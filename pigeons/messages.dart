// Pigeon schema for flutter_reality's platform channels.
//
// This is the single source of truth for the plugin's Dart <-> native
// communication. Run `dart run pigeon --input pigeons/messages.dart` after
// editing this file, then commit the regenerated files listed below.
//
// Generated outputs:
//  - lib/src/generated/messages.g.dart
//  - android/src/main/kotlin/com/flutterreality/flutter_reality/Messages.g.kt
//  - ios/Classes/Messages.g.swift
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/flutterreality/flutter_reality/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.flutterreality.flutter_reality'),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'flutter_reality',
  ),
)

/// A rigid transform, flattened as a 16-element row-major matrix
/// (matches `Matrix4.storage` / `Matrix4.fromList`).
class PoseMessage {
  PoseMessage({required this.matrix});
  List<double> matrix;
}

/// One entry from an `ARSessionManager.onPlaneOrPointTap` hit test.
class HitTestResultMessage {
  HitTestResultMessage({
    required this.type,
    required this.distance,
    required this.worldTransform,
  });

  /// Mirrors `ARHitTestResultType` (0 = undefined, 1 = plane, 2 = point).
  int type;
  double distance;
  List<double> worldTransform;
}

/// Mirrors `ARNode.toMap()` / `ARNode.fromMap()`.
class NodeMessage {
  NodeMessage({
    required this.type,
    required this.name,
    required this.transformation,
    this.uri,
    this.data,
  });

  /// Mirrors `NodeType.index`.
  int type;
  String name;
  List<double> transformation;
  String? uri;
  Map<String?, Object?>? data;
}

/// Mirrors `ARAnchor.toJson()` / `ARAnchor.fromJson()` (currently only
/// `ARPlaneAnchor` is implemented natively; `ARUnkownAnchor` is a
/// forward-compatible placeholder for anchor types future native code may
/// add, hence the mostly-nullable fields below).
class AnchorMessage {
  AnchorMessage({
    required this.type,
    required this.name,
    required this.transformation,
    this.childNodes,
    this.cloudAnchorId,
    this.ttl,
  });

  /// Mirrors `AnchorType.index` (0 = plane).
  int type;
  String name;
  List<double> transformation;
  List<String?>? childNodes;
  String? cloudAnchorId;
  int? ttl;
}

/// Arguments for `ARSessionManager.onInitialize`.
class SessionConfigMessage {
  SessionConfigMessage({
    this.showAnimatedGuide = true,
    this.showFeaturePoints = false,
    required this.planeDetectionConfig,
    this.showPlanes = true,
    this.customPlaneTexturePath,
    this.showWorldOrigin = false,
    this.handleTaps = true,
    this.handlePans = false,
    this.handleRotation = false,
  });

  bool showAnimatedGuide;
  bool showFeaturePoints;

  /// Mirrors `PlaneDetectionConfig.index`.
  int planeDetectionConfig;
  bool showPlanes;
  String? customPlaneTexturePath;
  bool showWorldOrigin;
  bool handleTaps;
  bool handlePans;
  bool handleRotation;
}

/// Payload for `onPanEnd`/`onRotationEnd`.
class NodeTransformEventMessage {
  NodeTransformEventMessage({required this.name, required this.transform});
  String name;
  List<double> transform;
}

/// Payload for `onCloudAnchorUploaded`.
class CloudAnchorUploadedMessage {
  CloudAnchorUploadedMessage({
    required this.name,
    required this.cloudAnchorId,
  });
  String name;
  String cloudAnchorId;
}

/// The plugin-wide (non-per-instance) API, used only for `getPlatformVersion`.
@HostApi()
abstract class FlutterRealityHostApi {
  @async
  String getPlatformVersion();
}

/// Dart -> native calls scoped to one [ARSessionManager] instance. Each
/// instance registers with a `messageChannelSuffix` derived from its
/// platform view id, replicating today's `arsession_$id` per-instance
/// channel.
@HostApi()
abstract class ARSessionHostApi {
  // Named `initialize`, not `init`: `init` is a reserved word for
  // initializers in Swift and Pigeon emits it as a literal protocol method
  // name there, which does not compile.
  @async
  void initialize(SessionConfigMessage config);

  @async
  void showPlanes(bool showPlanes);

  @async
  void dispose();

  @async
  PoseMessage getAnchorPose(String anchorId);

  @async
  PoseMessage getCameraPose();

  @async
  Uint8List snapshot();

  @async
  void disableCamera();

  @async
  void enableCamera();
}

/// Native -> Dart events scoped to one [ARSessionManager] instance.
@FlutterApi()
abstract class ARSessionFlutterApi {
  void onError(String message);
  void onPlaneDetected(int count);
  void onPlaneOrPointTap(List<HitTestResultMessage> hits);
}

/// Dart -> native calls scoped to one [ARObjectManager] instance.
@HostApi()
abstract class ARObjectHostApi {
  // See the note on ARSessionHostApi.initialize about avoiding `init`.
  @async
  void initialize();

  @async
  bool addNode(NodeMessage node);

  @async
  bool addNodeToPlaneAnchor(NodeMessage node, AnchorMessage anchor);

  @async
  void removeNode(String name);

  @async
  void transformationChanged(String name, List<double> transformation);
}

/// Native -> Dart events scoped to one [ARObjectManager] instance.
@FlutterApi()
abstract class ARObjectFlutterApi {
  void onError(String message);
  void onNodeTap(List<String?> names);
  void onPanStart(String name);
  void onPanChange(String name);
  void onPanEnd(NodeTransformEventMessage event);
  void onRotationStart(String name);
  void onRotationChange(String name);
  void onRotationEnd(NodeTransformEventMessage event);
}

/// Dart -> native calls scoped to one [ARAnchorManager] instance.
@HostApi()
abstract class ARAnchorHostApi {
  @async
  bool initGoogleCloudAnchorMode();

  @async
  bool addAnchor(AnchorMessage anchor);

  @async
  void removeAnchor(String name);

  @async
  bool uploadAnchor(String name);

  @async
  bool downloadAnchor(String cloudAnchorId);
}

/// Native -> Dart events scoped to one [ARAnchorManager] instance.
@FlutterApi()
abstract class ARAnchorFlutterApi {
  void onError(String message);
  void onCloudAnchorUploaded(CloudAnchorUploadedMessage event);

  /// Native waits for Dart's returned anchor name before completing the
  /// download.
  String onAnchorDownloadSuccess(AnchorMessage anchor);
}
