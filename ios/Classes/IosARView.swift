import Flutter
import UIKit
import Foundation
import ARKit
import Combine
import ARCoreCloudAnchors

class IosARView: NSObject, FlutterPlatformView, ARSCNViewDelegate, UIGestureRecognizerDelegate, ARSessionDelegate, ARSessionHostApi, ARObjectHostApi, ARAnchorHostApi {
    let sceneView: ARSCNView
    let coachingView: ARCoachingOverlayView
    let messenger: FlutterBinaryMessenger
    let channelSuffix: String
    let sessionFlutterApi: ARSessionFlutterApi
    let objectFlutterApi: ARObjectFlutterApi
    let anchorFlutterApi: ARAnchorFlutterApi
    var showPlanes = false
    var planeCount = 0
    var customPlaneTexturePath: String? = nil
    private var trackedPlanes = [UUID: (SCNNode, SCNNode)]()
    let modelBuilder = ArModelBuilder()

    var cancellableCollection = Set<AnyCancellable>() //Used to store all cancellables in (needed for working with Futures)
    var anchorCollection = [String: ARAnchor]() //Used to bookkeep all anchors created by Flutter calls

    private var cloudAnchorHandler: CloudAnchorHandler? = nil
    private var arcoreSession: GARSession? = nil
    private var arcoreMode: Bool = false
    private var configuration: ARWorldTrackingConfiguration!
    private var tappedPlaneAnchorAlignment = ARPlaneAnchor.Alignment.horizontal // default alignment

    private var panStartLocation: CGPoint?
    private var panCurrentLocation: CGPoint?
    private var panCurrentVelocity: CGPoint?
    private var panCurrentTranslation: CGPoint?
    private var rotationStartLocation: CGPoint?
    private var rotation: CGFloat?
    private var rotationVelocity: CGFloat?
    private var panningNode: SCNNode?
    private var panningNodeCurrentWorldLocation: SCNVector3?

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.sceneView = ARSCNView(frame: frame)
        self.coachingView = ARCoachingOverlayView(frame: frame)

        self.messenger = messenger
        let channelSuffix = String(viewId)
        self.channelSuffix = channelSuffix
        self.sessionFlutterApi = ARSessionFlutterApi(binaryMessenger: messenger, messageChannelSuffix: channelSuffix)
        self.objectFlutterApi = ARObjectFlutterApi(binaryMessenger: messenger, messageChannelSuffix: channelSuffix)
        self.anchorFlutterApi = ARAnchorFlutterApi(binaryMessenger: messenger, messageChannelSuffix: channelSuffix)
        super.init()

        let configuration = ARWorldTrackingConfiguration() // Create default configuration before initialize(config:) is called
        self.sceneView.delegate = self
        self.coachingView.delegate = self
        self.sceneView.session.run(configuration)
        self.sceneView.session.delegate = self

