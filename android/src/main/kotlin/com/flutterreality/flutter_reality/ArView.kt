package com.flutterreality.flutter_reality

import android.app.Activity
import android.content.Context
import android.util.Log
import android.view.View
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.google.ar.core.Anchor
import com.google.ar.core.Config
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.flutterreality.flutter_reality.Serialization.deserializeMatrix4
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import io.github.sceneview.ar.ARScene
import io.github.sceneview.rememberModelInstance
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File

/**
 * MILESTONE B of the arsceneview 2.2.1 -> 4.38.0 upgrade (see
 * agents/sceneview-4x-upgrade's plan): node/anchor placement, on top of
 * Milestone A's confirmed-working ComposeView-in-PlatformView stack.
 *
 * Placed anchors/nodes are modeled as Compose state (`anchors`/`nodes` below)
 * rather than built imperatively via `addChildNode`/`removeChildNode` as in
 * 2.2.1 - arsceneview 4.x's AnchorNode/ModelNode are declared inside the
 * `ARScene` content block, not constructed and attached by hand.
 *
 * Gestures (pan/rotate), cloud anchors, snapshot, camera/anchor pose queries,
 * and point-cloud are still NOT ported - see the plan's milestones C-D.
 */
class ArView(
    context: Context,
    private val activity: Activity,
    private val lifecycle: Lifecycle,
    private val messenger: BinaryMessenger,
    id: Int,
) : PlatformView, ARObjectHostApi, ARAnchorHostApi {
    private val TAG: String = ArView::class.java.name
    private val viewId: Int = id
    private val channelSuffix: String = id.toString()
    private val viewContext: Context = context
    private val mainScope = CoroutineScope(Dispatchers.Main)

    private val sessionFlutterApi = ARSessionFlutterApi(messenger, channelSuffix)
    private val objectFlutterApi = ARObjectFlutterApi(messenger, channelSuffix)
    private val anchorFlutterApi = ARAnchorFlutterApi(messenger, channelSuffix)

    private var planeFindingMode by mutableStateOf(Config.PlaneFindingMode.DISABLED)
    private var showPlanes by mutableStateOf(true)
    // ARCore reports an existing TRACKING plane as "updated" continuously (its
    // geometry keeps refining), not just once when first detected - dedup
    // against this set so the count only grows on genuinely new planes.
    private val detectedPlanes = mutableSetOf<com.google.ar.core.Plane>()
    private var session: Session? = null

    private data class PlacedNode(
        val uri: String,
        val type: Int,
        val transformation: List<Double>,
        val parentAnchorName: String?,
    )

    // Compose state driving the declarative scene content below. Keyed by the
    // Dart-assigned name (ARNode.name / ARAnchor.name), same identifiers the
    // Pigeon calls already use.
    private val anchors = mutableStateMapOf<String, Anchor>()
    private val nodes = mutableStateMapOf<String, PlacedNode>()

    private val composeView: ComposeView = ComposeView(context)

    // ComposeView requires ViewTree owners (LifecycleOwner/ViewModelStoreOwner/
    // SavedStateRegistryOwner) to be reachable when it's attached, or it throws
    // "ViewTreeLifecycleOwner not found". Propagating from the hosting Activity
    // didn't survive Flutter's Hybrid Composition view wrapping in practice
    // (confirmed on-device: the crash still named FlutterView as the point the
    // walk-up search failed at), so this plugin provides its own owner.
    //
    // It cannot simply alias Flutter's own `lifecycle: Lifecycle` param as this
    // owner's `lifecycle`, though: SavedStateRegistryController.performRestore()
    // requires exclusive control of a Lifecycle starting from INITIALIZED
    // (confirmed on-device: aliasing Flutter's - already past that point by
    // construction time - threw "Restarter must be created only during owner's
    // initialization stage"). So this owner drives its own private
    // LifecycleRegistry, fed by forwarding Flutter's lifecycle events into it.
    private val viewTreeOwner = object : LifecycleOwner, ViewModelStoreOwner, SavedStateRegistryOwner {
        private val lifecycleRegistry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = lifecycleRegistry
        override val viewModelStore: ViewModelStore = ViewModelStore()
        private val savedStateRegistryController = SavedStateRegistryController.create(this)
        override val savedStateRegistry: SavedStateRegistry get() = savedStateRegistryController.savedStateRegistry

        init {
            lifecycleRegistry.currentState = Lifecycle.State.INITIALIZED
            savedStateRegistryController.performRestore(null)
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }

        fun forward(event: Lifecycle.Event) {
            lifecycleRegistry.handleLifecycleEvent(event)
        }
    }

    init {
        Log.i(TAG, "init: viewId=$viewId lifecycleState=${lifecycle.currentState}")

        // Compose's per-window recomposer (AbstractComposeView.resolveParentCompositionContext
        // -> getWindowRecomposer) looks up the ViewTreeLifecycleOwner by walking UP from
        // FlutterView, not down into this ComposeView's own subtree - confirmed on-device
        // (the crash names FlutterView as the failed lookup's starting point). Tagging
        // composeView itself is therefore a no-op for this purpose: the tag has to be on
        // an ancestor of FlutterView. The Activity's decorView is the highest one reachable
        // here and is guaranteed to be an ancestor of FlutterView regardless of composition
        // mode.
        val decorView = activity.window?.decorView
        if (decorView != null) {
            decorView.setViewTreeLifecycleOwner(viewTreeOwner)
            decorView.setViewTreeViewModelStoreOwner(viewTreeOwner)
            decorView.setViewTreeSavedStateRegistryOwner(viewTreeOwner)
        }
        composeView.setViewTreeLifecycleOwner(viewTreeOwner)
        composeView.setViewTreeViewModelStoreOwner(viewTreeOwner)
        composeView.setViewTreeSavedStateRegistryOwner(viewTreeOwner)

        // Bring the owner's own lifecycle up to Flutter's current state, then
        // keep it in sync going forward.
        when (lifecycle.currentState) {
            Lifecycle.State.STARTED -> viewTreeOwner.forward(Lifecycle.Event.ON_START)
            Lifecycle.State.RESUMED -> {
                viewTreeOwner.forward(Lifecycle.Event.ON_START)
                viewTreeOwner.forward(Lifecycle.Event.ON_RESUME)
            }
            else -> {}
        }
        lifecycle.addObserver(LifecycleEventObserver { _, event -> viewTreeOwner.forward(event) })

        composeView.setContent {
            // Memoized so placing/removing a node (which changes `nodes`/`anchors`
            // state, causing this whole setContent lambda to recompose) doesn't
            // hand ARScene a freshly-allocated listener/config-callback identity
            // every time - confirmed on-device that recreating these on every
            // recomposition caused visible flicker and touch-to-hit-test latency
            // (manifesting as a consistent forward offset between the tap point
            // and where the model actually landed).
            val stableGestureListener = androidx.compose.runtime.remember {
                object : io.github.sceneview.gesture.GestureDetector.SimpleOnGestureListener() {
                    override fun onSingleTapConfirmed(e: android.view.MotionEvent, node: io.github.sceneview.node.Node?) {
                        handleTap(e, node)
                    }
                }
            }
            val stableSessionConfiguration = androidx.compose.runtime.remember(planeFindingMode) {
                { _: Session, config: Config -> config.planeFindingMode = planeFindingMode }
            }
            ARScene(
                modifier = Modifier.fillMaxSize(),
                sessionConfiguration = stableSessionConfiguration,
                planeRenderer = showPlanes,
                onSessionCreated = { createdSession ->
                    session = createdSession
                    Log.i(TAG, "ARScene session created")
                },
                onSessionFailed = { exception ->
                    mainScope.launch {
                        sessionFlutterApi.onError("AR session failed: ${exception.message}")
                    }
                },
                onTrackingFailureChanged = { reason ->
                    Log.d(TAG, "Tracking failure: $reason")
                },
                onGestureListener = stableGestureListener,
                onSessionUpdated = { _, frame ->
                    var addedNewPlane = false
                    frame.getUpdatedTrackables(com.google.ar.core.Plane::class.java).forEach { plane ->
                        if (plane.trackingState == com.google.ar.core.TrackingState.TRACKING &&
                            detectedPlanes.add(plane)
                        ) {
                            addedNewPlane = true
                        }
                    }
                    if (addedNewPlane) {
                        val count = detectedPlanes.size.toLong()
                        mainScope.launch {
                            sessionFlutterApi.onPlaneDetected(count)
                        }
                    }
                },
            ) {
                // Nodes anchored to a placed AnchorNode.
                //
                // Every call below is wrapped in key(...): without it, Compose's
                // positional slot table can misattribute remembered state (the
                // rememberModelInstance/ModelNode instance) across loop
                // iterations - confirmed on-device as the root cause of two
                // symptoms at once: newly placed models visually replacing
                // already-placed ones (their state got collapsed into the same
                // slot) and models not appearing at the tapped location (a
                // node's declared position got attributed to the wrong AnchorNode
                // after a recomposition). This is a well-known Compose pitfall
                // for composables called in a loop with structurally identical
                // arguments (every duck placement calls
                // rememberModelInstance(modelLoader, "duck.glb") with the exact
                // same arguments), not a bug in arsceneview itself.
                anchors.forEach { (anchorName, anchor) ->
                    key(anchorName) {
                        AnchorNode(anchor = anchor) {
                            nodes.forEach { (nodeName, node) ->
                                if (node.parentAnchorName == anchorName) {
                                    key(nodeName) {
                                        val fileLocation = resolveModelFileLocation(node.uri, node.type)
                                        if (fileLocation != null) {
                                            val instance = rememberModelInstance(modelLoader, fileLocation)
                                            if (instance != null) {
                                                ModelNode(
                                                    modelInstance = instance,
                                                    scaleToUnits = node.transformation.firstOrNull()?.toFloat(),
                                                    isEditable = false,
                                                    apply = {
                                                        name = nodeName
                                                        isScaleEditable = false
                                                    },
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // Top-level nodes (not attached to any anchor).
                nodes.forEach { (nodeName, node) ->
                    if (node.parentAnchorName == null) {
                      key(nodeName) {
                        val fileLocation = resolveModelFileLocation(node.uri, node.type)
                        if (fileLocation != null) {
                            val instance = rememberModelInstance(modelLoader, fileLocation)
                            if (instance != null) {
                                ModelNode(
                                    modelInstance = instance,
                                    scaleToUnits = node.transformation.firstOrNull()?.toFloat(),
                                    isEditable = false,
                                    apply = {
                                        name = nodeName
                                        isScaleEditable = false
                                    },
                                )
                            }
                        }
                      }
                    }
                }
            }
        }

        ARSessionHostApi.setUp(messenger, SessionApiHandler(), channelSuffix)
        ARObjectHostApi.setUp(messenger, this, channelSuffix)
        ARAnchorHostApi.setUp(messenger, this, channelSuffix)
    }

    // Resolves a [NodeMessage]'s `uri`/`type` to a loadable model path. Mirrors
    // 2.2.1's `buildModelNode` path-resolution logic, including the
    // path-containment check for the file-system node types.
    private fun handleTap(e: android.view.MotionEvent, node: io.github.sceneview.node.Node?) {
        if (node != null) {
            mainScope.launch {
                objectFlutterApi.onNodeTap(listOf(node.name))
            }
            return
        }
        val currentSession = session ?: return
        val frame = try {
            currentSession.update()
        } catch (ex: Exception) {
            return
        }
        val hits = frame.hitTest(e)
            .filter { hit ->
                val trackable = hit.trackable
                trackable is com.google.ar.core.Plane && trackable.trackingState == com.google.ar.core.TrackingState.TRACKING
            }
            .map { hit ->
                HitTestResultMessage(
                    type = 1L,
                    distance = hit.distance.toDouble(),
                    worldTransform = com.flutterreality.flutter_reality.Serialization.serializePose(hit.hitPose).toList(),
                )
            }
        if (hits.isNotEmpty()) {
            mainScope.launch {
                sessionFlutterApi.onPlaneOrPointTap(hits)
            }
        }
    }

    private fun resolveModelFileLocation(uri: String, type: Int): String? {
        return when (type) {
            0 -> { // GLTF2 Model from Flutter asset folder
                FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(uri)
            }
            1 -> uri // GLB Model from the web
            2 -> uri // fileSystemAppFolderGLB (native never prefixed this one in 2.2.1 either)
            3 -> { // fileSystemAppFolderGLTF2
                val baseDir = File(viewContext.applicationInfo.dataDir, "app_flutter")
                resolveWithinBaseDir(baseDir, uri)
            }
            else -> null
        }
    }

    // Resolves `relativeUri` against `baseDir` and returns null if the result would
    // escape `baseDir` (e.g. via a "../" path-traversal segment). `node.uri` is
    // developer-supplied on the Dart side, but a host app that forwards an
    // externally-controlled string (e.g. from a server-driven model catalog)
    // without validating it could otherwise reach arbitrary files the app's own
    // sandbox can read/write.
    private fun resolveWithinBaseDir(baseDir: File, relativeUri: String): String? {
        val resolved = File(baseDir, relativeUri).canonicalFile
        val canonicalBase = baseDir.canonicalFile
        return if (resolved.path == canonicalBase.path || resolved.path.startsWith(canonicalBase.path + File.separator)) {
            resolved.path
        } else {
            null
        }
    }

    override fun getView(): View = composeView

    override fun dispose() {
        teardown()
    }

    private var isTornDown = false

    private fun teardown() {
        if (isTornDown) return
        isTornDown = true
        Log.i(TAG, "dispose: viewId=$viewId lifecycleState=${lifecycle.currentState}")
        ARSessionHostApi.setUp(messenger, null, channelSuffix)
        ARObjectHostApi.setUp(messenger, null, channelSuffix)
        ARAnchorHostApi.setUp(messenger, null, channelSuffix)
    }

    private inner class SessionApiHandler : ARSessionHostApi {
        override suspend fun initialize(config: SessionConfigMessage) {
            planeFindingMode = when (config.planeDetectionConfig.toInt()) {
                1 -> Config.PlaneFindingMode.HORIZONTAL
                2 -> Config.PlaneFindingMode.VERTICAL
                3 -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                else -> Config.PlaneFindingMode.DISABLED
            }
            showPlanes = config.showPlanes
            // ARScene's `sessionConfiguration` callback only runs at session
            // bootstrap, not on every recomposition - confirmed on-device
            // (updating `planeFindingMode` state alone left plane detection
            // permanently disabled once the session was already created,
            // since Dart's initialize() call always arrives after that).
            // Reconfigure the live session directly, same as 2.2.1 did.
            session?.let { s ->
                try {
                    s.configure(s.config.apply { planeFindingMode = this@ArView.planeFindingMode })
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to reconfigure session: ${e.message}")
                }
            }
        }

        override suspend fun showPlanes(showPlanes: Boolean) {
            this@ArView.showPlanes = showPlanes
        }

        override suspend fun dispose() {
            teardown()
        }

        override suspend fun getAnchorPose(anchorId: String): PoseMessage {
            throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
        }

        override suspend fun getCameraPose(): PoseMessage {
            throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
        }

        override suspend fun snapshot(): ByteArray {
            throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
        }

        override suspend fun disableCamera() {
            throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
        }

        override suspend fun enableCamera() {
            throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
        }
    }

    override suspend fun initialize() {
        // ARObjectHostApi.initialize() has nothing to set up.
    }

    override suspend fun addNode(node: NodeMessage): Boolean {
        if (node.uri == null) return false
        nodes[node.name] = PlacedNode(node.uri!!, node.type.toInt(), node.transformation, null)
        return true
    }

    override suspend fun addNodeToPlaneAnchor(node: NodeMessage, anchor: AnchorMessage): Boolean {
        if (node.uri == null) return false
        if (!anchors.containsKey(anchor.name)) return false
        nodes[node.name] = PlacedNode(node.uri!!, node.type.toInt(), node.transformation, anchor.name)
        return true
    }

    override suspend fun removeNode(name: String) {
        if (nodes.remove(name) == null) {
            throw FlutterError("NODE_NOT_FOUND", "Node with name $name not found", null)
        }
    }

    override suspend fun transformationChanged(name: String, transformation: List<Double>) {
        throw FlutterError("NOT_YET_PORTED", "Milestone C stub", null)
    }

    override suspend fun addAnchor(anchor: AnchorMessage): Boolean {
        if (anchor.type.toInt() != 0) return false // only plane anchors are supported
        val currentSession = session ?: return false
        return try {
            val (position, rotation) = deserializeMatrix4(ArrayList(anchor.transformation))
            val pose = Pose(
                floatArrayOf(position.x, position.y, position.z),
                floatArrayOf(rotation.x, rotation.y, rotation.z, 1f),
            )
            val arAnchor = currentSession.createAnchor(pose)
            anchors[anchor.name] = arAnchor
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error in addAnchor: ${e.message}")
            false
        }
    }

    override suspend fun removeAnchor(name: String) {
        val anchor = anchors.remove(name)
            ?: throw FlutterError("ANCHOR_NOT_FOUND", "Anchor with name $name not found", null)
        // Also drop any nodes that were attached to this anchor - their AnchorNode
        // parent is about to stop being declared.
        nodes.keys.filter { nodes[it]?.parentAnchorName == name }.forEach { nodes.remove(it) }
        anchor.detach()
    }

    override suspend fun initGoogleCloudAnchorMode(): Boolean {
        throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
    }

    override suspend fun uploadAnchor(name: String): Boolean {
        throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
    }

    override suspend fun downloadAnchor(cloudAnchorId: String): Boolean {
        throw FlutterError("NOT_YET_PORTED", "Milestone D stub", null)
    }
}
