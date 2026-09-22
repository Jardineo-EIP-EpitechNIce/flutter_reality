import 'package:flutter_reality/models/ar_anchor.dart';
import 'package:flutter_reality/src/generated/messages.g.dart';

// Type definitions to enforce a consistent use of the API
/// Signature for [ARAnchorManager.onAnchorUploaded]: receives the anchor
/// that was successfully uploaded to the Google Cloud Anchor API.
typedef AnchorUploadedHandler = void Function(ARAnchor arAnchor);

/// Signature for [ARAnchorManager.onAnchorDownloaded]: receives the
/// serialized anchor downloaded from the Google Cloud Anchor API and must
/// return the [ARAnchor] to add to the scene.
typedef AnchorDownloadedHandler = ARAnchor Function(
    Map<String, dynamic> serializedAnchor);

/// Signature for [ARAnchorManager.onError]: receives a human-readable
/// description of a native anchor-related error.
typedef AnchorErrorHandler = void Function(String error);

/// Handles all anchor-related functionality of an [ARView], including configuration and usage of collaborative sessions
class ARAnchorManager {
  late ARAnchorHostApi _hostApi;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Reference to all anchors that are being uploaded to the google cloud anchor API
  List<ARAnchor> pendingAnchors = [];

  /// Callback that is triggered once an anchor has successfully been uploaded to the google cloud anchor API
  AnchorUploadedHandler? onAnchorUploaded;

  /// Callback that is triggered once an anchor has successfully been downloaded from the google cloud anchor API and resolved within the current scene
  AnchorDownloadedHandler? onAnchorDownloaded;

  /// Callback that is triggered when the native platform reports an anchor-related error
  AnchorErrorHandler? onError;

  /// Creates the anchor manager for the [ARView] platform view identified by
  /// [id]. Consumers normally receive an already-constructed instance
  /// through [ARViewCreatedCallback] rather than calling this directly.
  ARAnchorManager(int id, {this.debug = false}) {
    final suffix = id.toString();
    _hostApi = ARAnchorHostApi(messageChannelSuffix: suffix);
    ARAnchorFlutterApi.setUp(
      _AnchorEventHandler(this),
      messageChannelSuffix: suffix,
    );
    if (debug) {
      print("ARAnchorManager initialized");
    }
  }

  /// Activates collaborative AR mode (using Google Cloud Anchors)
  Future<void> initGoogleCloudAnchorMode() async {
    await _hostApi.initGoogleCloudAnchorMode();
  }

  /// Add given anchor to the underlying AR scene
  Future<bool?> addAnchor(ARAnchor anchor) async {
    try {
      return await _hostApi.addAnchor(_toAnchorMessage(anchor));
    } catch (e) {
      print('Error caught: ' + e.toString());
      return false;
    }
  }

  /// Remove given anchor and all its children from the AR Scene
  Future<void> removeAnchor(ARAnchor anchor) {
    return _hostApi.removeAnchor(anchor.name);
  }

  /// Upload given anchor from the underlying AR scene to the Google Cloud Anchor API
  Future<bool?> uploadAnchor(ARAnchor anchor) async {
    try {
      final response = await _hostApi.uploadAnchor(anchor.name);
      pendingAnchors.add(anchor);
      return response;
    } catch (e) {
      print('Error caught: ' + e.toString());
      return false;
    }
  }

  /// Try to download anchor with the given ID from the Google Cloud Anchor API and add it to the scene
  Future<bool?> downloadAnchor(String cloudanchorid) async {
    print('TRYING TO DOWNLOAD ANCHOR WITH ID $cloudanchorid');
    return await _hostApi.downloadAnchor(cloudanchorid);
  }

  AnchorMessage _toAnchorMessage(ARAnchor anchor) {
    final map = anchor.toJson();
    return AnchorMessage(
      type: map['type'] as int,
      name: map['name'] as String,
      transformation: (map['transformation'] as List).cast<double>(),
      childNodes: (map['childNodes'] as List?)?.cast<String>(),
      cloudAnchorId: map['cloudanchorid'] as String?,
      ttl: map['ttl'] as int?,
    );
  }
}

/// Forwards Pigeon-generated `ARAnchorFlutterApi` callbacks to
/// [ARAnchorManager]'s public callback fields. Kept as a separate class
/// because the callback field names (`onError`, ...) are intentionally
/// identical to the interface method names, which a class can't both
/// declare as a field and implement as a method.
class _AnchorEventHandler implements ARAnchorFlutterApi {
  _AnchorEventHandler(this._manager);

  final ARAnchorManager _manager;

  @override
  void onError(String message) {
    print(message);
    _manager.onError?.call(message);
  }

  @override
  void onCloudAnchorUploaded(CloudAnchorUploadedMessage event) {
    print(
        'UPLOADED ANCHOR WITH ID: ${event.cloudAnchorId}, NAME: ${event.name}');
    final currentAnchor = _manager.pendingAnchors
        .where((element) => element.name == event.name)
        .first;
    (currentAnchor as ARPlaneAnchor).cloudanchorid = event.cloudAnchorId;
    _manager.pendingAnchors.remove(currentAnchor);
    _manager.onAnchorUploaded?.call(currentAnchor);
  }

  @override
  String onAnchorDownloadSuccess(AnchorMessage anchor) {
    final serializedAnchor = <String, dynamic>{
      'type': anchor.type,
      'name': anchor.name,
      'transformation': anchor.transformation,
      'childNodes': anchor.childNodes,
      'cloudanchorid': anchor.cloudAnchorId,
      'ttl': anchor.ttl,
    };
    if (_manager.onAnchorDownloaded != null) {
      final downloaded = _manager.onAnchorDownloaded!(serializedAnchor);
      return downloaded.name;
    }
    return anchor.name;
  }
}