        ARSessionHostApiSetup.setUp(binaryMessenger: messenger, api: self, messageChannelSuffix: channelSuffix)
        ARObjectHostApiSetup.setUp(binaryMessenger: messenger, api: self, messageChannelSuffix: channelSuffix)
        ARAnchorHostApiSetup.setUp(binaryMessenger: messenger, api: self, messageChannelSuffix: channelSuffix)
    }

    func view() -> UIView {
        return self.sceneView
    }

    // MARK: - ARSessionHostApi

    func initialize(config: SessionConfigMessage) async throws {
        // Set plane detection configuration
        self.configuration = ARWorldTrackingConfiguration()
        self.configuration.environmentTexturing = .automatic
        switch config.planeDetectionConfig {
            case 1:
                configuration.planeDetection = .horizontal
            case 2:
                if #available(iOS 11.3, *) {
                    configuration.planeDetection = .vertical
                }
            case 3:
                if #available(iOS 11.3, *) {
                    configuration.planeDetection = [.horizontal, .vertical]
                }
            default:
                configuration.planeDetection = []
        }

        // Set plane rendering options
        showPlanes = config.showPlanes
        if showPlanes {
            // Visualize currently tracked planes
            for plane in trackedPlanes.values {
                plane.0.addChildNode(plane.1)
            }
        } else {
            // Remove currently visualized planes
            for plane in trackedPlanes.values {
                plane.1.removeFromParentNode()
            }
        }
        if let configCustomPlaneTexturePath = config.customPlaneTexturePath {
            customPlaneTexturePath = configCustomPlaneTexturePath
        }

        // Set debug options
        var debugOptions = ARSCNDebugOptions().rawValue
        if config.showFeaturePoints {
            debugOptions |= ARSCNDebugOptions.showFeaturePoints.rawValue
        }
        if config.showWorldOrigin {
            debugOptions |= ARSCNDebugOptions.showWorldOrigin.rawValue
        }
        self.sceneView.debugOptions = ARSCNDebugOptions(rawValue: debugOptions)

        if config.handleTaps {
            let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tapGestureRecognizer.delegate = self
            self.sceneView.gestureRecognizers?.append(tapGestureRecognizer)
        }

        if config.handlePans {
            let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            panGestureRecognizer.maximumNumberOfTouches = 1
            panGestureRecognizer.delegate = self
            self.sceneView.gestureRecognizers?.append(panGestureRecognizer)
        }

        if config.handleRotation {
            let rotationGestureRecognizer = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
            rotationGestureRecognizer.delegate = self
            self.sceneView.gestureRecognizers?.append(rotationGestureRecognizer)
        }

        // Add coaching view
        if config.showAnimatedGuide {
            if self.sceneView.superview != nil && self.coachingView.superview == nil {
                self.sceneView.addSubview(self.coachingView)
                self.coachingView.autoresizingMask = [
                      .flexibleWidth, .flexibleHeight
                    ]
                self.coachingView.session = self.sceneView.session
                self.coachingView.activatesAutomatically = true
                if configuration.planeDetection == .horizontal {
                    self.coachingView.goal = .horizontalPlane
                } else {
                    self.coachingView.goal = .verticalPlane
                }
            }
        }

        // Update session configuration
        self.sceneView.session.run(configuration)
    }

    func showPlanes(showPlanes: Bool) async throws {
        self.showPlanes = showPlanes
        if showPlanes {
            // Visualize currently tracked planes
            for plane in trackedPlanes.values {
                plane.0.addChildNode(plane.1)
            }
        } else {
            // Remove currently visualized planes
            for plane in trackedPlanes.values {
                plane.1.removeFromParentNode()
            }
        }
    }

    func dispose() async throws {
        sceneView.session.pause()
        ARSessionHostApiSetup.setUp(binaryMessenger: messenger, api: nil, messageChannelSuffix: channelSuffix)
        ARObjectHostApiSetup.setUp(binaryMessenger: messenger, api: nil, messageChannelSuffix: channelSuffix)
        ARAnchorHostApiSetup.setUp(binaryMessenger: messenger, api: nil, messageChannelSuffix: channelSuffix)
    }

    func getAnchorPose(anchorId: String) async throws -> PoseMessage {
        guard let anchorTransform = anchorCollection[anchorId]?.transform else {
            throw PigeonError(code: "ANCHOR_NOT_FOUND", message: "Anchor with ID \(anchorId) not found", details: nil)
        }
        return PoseMessage(matrix: serializeMatrix(anchorTransform).map { Double($0) })
    }

    func getCameraPose() async throws -> PoseMessage {
        guard let cameraPose = sceneView.session.currentFrame?.camera.transform else {
            throw PigeonError(code: "NO_CAMERA_POSE", message: "Camera pose is not available", details: nil)
        }
        return PoseMessage(matrix: serializeMatrix(cameraPose).map { Double($0) })
    }

    func snapshot() async throws -> FlutterStandardTypedData {
        let snapshotImage = sceneView.snapshot()
        guard let bytes = snapshotImage.pngData() else {
            throw PigeonError(code: "SNAPSHOT_ERROR", message: "Failed to capture snapshot", details: nil)
        }
        return FlutterStandardTypedData(bytes: bytes)
    }

    func disableCamera() async throws {
        sceneView.session.pause()
    }

    func enableCamera() async throws {
        sceneView.session.run(configuration)
    }

    // MARK: - ARObjectHostApi

    func initialize() async throws {
        // Nothing to set up: node bookkeeping is lazily initialized and shared
        // with the session's sceneView.
    }

    func addNode(node: NodeMessage) async throws -> Bool {
        await withCheckedContinuation { continuation in
            self.loadNode(dict_node: nodeDict(from: node)).sink(receiveCompletion: { _ in }, receiveValue: { val in
                continuation.resume(returning: val)
            }).store(in: &self.cancellableCollection)
        }
    }

    func addNodeToPlaneAnchor(node: NodeMessage, anchor: AnchorMessage) async throws -> Bool {
        await withCheckedContinuation { continuation in
            self.loadNode(dict_node: nodeDict(from: node), dict_anchor: anchorDict(from: anchor)).sink(receiveCompletion: { _ in }, receiveValue: { val in
                continuation.resume(returning: val)
            }).store(in: &self.cancellableCollection)
        }
    }

    func removeNode(name: String) async throws {
        sceneView.scene.rootNode.childNode(withName: name, recursively: true)?.removeFromParentNode()
    }

    func transformationChanged(name: String, transformation: [Double]) async throws {
        transformNode(name: name, transform: transformation.map { NSNumber(value: $0) })
    }

    // MARK: - ARAnchorHostApi

    func addAnchor(anchor: AnchorMessage) async throws -> Bool {
        guard anchor.type == 0 else { return false } // only plane anchors are supported
        addPlaneAnchor(transform: anchor.transformation.map { NSNumber(value: $0) }, name: anchor.name)
        return true
    }

    func removeAnchor(name: String) async throws {
        deleteAnchor(anchorName: name)
    }

    func initGoogleCloudAnchorMode() async throws -> Bool {
        guard let session = try? GARSession.session() else {
            Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Error initializing Google AR Session") }
            throw PigeonError(code: "CLOUD_ANCHOR_INIT_ERROR", message: "Error initializing Google AR Session", details: nil)
        }
        arcoreSession = session

        let configuration = GARSessionConfiguration()
        configuration.cloudAnchorMode = .enabled
        session.setConfiguration(configuration, error: nil)

        guard let token = JWTGenerator().generateWebToken() else {
            let message = "Error generating JWT, have you added cloudAnchorKey.json into the ios/Runner directory ?"
            Task { @MainActor in try? await self.sessionFlutterApi.onError(message: message) }
            throw PigeonError(code: "CLOUD_ANCHOR_INIT_ERROR", message: message, details: nil)
        }
        session.setAuthToken(token)

        cloudAnchorHandler = CloudAnchorHandler(session: session)
        session.delegate = cloudAnchorHandler
        session.delegateQueue = DispatchQueue.main
        arcoreMode = true
        return true
    }

    func uploadAnchor(name: String) async throws -> Bool {
        guard let anchor = anchorCollection[name] else { return false }
        print("---------------- HOSTING INITIATED ------------------")
        // Cloud anchor upload success/failure is reported asynchronously through
        // cloudAnchorUploadedListener (onCloudAnchorUploaded / onError), since the
        // ARCore Cloud Anchor SDK's host callback can fire well after this call
        // returns - this only confirms the upload was kicked off.
        cloudAnchorHandler?.hostCloudAnchor(anchorName: name, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self))
        return true
    }

    func downloadAnchor(cloudAnchorId: String) async throws -> Bool {
        print("---------------- RESOLVING INITIATED ------------------")
        // Like uploadAnchor, resolution success/failure is reported asynchronously
        // through cloudAnchorDownloadedListener (onAnchorDownloadSuccess / onError).
        cloudAnchorHandler?.resolveCloudAnchor(anchorId: cloudAnchorId, listener: cloudAnchorDownloadedListener(parent: self))
        return true
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {

        if let planeAnchor = anchor as? ARPlaneAnchor{
            let plane = modelBuilder.makePlane(anchor: planeAnchor, flutterAssetFile: customPlaneTexturePath)
            trackedPlanes[anchor.identifier] = (node, plane)
            planeCount += 1
            let count = Int64(planeCount)
            Task { @MainActor in try? await self.sessionFlutterApi.onPlaneDetected(count: count) }
            if (showPlanes) {
                node.addChildNode(plane)
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {

        if let planeAnchor = anchor as? ARPlaneAnchor, let plane = trackedPlanes[anchor.identifier] {
            modelBuilder.updatePlaneNode(planeNode: plane.1, anchor: planeAnchor)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        trackedPlanes.removeValue(forKey: anchor.identifier)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if (arcoreMode) {
            do {
                try arcoreSession!.update(frame)
            } catch {
                print(error)
            }
        }
    }

    private func nodeDict(from node: NodeMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "type": Int(node.type),
            "name": node.name,
            "transformation": node.transformation.map { NSNumber(value: $0) },
        ]
        if let uri = node.uri {
            dict["uri"] = uri
        }
        return dict
    }

    private func anchorDict(from anchor: AnchorMessage) -> [String: Any] {
        return [
            "type": Int(anchor.type),
            "name": anchor.name,
            "transformation": anchor.transformation.map { NSNumber(value: $0) },
        ]
    }

    private func localTransform(of node: SCNNode) -> [Double] {
        let t = node.transform
        return [t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24, t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44].map { Double($0) }
    }

    private func hitTestResultMessage(from result: ARHitTestResult) -> HitTestResultMessage {
        let type: Int64
        if (result.type == .existingPlaneUsingExtent || result.type == .existingPlaneUsingGeometry || result.type == .existingPlane) {
            type = 1
        } else if (result.type == .featurePoint) {
            type = 2
        } else {
            type = 0
        }
        return HitTestResultMessage(
            type: type,
            distance: result.distance,
            worldTransform: serializeMatrix(result.worldTransform).map { Double($0) }
        )
    }

    // Resolves `relativeUri` against the app's Documents directory and returns nil
    // if the result would escape it (e.g. via a "../" path-traversal segment).
    // `node.uri` is developer-supplied on the Dart side, but a host app that
    // forwards an externally-controlled string (e.g. from a server-driven model
    // catalog) without validating it could otherwise reach arbitrary files the
    // app's own sandbox can read/write.
    private func resolveWithinDocuments(_ relativeUri: String) -> String? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resolved = documentsDirectory.appendingPathComponent(relativeUri).standardizedFileURL
        let base = documentsDirectory.standardizedFileURL
        if resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") {
            return resolved.path
        }
        return nil
    }

    func loadNode(dict_node: Dictionary<String, Any>, dict_anchor: Dictionary<String, Any>? = nil) -> Future<Bool, Never> {

        return Future {promise in

            switch (dict_node["type"] as! Int) {
                case 0: // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    let key = FlutterDartProject.lookupKey(forAsset: dict_node["uri"] as! String)
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromGltf(name: dict_node["name"] as! String, modelPath: key, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }

                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        let uri = dict_node["uri"] as! String
                        Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Unable to load renderable \(uri)") }
                        promise(.success(false))
                    }
                    break
                case 1: // GLB Model from the web
                    // Add object to scene
                    self.modelBuilder.makeNodeFromWebGlb(name: dict_node["name"] as! String, modelURL: dict_node["uri"] as! String, transformation: dict_node["transformation"] as? Array<NSNumber>)
                    .sink(receiveCompletion: {
                                    completion in print("Async Model Downloading Task completed: ", completion)
                    }, receiveValue: { val in
                        if let node: SCNNode = val {
                            if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                                switch anchorType{
                                    case 0: //PlaneAnchor
                                        if let anchor = self.anchorCollection[anchorName]{
                                            // Attach node to the top-level node of the specified anchor
                                            self.sceneView.node(for: anchor)?.addChildNode(node)
                                            promise(.success(true))
                                        } else {
                                            promise(.success(false))
                                        }
                                    default:
                                        promise(.success(false))
                                    }

                            } else {
                                // Attach to top-level node of the scene
                                self.sceneView.scene.rootNode.addChildNode(node)
                                promise(.success(true))
                            }
                            promise(.success(false))
                        } else {
                            let name = dict_node["name"] as! String
                            Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Unable to load renderable \(name)") }
                            promise(.success(false))
                        }
                    }).store(in: &self.cancellableCollection)
                    break
                case 2: // GLB Model from the app's documents folder
                    // Get path to given file system asset
                    guard let targetPath = self.resolveWithinDocuments(dict_node["uri"] as! String) else {
                        Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Invalid uri: path escapes the app's documents folder") }
                        promise(.success(false))
                        break
                    }

                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGLB(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }

                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        let uri = dict_node["uri"] as! String
                        Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Unable to load renderable \(uri)") }
                        promise(.success(false))
                    }
                    break
                case 3: //fileSystemAppFolderGLTF2
                    // Get path to given file system asset
                    guard let targetPath = self.resolveWithinDocuments(dict_node["uri"] as! String) else {
                        Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Invalid uri: path escapes the app's documents folder") }
                        promise(.success(false))
                        break
                    }

                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGltf(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }

                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        let uri = dict_node["uri"] as! String
                        Task { @MainActor in try? await self.sessionFlutterApi.onError(message: "Unable to load renderable \(uri)") }
                        promise(.success(false))
                    }
                    break
                default:
                    promise(.success(false))
            }

        }
    }

    func transformNode(name: String, transform: Array<NSNumber>) {
        let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true)
        node?.transform = deserializeMatrix4(transform)
    }

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }
        let touchLocation = recognizer.location(in: sceneView)

        let allHitResults = sceneView.hitTest(touchLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
        // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
        let nodeHitResults: Array<String> = allHitResults.compactMap { nearestParentWithNameStart(node: $0.node, characters: "[#")?.name }
        if (nodeHitResults.count != 0) {
            let names = Array(Set(nodeHitResults)) // Chaining of Array and Set is used to remove duplicates
            Task { @MainActor in try? await self.objectFlutterApi.onNodeTap(names: names) }
            return
        }

        let planeTypes: ARHitTestResult.ResultType
        if #available(iOS 11.3, *){
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingGeometry, .featurePoint])
        }else {
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingExtent, .featurePoint])
        }

        let planeAndPointHitResults = sceneView.hitTest(touchLocation, types: planeTypes)

        // store the alignment of the tapped plane anchor so we can refer to is later when transforming the node
        if planeAndPointHitResults.count > 0, let hitAnchor = planeAndPointHitResults.first?.anchor as? ARPlaneAnchor {
            self.tappedPlaneAnchorAlignment = hitAnchor.alignment
        }

        let hits = planeAndPointHitResults.map { hitTestResultMessage(from: $0) }
        if (hits.count != 0) {
            Task { @MainActor in try? await self.sessionFlutterApi.onPlaneOrPointTap(hits: hits) }
        }
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            panStartLocation = recognizer.location(in: sceneView)
            if let startLocation = panStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    panningNodeCurrentWorldLocation = panningNode!.worldPosition
                    if let name = panningNode!.name {
                        Task { @MainActor in try? await self.objectFlutterApi.onPanStart(name: name) }
                    }
                    return
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            panCurrentVelocity = recognizer.velocity(in: sceneView)
            panCurrentLocation = recognizer.location(in: sceneView)
            panCurrentTranslation = recognizer.translation(in: sceneView)

            if let panLoc = panCurrentLocation, let panNode = panningNode {
                if let query = sceneView.raycastQuery(from: panLoc, allowing: .estimatedPlane, alignment: .any) {
                    guard let result = self.sceneView.session.raycast(query).first else {
                        return
                    }
                    let posX = result.worldTransform.columns.3.x
                    let posY = result.worldTransform.columns.3.y
                    let posZ = result.worldTransform.columns.3.z
                    panNode.worldPosition = SCNVector3(posX, posY, posZ)
                }
                if let name = panNode.name {
                    Task { @MainActor in try? await self.objectFlutterApi.onPanChange(name: name) }
                }
            }
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            panStartLocation = nil
            panCurrentLocation = nil
            if let node = panningNode, let name = node.name {
                let event = NodeTransformEventMessage(name: name, transform: localTransform(of: node))
                Task { @MainActor in try? await self.objectFlutterApi.onPanEnd(event: event) }
            }
            panningNode = nil
        }
    }

    @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            rotationStartLocation = recognizer.location(in: sceneView)
            if let startLocation = rotationStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    if let name = panningNode!.name {
                        Task { @MainActor in try? await self.objectFlutterApi.onRotationStart(name: name) }
                    }
                    return
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            rotation = recognizer.rotation
            rotationVelocity = recognizer.velocity

            if let r = rotationVelocity, let panNode = panningNode {
                // velocity needs to be reduced substantially otherwise the rotation change seems too fast as radians; also needs inverting to match the movement of the fingers as they rotate on the screen
                let r2 = (r*0.01) * -1
                let nodeRotation = panNode.rotation
                let rotation: SCNQuaternion!
                let planeAlignment = self.tappedPlaneAnchorAlignment
                if planeAlignment == .horizontal {
                    rotation = SCNQuaternion(x: 0, y: 1, z: 0, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }else{
                    rotation = SCNQuaternion(x: 0, y: 0, z: 1, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }
                panNode.rotation = rotation
                if let name = panNode.name {
                    Task { @MainActor in try? await self.objectFlutterApi.onRotationChange(name: name) }
                }
            }

            // update position of panning node if it has been created
            // panningNode.position + the gesture delta
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            rotation = nil
            rotationVelocity = nil
            if let node = panningNode, let name = node.name {
                let event = NodeTransformEventMessage(name: name, transform: localTransform(of: node))
                Task { @MainActor in try? await self.objectFlutterApi.onRotationEnd(event: event) }
            }
            panningNode = nil
        }

    }

    // Recursive helper function to traverse a node's parents until a node with a name starting with the specified characters is found
    func nearestParentWithNameStart(node: SCNNode?, characters: String) -> SCNNode? {
        if let nodeNamePrefix = node?.name?.prefix(characters.count) {
            if (nodeNamePrefix == characters) { return node }
        }
        if let parent = node?.parent { return nearestParentWithNameStart(node: parent, characters: characters) }
        return nil
    }

    func addPlaneAnchor(transform: Array<NSNumber>, name: String){
        let arAnchor = ARAnchor(transform: simd_float4x4(deserializeMatrix4(transform)))
        anchorCollection[name] = arAnchor
        sceneView.session.add(anchor: arAnchor)
        // Ensure root node is added to anchor before any other function can run (if this isn't done, addNode could fail because anchor does not have a root node yet).
        // The root node is added to the anchor as soon as the async rendering loop runs once, more specifically the function "renderer(_:nodeFor:)"
        while (sceneView.node(for: arAnchor) == nil) {
            usleep(1) // wait 1 millionth of a second
        }
    }

    func deleteAnchor(anchorName: String) {
        if let anchor = anchorCollection[anchorName]{
            // Delete all child nodes
            if var attachedNodes = sceneView.node(for: anchor)?.childNodes {
                attachedNodes.removeAll()
            }
            // Remove anchor
            sceneView.session.remove(anchor: anchor)
            // Update bookkeeping
            anchorCollection.removeValue(forKey: anchorName)
        }
    }

    private class cloudAnchorUploadedListener: CloudAnchorListener {
        private var parent: IosARView

        init(parent: IosARView) {
            self.parent = parent
        }

        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success), let cloudId = anchor?.cloudIdentifier, let name = anchorName {
                    let event = CloudAnchorUploadedMessage(name: name, cloudAnchorId: cloudId)
                    Task { @MainActor in try? await self.parent.anchorFlutterApi.onCloudAnchorUploaded(event: event) }
                } else {
                    print("Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))")
                    let message = "Error uploading anchor, state: \(self.parent.decodeCloudAnchorState(state: cloudState))"
                    Task { @MainActor in try? await self.parent.sessionFlutterApi.onError(message: message) }
                    return
                }
            }
        }
    }

    private class cloudAnchorDownloadedListener: CloudAnchorListener {
        private var parent: IosARView

        init(parent: IosARView) {
            self.parent = parent
        }

        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            guard let cloudState = anchor?.cloudState else { return }
            guard cloudState == GARCloudAnchorState.success, let garAnchor = anchor else {
                print("Error downloading anchor, state \(cloudState)")
                let message = "Error downloading anchor, state \(cloudState)"
                Task { @MainActor in try? await self.parent.sessionFlutterApi.onError(message: message) }
                return
            }
            let newAnchor = ARAnchor(transform: garAnchor.transform)
            let anchorMessage = AnchorMessage(
                type: 0,
                name: anchorName ?? garAnchor.cloudIdentifier ?? UUID().uuidString,
                transformation: serializeMatrix(newAnchor.transform).map { Double($0) },
                childNodes: nil,
                cloudAnchorId: garAnchor.cloudIdentifier
            )
            Task { @MainActor in
                do {
                    let resolvedName = try await self.parent.anchorFlutterApi.onAnchorDownloadSuccess(anchor: anchorMessage)
                    self.parent.sceneView.session.add(anchor: newAnchor)
                    self.parent.anchorCollection[resolvedName] = newAnchor
                } catch {
                    try? await self.parent.sessionFlutterApi.onError(message: "Error while registering downloaded anchor at the AR Flutter plugin")
                }
            }
        }
    }

    func decodeCloudAnchorState(state: GARCloudAnchorState) -> String {
        switch state {
        case .errorCloudIdNotFound:
            return "Cloud anchor id not found"
        case .errorHostingDatasetProcessingFailed:
            return "Dataset processing failed, feature map insufficient"
        case .errorHostingServiceUnavailable:
            return "Hosting service unavailable"
        case .errorInternal:
            return "Internal error"
        case .errorNotAuthorized:
            return "Authentication failed: Not Authorized"
        case .errorResolvingSdkVersionTooNew:
            return "Resolving Sdk version too new"
        case .errorResolvingSdkVersionTooOld:
            return "Resolving Sdk version too old"
        case .errorResourceExhausted:
            return " Resource exhausted"
        case .none:
            return "Empty state"
        case .taskInProgress:
            return "Task in progress"
        case .success:
            return "Success"
        case .errorServiceUnavailable:
            return "Cloud Anchor Service unavailable"
        case .errorResolvingLocalizationNoMatch:
            return "No match"
        @unknown default:
            return "Unknown"
        }
    }
}

// ---------------------- ARCoachingOverlayViewDelegate ---------------------------------------

extension IosARView: ARCoachingOverlayViewDelegate {

    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView){
        // use this delegate method to hide anything in the UI that could cover the coaching overlay view
    }

    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        // Reset the session.
        self.sceneView.session.run(configuration, options: [.resetTracking])
    }
}
