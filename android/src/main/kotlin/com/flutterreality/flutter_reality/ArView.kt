package com.flutterreality.flutter_reality

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.lifecycle.Lifecycle
import com.google.ar.core.Anchor.CloudAnchorState
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.TrackingState
import com.flutterreality.flutter_reality.Serialization.deserializeMatrix4
import com.flutterreality.flutter_reality.Serialization.serializePose
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import io.github.sceneview.ar.ARSceneView
import io.github.sceneview.ar.arcore.canHostCloudAnchor
import io.github.sceneview.ar.arcore.fps
import io.github.sceneview.ar.node.AnchorNode
import io.github.sceneview.ar.node.CloudAnchorNode
import io.github.sceneview.gesture.MoveGestureDetector
import io.github.sceneview.gesture.RotateGestureDetector
import io.github.sceneview.math.Position
import io.github.sceneview.math.Transform
import io.github.sceneview.model.ModelInstance
import io.github.sceneview.node.ModelNode
import io.github.sceneview.node.Node
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import io.github.sceneview.math.Position as ScenePosition
import io.github.sceneview.math.Rotation as SceneRotation
import io.github.sceneview.math.Scale as SceneScale
import io.github.sceneview.texture.ImageTexture
import io.github.sceneview.material.setTexture
import io.github.sceneview.ar.scene.PlaneRenderer
import io.flutter.FlutterInjector
import io.github.sceneview.node.CylinderNode
import io.github.sceneview.math.Direction
import io.github.sceneview.math.Rotation
import io.github.sceneview.math.Scale
import io.github.sceneview.math.colorOf
import io.github.sceneview.loaders.MaterialLoader
import com.google.ar.core.exceptions.SessionPausedException

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
    private var sceneView: ARSceneView
    private val mainScope = CoroutineScope(Dispatchers.Main)
    private var worldOriginNode: Node? = null

    private val rootLayout: ViewGroup = FrameLayout(context)

    private val sessionFlutterApi = ARSessionFlutterApi(messenger, channelSuffix)
    private val objectFlutterApi = ARObjectFlutterApi(messenger, channelSuffix)
    private val anchorFlutterApi = ARAnchorFlutterApi(messenger, channelSuffix)
    private val nodesMap = mutableMapOf<String, ModelNode>()
    private var selectedNode: Node? = null
    private val detectedPlanes = mutableSetOf<Plane>()
    private val anchorNodesMap = mutableMapOf<String, AnchorNode>()
    private var showAnimatedGuide = true
    private var showFeaturePoints = false
    private val pointCloudNodes = mutableListOf<PointCloudNode>()
    private var lastPointCloudTimestamp: Long? = null
    private var lastPointCloudFrame: Frame? = null
    private var pointCloudModelInstances = mutableListOf<ModelInstance>()
    private var handlePans = false
    private var handleRotation = false
    private var isSessionPaused = false

    private class PointCloudNode(
        modelInstance: ModelInstance,
        var id: Int,
        var confidence: Float,
    ) : ModelNode(modelInstance)

    init {
        Log.i(TAG, "init: viewId=$viewId lifecycleState=${lifecycle.currentState}")
        sceneView = ARSceneView(
            context = viewContext,
            sharedLifecycle = lifecycle,
            sessionConfiguration = { session, config ->
                config.apply {
                    depthMode = Config.DepthMode.DISABLED
                    instantPlacementMode = Config.InstantPlacementMode.DISABLED
                    lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                    focusMode = Config.FocusMode.AUTO
                    planeFindingMode = Config.PlaneFindingMode.DISABLED
                }
            },
            onSessionFailed = { exception ->
                // The lifecycle-driven session resume (e.g. after the app returns
                // from background) can fail natively without ever reaching Dart.
                // Surface it explicitly instead of leaving the AR view silently black.
                mainScope.launch {
                    sessionFlutterApi.onError("AR session failed: ${exception.message}")
                }
            },
        )

        rootLayout.addView(sceneView)

        ARSessionHostApi.setUp(messenger, SessionApiHandler(), channelSuffix)
        ARObjectHostApi.setUp(messenger, this, channelSuffix)
        ARAnchorHostApi.setUp(messenger, this, channelSuffix)
    }

    private suspend fun disableCameraImpl() {
        try {
            isSessionPaused = true
            sceneView.session?.pause()
        } catch (e: Exception) {
            throw FlutterError("DISABLE_CAMERA_ERROR", e.message, null)
        }
    }

    private suspend fun enableCameraImpl() {
        try {
            isSessionPaused = false
            sceneView.session?.resume()
        } catch (e: Exception) {
            throw FlutterError("ENABLE_CAMERA_ERROR", e.message, null)
        }
    }

    private suspend fun buildModelNode(node: NodeMessage): ModelNode? {
        var fileLocation = node.uri ?: return null
        when (node.type.toInt()) {
            0 -> { // GLTF2 Model from Flutter asset folder
                val loader = FlutterInjector.instance().flutterLoader()
                fileLocation = loader.getLookupKeyForAsset(fileLocation)
            }
            1 -> { // GLB Model from the web
            }
            2 -> { // fileSystemAppFolderGLB
            }
            3 -> { // fileSystemAppFolderGLTF2
                val documentsPath = viewContext.getApplicationInfo().dataDir
                fileLocation = documentsPath + "/app_flutter/" + node.uri
            }
            else -> {
                return null
            }
        }

        val transformation = node.transformation
        if (transformation.isEmpty()) {
            return null
        }

        return try {
            sceneView.modelLoader.loadModelInstance(fileLocation)?.let { modelInstance ->
                object : ModelNode(
                    modelInstance = modelInstance,
                    scaleToUnits = transformation.first().toFloat(),
                ) {
                    override fun onMove(detector: MoveGestureDetector, e: MotionEvent): Boolean {
                        if (handlePans) {
                            val defaultResult = super.onMove(detector, e)
                            name?.let { n -> mainScope.launch { objectFlutterApi.onPanChange(n) } }
                            return defaultResult
                        }
                        return false
                    }

                    override fun onMoveBegin(detector: MoveGestureDetector, e: MotionEvent): Boolean {
                        if (handlePans) {
                            val defaultResult = super.onMoveBegin(detector, e)
                            name?.let { n -> mainScope.launch { objectFlutterApi.onPanStart(n) } }
                            return defaultResult
                        }
                        return false
                    }

                    override fun onMoveEnd(detector: MoveGestureDetector, e: MotionEvent) {
                        if (handlePans) {
                            super.onMoveEnd(detector, e)
                            name?.let { n ->
                                mainScope.launch {
                                    objectFlutterApi.onPanEnd(
                                        NodeTransformEventMessage(
                                            name = n,
                                            transform = transform.toFloatArray().map { it.toDouble() },
                                        ),
                                    )
                                }
                            }
                        }
                    }

                    override fun onRotateBegin(detector: RotateGestureDetector, e: MotionEvent): Boolean {
                        if (handleRotation) {
                            val defaultResult = super.onRotateBegin(detector, e)
                            name?.let { n -> mainScope.launch { objectFlutterApi.onRotationStart(n) } }
                            return defaultResult
                        }
                        return false
                    }

                    override fun onRotate(detector: RotateGestureDetector, e: MotionEvent): Boolean {
                        if (handleRotation) {
                            val defaultResult = super.onRotate(detector, e)
                            name?.let { n -> mainScope.launch { objectFlutterApi.onRotationChange(n) } }
                            return defaultResult
                        }
                        return false
                    }

                    override fun onRotateEnd(detector: RotateGestureDetector, e: MotionEvent) {
                        if (handleRotation) {
                            super.onRotateEnd(detector, e)
                            name?.let { n ->
                                mainScope.launch {
                                    objectFlutterApi.onRotationEnd(
                                        NodeTransformEventMessage(
                                            name = n,
                                            transform = transform.toFloatArray().map { it.toDouble() },
                                        ),
                                    )
                                }
                            }
                        }
                    }
                }.apply {
                    // isRotationEditable is gated behind isEditable in the sceneview library
                    // (isRotationEditable getter == isEditable && field), so without setting
                    // isEditable it always evaluates to false and the library's own gesture
                    // arbitration between rotate/scale never resolves in rotate's favor (see
                    // https://github.com/SceneView/sceneview-android/issues/100).
                    isEditable = handleRotation
                    isRotationEditable = handleRotation
                    // Deliberately NOT setting isPositionEditable here. Pan already works by a
                    // different route: the base Node.onMove(detector, e) delegates to the
                    // parent (AnchorNode) whenever isPositionEditable() is false, and AnchorNode
                    // hardcodes its own isPositionEditable to true in its constructor -
                    // dragging actually moves/recreates the anchor, not this node's local
                    // transform. Setting isEditable above (needed for rotation) would also
                    // unmask isPositionEditable's getter if its field were true, switching pan
                    // to a local-hit-test code path that requires the raycast hit's node to
                    // equal this node's parent - which doesn't hold in practice and silently
                    // breaks dragging. Leaving the field at its default (false) keeps pan on
                    // the anchor-delegation path that already works.
                    // isScaleEditable defaults to true in the base Node class, and setting
                    // isEditable above unmasks it: since this plugin doesn't expose a
                    // handleScale flag (no Dart-side control over it, no tests for it), leave
                    // pinch-to-scale off rather than ship an uncontrolled, untested capability.
                    isScaleEditable = false
                    name = node.name
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    override suspend fun addNodeToPlaneAnchor(node: NodeMessage, anchor: AnchorMessage): Boolean {
        val anchorNode = anchorNodesMap[anchor.name] ?: return false
        return try {
            val builtNode = buildModelNode(node) ?: return false
            anchorNode.addChildNode(builtNode)
            sceneView.addChildNode(anchorNode)
            builtNode.name?.let { nodesMap[it] = builtNode }
            true
        } catch (e: Exception) {
            false
        }
    }

    private suspend fun initSession(config: SessionConfigMessage) {
        try {
            handlePans = config.handlePans
            handleRotation = config.handleRotation

            sceneView.session?.let { session ->
                session.configure(session.config.apply {
                    depthMode = when (session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                        true -> Config.DepthMode.AUTOMATIC
                        else -> Config.DepthMode.DISABLED
                    }
                    planeFindingMode = when (config.planeDetectionConfig.toInt()) {
                        1 -> Config.PlaneFindingMode.HORIZONTAL
                        2 -> Config.PlaneFindingMode.VERTICAL
                        3 -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                        else -> Config.PlaneFindingMode.DISABLED
                    }
                })
            }

            handleShowWorldOrigin(config.showWorldOrigin)

            sceneView.apply {
                environment = environmentLoader.createHDREnvironment(
                    assetFileLocation = "environments/evening_meadow_2k.hdr"
                )!!

                planeRenderer.isEnabled = config.showPlanes
                planeRenderer.isVisible = config.showPlanes
                planeRenderer.planeRendererMode = PlaneRenderer.PlaneRendererMode.RENDER_ALL

                if (config.showFeaturePoints) {
                    showFeaturePoints = true
                } else {
                    showFeaturePoints = false
                    pointCloudNodes.toList().forEach { removePointCloudNode(it) }
                }

                onFrame = { frameTime ->
                    try {
                        if (!isSessionPaused) {
                            // ARSceneView's own per-frame callback (the protected onFrame(Long)
                            // that invokes this lambda) already calls session.updateOrNull() once
                            // before we ever get here, and stashes the result in its `frame`
                            // property (confirmed by decompiling arsceneview 2.3.0:
                            // ARSceneView.onFrame() updates ARCore, feeds the camera
                            // stream/camera node/light estimator/plane renderer from that result,
                            // then exposes it via the public `frame` getter). Calling
                            // session.update() again here was a second full ARCore update - image
                            // acquisition plus plane/point-cloud/anchor tracking - every single
                            // rendered frame, for the entire time the AR view was active. Reusing
                            // the already-updated frame avoids that duplicate per-frame cost.
                            frame?.let { frame ->
                                if (showAnimatedGuide) {
                                    frame.getUpdatedTrackables(Plane::class.java).forEach { plane ->
                                        if (plane.trackingState == TrackingState.TRACKING) {
                                            rootLayout.findViewWithTag<View>("hand_motion_layout")?.let { handMotionLayout ->
                                                rootLayout.removeView(handMotionLayout)
                                                showAnimatedGuide = false
                                            }
                                        }
                                    }
                                }

                                if (showFeaturePoints) {
                                    val currentFps = frame.fps(lastPointCloudFrame)
                                    if (currentFps < 10) {
                                        frame.acquirePointCloud()?.let { pointCloud ->
                                            if (pointCloud.timestamp != lastPointCloudTimestamp) {
                                                lastPointCloudFrame = frame
                                                lastPointCloudTimestamp = pointCloud.timestamp

                                                val pointsSize = pointCloud.ids?.limit() ?: 0

                                                pointCloudNodes.toList().forEach { removePointCloudNode(it) }

                                                val pointsBuffer = pointCloud.points
                                                for (index in 0 until pointsSize) {
                                                    val pointIndex = index * 4
                                                    val position =
                                                        Position(
                                                            pointsBuffer[pointIndex],
                                                            pointsBuffer[pointIndex + 1],
                                                            pointsBuffer[pointIndex + 2],
                                                        )
                                                    val confidence = pointsBuffer[pointIndex + 3]
                                                    addPointCloudNode(index, position, confidence)
                                                }

                                                pointCloud.release()
                                            }
                                        }
                                    }
                                }

                                frame.getUpdatedTrackables(Plane::class.java).forEach { plane ->
                                    if (plane.trackingState == TrackingState.TRACKING &&
                                        !detectedPlanes.contains(plane)
                                    ) {
                                        detectedPlanes.add(plane)
                                        mainScope.launch {
                                            sessionFlutterApi.onPlaneDetected(detectedPlanes.size.toLong())
                                        }
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        when (e) {
                            is SessionPausedException -> {
                                Log.d(TAG, "Session paused, skipping frame update")
                            }
                            else -> {
                                Log.e(TAG, "Error during frame update", e)
                                e.printStackTrace()
                            }
                        }
                    }
                }

                setOnGestureListener(
                    onSingleTapConfirmed = { motionEvent: MotionEvent, node: Node? ->
                        if (node != null) {
                            var anchorName: String? = null
                            var currentNode: Node? = node
                            while (currentNode != null) {
                                anchorNodesMap.forEach { (name, anchorNode) ->
                                    if (currentNode == anchorNode) {
                                        anchorName = name
                                        return@forEach
                                    }
                                }
                                if (anchorName != null) break
                                currentNode = currentNode.parent
                            }
                            if (config.handleTaps) {
                                mainScope.launch { objectFlutterApi.onNodeTap(listOf(anchorName)) }
                            }
                            true
                        } else {
                            session?.update()?.let { frame ->
                                val hitResults = frame.hitTest(motionEvent)

                                Log.d("ArView", "Hit Results count: ${hitResults.size}")

                                val planeHits =
                                    hitResults
                                        .filter { hit ->
                                            val trackable = hit.trackable
                                            trackable is Plane && trackable.trackingState == TrackingState.TRACKING
                                        }.map { hit ->
                                            HitTestResultMessage(
                                                type = 1L,
                                                distance = hit.distance.toDouble(),
                                                worldTransform = serializePose(hit.hitPose).toList(),
                                            )
                                        }
                                mainScope.launch {
                                    sessionFlutterApi.onPlaneOrPointTap(planeHits)
                                }
                            }
                            true
                        }
                    },
                )

                if (config.showAnimatedGuide && showAnimatedGuide) {
                    val handMotionLayout =
                        LayoutInflater
                            .from(context)
                            .inflate(R.layout.sceneform_hand_layout, rootLayout, false)
                            .apply {
                                tag = "hand_motion_layout"
                            }
                    rootLayout.addView(handMotionLayout)
                }

                val customPlaneTexturePath = config.customPlaneTexturePath
                if (customPlaneTexturePath != null) {
                    try {
                        val loader = FlutterInjector.instance().flutterLoader()
                        val assetKey = loader.getLookupKeyForAsset(customPlaneTexturePath)
                        val customPlaneTexture =
                            ImageTexture
                                .Builder()
                                .bitmap(materialLoader.assets, assetKey)
                                .build(engine)
                        planeRenderer.planeMaterial.defaultInstance.apply {
                            setTexture(PlaneRenderer.MATERIAL_TEXTURE, customPlaneTexture)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error applying custom plane texture: ${e.message}")
                        Log.e(TAG, "Stack trace:", e)
                    }
                }
            }
        } catch (e: Exception) {
            throw FlutterError("AR_VIEW_ERROR", e.message, null)
        }
    }

    override suspend fun initialize() {
        // ARObjectHostApi.initialize() has nothing to set up: node bookkeeping is
        // lazily initialized and shared with the session's sceneView.
    }

    override suspend fun addNode(node: NodeMessage): Boolean {
        return try {
            val builtNode = buildModelNode(node) ?: return false
            sceneView.addChildNode(builtNode)
            builtNode.name?.let { nodesMap[it] = builtNode }
            true
        } catch (e: Exception) {
            false
        }
    }

    override suspend fun removeNode(name: String) {
        val node = nodesMap[name]
            ?: throw FlutterError("NODE_NOT_FOUND", "Node with name $name not found", null)
        try {
            node.parent?.removeChildNode(node)
            sceneView.removeChildNode(node)
            node.destroy()
            // ModelLoader.loadModelInstance creates a brand new FilamentAsset on every
            // call (confirmed by decompiling ModelLoader.createModel: it always calls
            // assetLoader.createAsset(buffer), never a cache lookup by path) - so this
            // asset is never shared with another node, and destroying it here is safe.
            // node.destroy() alone only releases the root entity's transform, not the
            // underlying mesh/texture buffers, which otherwise leak on every removal.
            sceneView.modelLoader.destroyModel(node.model)
            nodesMap.remove(name)
        } catch (e: Exception) {
            throw FlutterError("REMOVE_NODE_ERROR", e.message, null)
        }
    }

    override suspend fun transformationChanged(name: String, transformation: List<Double>) {
        if (!handlePans && !handleRotation) return
        try {
            if (transformation.size != 16) {
                throw FlutterError("INVALID_TRANSFORMATION", "Transformation must be a 4x4 matrix (16 values)", null)
            }
            val node = nodesMap[name]
                ?: throw FlutterError("NODE_NOT_FOUND", "Node with name $name not found", null)

            node.apply {
                transform(
                    position = ScenePosition(
                        x = transformation[12].toFloat(),
                        y = transformation[13].toFloat(),
                        z = transformation[14].toFloat(),
                    ),
                    rotation = SceneRotation(
                        x = kotlin.math.atan2(transformation[6].toFloat(), transformation[10].toFloat()),
                        y = kotlin.math.atan2(
                            -transformation[2].toFloat(),
                            kotlin.math.sqrt(
                                transformation[6].toFloat() * transformation[6].toFloat() +
                                    transformation[10].toFloat() * transformation[10].toFloat(),
                            ),
                        ),
                        z = kotlin.math.atan2(transformation[1].toFloat(), transformation[0].toFloat()),
                    ),
                    scale = SceneScale(
                        x = kotlin.math.sqrt(
                            (
                                transformation[0] * transformation[0] + transformation[1] * transformation[1] +
                                    transformation[2] * transformation[2]
                                ).toFloat(),
                        ),
                        y = kotlin.math.sqrt(
                            (
                                transformation[4] * transformation[4] + transformation[5] * transformation[5] +
                                    transformation[6] * transformation[6]
                                ).toFloat(),
                        ),
                        z = kotlin.math.sqrt(
                            (
                                transformation[8] * transformation[8] + transformation[9] * transformation[9] +
                                    transformation[10] * transformation[10]
                                ).toFloat(),
                        ),
                    ),
                )
            }
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("TRANSFORM_NODE_ERROR", e.message, null)
        }
    }

    override suspend fun removeAnchor(name: String) {
        try {
            val anchor = anchorNodesMap[name]
                ?: throw FlutterError("ANCHOR_NOT_FOUND", "Anchor with name $name not found", null)
            sceneView.removeChildNode(anchor)
            anchor.anchor?.detach()
            anchor.destroy()
            anchorNodesMap.remove(name)
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("REMOVE_ANCHOR_ERROR", e.message, null)
        }
    }

    private suspend fun getCameraPoseImpl(): PoseMessage {
        try {
            val frame = sceneView.session?.update()
            val cameraPose = frame?.camera?.pose
                ?: throw FlutterError("NO_CAMERA_POSE", "Camera pose is not available", null)
            return PoseMessage(matrix = serializePose(cameraPose).toList())
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("CAMERA_POSE_ERROR", e.message, null)
        }
    }

    private suspend fun getAnchorPoseImpl(anchorId: String): PoseMessage {
        try {
            // Look up by the anchor's local name (matches what Dart always sends),
            // not its cloud anchor id - most anchors are never uploaded and have none.
            val anchorNode = anchorNodesMap[anchorId]
                ?: throw FlutterError("ANCHOR_NOT_FOUND", "Anchor with ID $anchorId not found", null)
            val anchorPose = anchorNode.anchor?.pose
                ?: throw FlutterError("ANCHOR_NOT_FOUND", "Anchor with ID $anchorId not found", null)
            return PoseMessage(matrix = serializePose(anchorPose).toList())
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("ANCHOR_POSE_ERROR", e.message, null)
        }
    }

    private suspend fun snapshotImpl(): ByteArray {
        return try {
            suspendCancellableCoroutine { continuation ->
                val bitmap = Bitmap.createBitmap(
                    sceneView.width,
                    sceneView.height,
                    Bitmap.Config.ARGB_8888,
                )
                try {
                    val listener =
                        PixelCopy.OnPixelCopyFinishedListener { copyResult ->
                            if (copyResult == PixelCopy.SUCCESS) {
                                // PixelCopy's callback runs on the Handler we pass it below -
                                // the main looper, since PixelCopy requires either the main
                                // looper or a HandlerThread with an attached Surface, and we
                                // don't have the latter here. Synchronously PNG-encoding a
                                // full-resolution ARGB_8888 bitmap (commonly 10-20+ MB
                                // uncompressed on modern phone resolutions) directly in that
                                // callback used to block the main/UI thread for the entire
                                // encode, which can take hundreds of milliseconds and stalls
                                // rendering/input right when a snapshot is taken. Moving the
                                // compress() call to Dispatchers.Default keeps the main thread
                                // free while the encode runs.
                                mainScope.launch(Dispatchers.Default) {
                                    val byteStream = java.io.ByteArrayOutputStream()
                                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, byteStream)
                                    continuation.resume(byteStream.toByteArray())
                                }
                            } else {
                                continuation.resumeWithException(
                                    FlutterError("SNAPSHOT_ERROR", "Failed to capture snapshot", null),
                                )
                            }
                        }
                    PixelCopy.request(
                        sceneView,
                        bitmap,
                        listener,
                        Handler(Looper.getMainLooper()),
                    )
                } catch (e: Exception) {
                    continuation.resumeWithException(FlutterError("SNAPSHOT_ERROR", e.message, null))
                }
            }
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("SNAPSHOT_ERROR", e.message, null)
        }
    }

    private suspend fun showPlanesImpl(showPlanes: Boolean) {
        try {
            sceneView.apply {
                planeRenderer.isEnabled = showPlanes
            }
        } catch (e: Exception) {
            throw FlutterError("SHOW_PLANES_ERROR", e.message, null)
        }
    }

    override suspend fun addAnchor(anchor: AnchorMessage): Boolean {
        if (anchor.type.toInt() != 0) return false // only plane anchors are supported
        return try {
            val transform = ArrayList(anchor.transformation)
            val (position, rotation) = deserializeMatrix4(transform)

            val pose = Pose(
                floatArrayOf(position.x, position.y, position.z),
                floatArrayOf(rotation.x, rotation.y, rotation.z, 1f),
            )

            val arAnchor = sceneView.session?.createAnchor(pose) ?: return false
            val anchorNode = AnchorNode(sceneView.engine, arAnchor)
            try {
                anchorNode.transform = Transform(position = position, rotation = rotation)
            } catch (e: Exception) {
                Log.w(TAG, "Transform warning suppressed: ${e.message}")
            }

            sceneView.addChildNode(anchorNode)
            anchorNodesMap[anchor.name] = anchorNode
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error in addAnchor: ${e.message}")
            false
        }
    }

    override suspend fun initGoogleCloudAnchorMode(): Boolean {
        return try {
            Log.d(TAG, "Initializing Cloud Anchor mode")
            sceneView.session?.let { session ->
                session.configure(session.config.apply {
                    cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                })
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing Cloud Anchor mode", e)
            mainScope.launch {
                sessionFlutterApi.onError("Error initializing cloud anchor mode: ${e.message}")
            }
            throw FlutterError("CLOUD_ANCHOR_INIT_ERROR", e.message, null)
        }
    }

    override suspend fun uploadAnchor(name: String): Boolean {
        val session = sceneView.session
            ?: throw FlutterError("SESSION_ERROR", "AR Session is not available", null)

        try {
            sceneView.configureSession { _, config ->
                config.cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
            }
        } catch (e: Exception) {
            throw FlutterError("CLOUD_ANCHOR_CONFIG_ERROR", e.message, null)
        }

        if (!session.canHostCloudAnchor(sceneView.cameraNode)) {
            throw FlutterError("HOSTING_ERROR", "Insufficient visual data to host", null)
        }

        val anchorNode = anchorNodesMap[name]
            ?: throw FlutterError("ANCHOR_NOT_FOUND", "Anchor not found: $name", null)

        val cloudAnchorNode = CloudAnchorNode(sceneView.engine, anchorNode.anchor!!)
        val cloudAnchorId = suspendCancellableCoroutine<String?> { continuation ->
            cloudAnchorNode.host(session) { id, state ->
                if (state == CloudAnchorState.SUCCESS && id != null) {
                    continuation.resume(id)
                } else {
                    Log.e(TAG, "Failed to host cloud anchor: $state")
                    mainScope.launch { sessionFlutterApi.onError("Failed to host cloud anchor: $state") }
                    continuation.resume(null)
                }
            }
            sceneView.addChildNode(cloudAnchorNode)
        }

        if (cloudAnchorId == null) {
            throw FlutterError("HOSTING_ERROR", "Failed to host cloud anchor", null)
        }

        mainScope.launch {
            anchorFlutterApi.onCloudAnchorUploaded(
                CloudAnchorUploadedMessage(name = name, cloudAnchorId = cloudAnchorId),
            )
        }
        return true
    }

    override suspend fun downloadAnchor(cloudAnchorId: String): Boolean {
        val session = sceneView.session ?: run {
            mainScope.launch { sessionFlutterApi.onError("AR Session is not available") }
            throw FlutterError("SESSION_ERROR", "AR Session is not available", null)
        }

        val resolvedNode = suspendCancellableCoroutine<AnchorNode?> { continuation ->
            CloudAnchorNode.resolve(sceneView.engine, session, cloudAnchorId) { state, node ->
                if (!state.isError && node != null) {
                    continuation.resume(node)
                } else {
                    mainScope.launch { sessionFlutterApi.onError("Failed to resolve cloud anchor: $state") }
                    continuation.resume(null)
                }
            }
        }

        val node = resolvedNode
            ?: throw FlutterError("RESOLVE_ERROR", "Failed to resolve cloud anchor", null)
        sceneView.addChildNode(node)

        val anchorPose = node.anchor?.pose
        val anchorData = AnchorMessage(
            type = 0,
            // Native doesn't know the eventual Dart-assigned name yet; the cloud anchor
            // id is the best identifier available until Dart's onAnchorDownloadSuccess
            // response comes back.
            name = cloudAnchorId,
            transformation = anchorPose?.let { serializePose(it).toList() } ?: List(16) { 0.0 },
            cloudAnchorId = cloudAnchorId,
        )

        val anchorName = try {
            anchorFlutterApi.onAnchorDownloadSuccess(anchorData)
        } catch (e: Exception) {
            mainScope.launch {
                sessionFlutterApi.onError("Error registering downloaded anchor: ${e.message}")
            }
            throw FlutterError("DOWNLOAD_ANCHOR_ERROR", e.message, null)
        }

        anchorNodesMap[anchorName] = node
        return true
    }

    override fun getView(): View = rootLayout

    override fun dispose() {
        teardown()
    }

    // Guards teardown() against running twice: Dart calling ARSessionManager.dispose()
    // and the Flutter framework calling PlatformView.dispose() when the view is removed
    // both route here, and the documented usage is to call both in that order.
    private var isTornDown = false

    private fun teardown() {
        if (isTornDown) return
        isTornDown = true
        Log.i(TAG, "dispose: viewId=$viewId lifecycleState=${lifecycle.currentState}")
        ARSessionHostApi.setUp(messenger, null, channelSuffix)
        ARObjectHostApi.setUp(messenger, null, channelSuffix)
        ARAnchorHostApi.setUp(messenger, null, channelSuffix)
        nodesMap.clear()
        sceneView.destroy()
        pointCloudNodes.toList().forEach { removePointCloudNode(it) }
        pointCloudModelInstances.clear()
    }

    /**
     * Implements [ARSessionHostApi] as a separate class rather than directly on
     * [ArView]: `ARSessionHostApi.dispose()` and [PlatformView.dispose] share the
     * same name but are unrelated contracts (one Dart-triggered, one
     * Flutter-framework-triggered), and Kotlin rejects a class that inherits two
     * conflicting `dispose()` members from different supertypes.
     */
    private inner class SessionApiHandler : ARSessionHostApi {
        override suspend fun initialize(config: SessionConfigMessage) = initSession(config)
        override suspend fun showPlanes(showPlanes: Boolean) = showPlanesImpl(showPlanes)
        override suspend fun dispose() = teardown()
        override suspend fun getAnchorPose(anchorId: String): PoseMessage = getAnchorPoseImpl(anchorId)
        override suspend fun getCameraPose(): PoseMessage = getCameraPoseImpl()
        override suspend fun snapshot(): ByteArray = snapshotImpl()
        override suspend fun disableCamera() = disableCameraImpl()
        override suspend fun enableCamera() = enableCameraImpl()
    }

    private fun getPointCloudModelInstance(): ModelInstance? {
        if (pointCloudModelInstances.isEmpty()) {
            pointCloudModelInstances =
                sceneView.modelLoader
                    .createInstancedModel(
                        assetFileLocation = "models/point_cloud.glb",
                        count = 1000,
                    ).toMutableList()
        }
        return pointCloudModelInstances.removeLastOrNull()
    }

    private fun addPointCloudNode(
        id: Int,
        position: Position,
        confidence: Float,
    ) {
        if (pointCloudNodes.size < 1000) { // Max point limit
            getPointCloudModelInstance()?.let { modelInstance ->
                val pointCloudNode =
                    PointCloudNode(
                        modelInstance = modelInstance,
                        id = id,
                        confidence = confidence,
                    ).apply {
                        this.position = position
                    }
                pointCloudNodes += pointCloudNode
                sceneView.addChildNode(pointCloudNode)
            }
        }
    }

    private fun removePointCloudNode(pointCloudNode: PointCloudNode) {
        pointCloudNodes -= pointCloudNode
        sceneView.removeChildNode(pointCloudNode)
        // Deliberately NOT calling pointCloudNode.destroy() here: Node.destroy() (via
        // ModelNode) destroys the FilamentInstance's own root entity
        // (ModelLoader.createInstancedModel constructs each ModelNode with
        // entity = modelInstance.root), permanently invalidating that pooled instance.
        // Since every <10fps point-cloud refresh removes and re-adds up to 1000 nodes,
        // destroying the entity here meant pointCloudModelInstances was drained (never
        // refilled) within the first refresh or two, after which every subsequent
        // refresh's getPointCloudModelInstance() call hit the
        // pointCloudModelInstances.isEmpty() branch and called createInstancedModel()
        // again - allocating a brand-new FilamentAsset (with its own point_cloud.glb
        // vertex/texture buffers, confirmed via decompiling ModelLoader.createInstancedModel:
        // it appends the new asset to ModelLoader's internal `models` list and never
        // reuses or destroys the previous one) roughly once per pool depletion, for as
        // long as showFeaturePoints stayed enabled. Those orphaned assets are only ever
        // cleaned up when the whole ArSceneView/ModelLoader is torn down
        // (ModelLoader.destroy() -> clear() -> destroyModel() for every tracked asset),
        // so this was an unbounded native/GPU memory leak for the lifetime of the AR
        // session. Returning the still-alive instance to the pool instead lets it be
        // reused on the next refresh, keeping the pool's total instance count bounded at
        // the original 1000 and eliminating the repeated asset allocation entirely.
        pointCloudModelInstances.add(pointCloudNode.modelInstance)
    }

    private fun makeWorldOriginNode(context: Context): Node {
        val axisSize = 0.1f
        val axisRadius = 0.005f

        val engine = sceneView.engine
        val materialLoader = MaterialLoader(engine, context)

        val rootNode = Node(engine = engine)

        val xNode = CylinderNode(
            engine = engine,
            radius = axisRadius,
            height = axisSize,
            materialInstance = materialLoader.createColorInstance(
                color = colorOf(1f, 0f, 0f, 1f),
                metallic = 0.0f,
                roughness = 0.4f
            )
        )

        val yNode = CylinderNode(
            engine = engine,
            radius = axisRadius,
            height = axisSize,
            materialInstance = materialLoader.createColorInstance(
                color = colorOf(0f, 1f, 0f, 1f),
                metallic = 0.0f,
                roughness = 0.4f
            )
        )

        val zNode = CylinderNode(
            engine = engine,
            radius = axisRadius,
            height = axisSize,
            materialInstance = materialLoader.createColorInstance(
                color = colorOf(0f, 0f, 1f, 1f),
                metallic = 0.0f,
                roughness = 0.4f
            )
        )

        rootNode.addChildNode(xNode)
        rootNode.addChildNode(yNode)
        rootNode.addChildNode(zNode)

        xNode.position = Position(axisSize / 2, 0f, 0f)
        xNode.rotation = Rotation(0f, 0f, 90f)

        yNode.position = Position(0f, axisSize / 2, 0f)

        zNode.position = Position(0f, 0f, axisSize / 2)
        zNode.rotation = Rotation(90f, 0f, 0f)

        return rootNode
    }

    private fun handleShowWorldOrigin(show: Boolean) {
        if (show) {
            if (worldOriginNode == null) {
                worldOriginNode = makeWorldOriginNode(viewContext)
            }
            worldOriginNode?.let { node ->
                sceneView.addChildNode(node)
            }
        } else {
            worldOriginNode?.let { node ->
                sceneView.removeChildNode(node)
            }
            worldOriginNode = null
        }
    }
}
