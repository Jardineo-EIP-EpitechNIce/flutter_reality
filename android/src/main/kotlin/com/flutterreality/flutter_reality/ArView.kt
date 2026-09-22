package com.flutterreality.flutter_reality

import android.app.Activity
import android.content.Context
import android.util.Log
import android.view.View
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
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
import com.google.ar.core.Config
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import io.github.sceneview.ar.ARScene
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * MILESTONE A (feasibility spike) of the arsceneview 2.2.1 -> 4.38.0 upgrade
 * (see agents/sceneview-4x-upgrade's plan). arsceneview 4.x has no View-based
 * `ARSceneView` class any more - it's a Jetpack Compose `@Composable`
 * (`ARScene`), hosted here inside a `ComposeView` since Flutter's
 * `PlatformView` contract still requires a plain `android.view.View`.
 *
 * This intentionally implements only enough to prove the
 * ComposeView-in-PlatformView-in-Filament stack renders at all: session
 * init/dispose and plane detection. Node/anchor placement, gestures, cloud
 * anchors, snapshot, and point-cloud are NOT yet ported - see the plan's
 * milestones B-D.
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
    private val mainScope = CoroutineScope(Dispatchers.Main)

    private val sessionFlutterApi = ARSessionFlutterApi(messenger, channelSuffix)
    private val objectFlutterApi = ARObjectFlutterApi(messenger, channelSuffix)
    private val anchorFlutterApi = ARAnchorFlutterApi(messenger, channelSuffix)

    private var planeFindingMode by mutableStateOf(Config.PlaneFindingMode.DISABLED)
    private var showPlanes by mutableStateOf(true)
    private var detectedPlaneCount = 0

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
            ARScene(
                modifier = Modifier.fillMaxSize(),
                sessionConfiguration = { _, config ->
                    config.planeFindingMode = planeFindingMode
                },
                planeRenderer = showPlanes,
                onSessionCreated = { Log.i(TAG, "ARScene session created") },
                onSessionFailed = { exception ->
                    mainScope.launch {
                        sessionFlutterApi.onError("AR session failed: ${exception.message}")
                    }
                },
                onTrackingFailureChanged = { reason ->
                    Log.d(TAG, "Tracking failure: $reason")
                },
                onSessionUpdated = { _, frame ->
                    val newPlaneCount = frame.getUpdatedTrackables(com.google.ar.core.Plane::class.java)
                        .count { it.trackingState == com.google.ar.core.TrackingState.TRACKING }
                    if (newPlaneCount > 0) {
                        detectedPlaneCount += newPlaneCount
                        mainScope.launch {
                            sessionFlutterApi.onPlaneDetected(detectedPlaneCount.toLong())
                        }
                    }
                },
            ) {
                // Milestone B will declare AnchorNode/ModelNode content here.
            }
        }

        ARSessionHostApi.setUp(messenger, SessionApiHandler(), channelSuffix)
        ARObjectHostApi.setUp(messenger, this, channelSuffix)
        ARAnchorHostApi.setUp(messenger, this, channelSuffix)
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
        }

        override suspend fun showPlanes(showPlanes: Boolean) {
            this@ArView.showPlanes = showPlanes
        }

        override suspend fun dispose() {
            teardown()
        }

        override suspend fun getAnchorPose(anchorId: String): PoseMessage {
            throw FlutterError("NOT_YET_PORTED", "Milestone A stub", null)
        }

        override suspend fun getCameraPose(): PoseMessage {
            throw FlutterError("NOT_YET_PORTED", "Milestone A stub", null)
        }

        override suspend fun snapshot(): ByteArray {
            throw FlutterError("NOT_YET_PORTED", "Milestone A stub", null)
        }

        override suspend fun disableCamera() {
            throw FlutterError("NOT_YET_PORTED", "Milestone A stub", null)
        }

        override suspend fun enableCamera() {
            throw FlutterError("NOT_YET_PORTED", "Milestone A stub", null)
        }
    }

    override suspend fun initialize() {
        // ARObjectHostApi.initialize() has nothing to set up yet in Milestone A.
    }

    override suspend fun addNode(node: NodeMessage): Boolean {
        throw FlutterError("NOT_YET_PORTED", "Milestone B stub", null)
    }

    override suspend fun addNodeToPlaneAnchor(node: NodeMessage, anchor: AnchorMessage): Boolean {
        throw FlutterError("NOT_YET_PORTED", "Milestone B stub", null)
    }

    override suspend fun removeNode(name: String) {
        throw FlutterError("NOT_YET_PORTED", "Milestone B stub", null)
    }

    override suspend fun transformationChanged(name: String, transformation: List<Double>) {
        throw FlutterError("NOT_YET_PORTED", "Milestone C stub", null)
    }

    override suspend fun addAnchor(anchor: AnchorMessage): Boolean {
        throw FlutterError("NOT_YET_PORTED", "Milestone B stub", null)
    }

    override suspend fun removeAnchor(name: String) {
        throw FlutterError("NOT_YET_PORTED", "Milestone B stub", null)
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
