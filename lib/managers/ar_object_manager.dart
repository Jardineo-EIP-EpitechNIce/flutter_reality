import 'package:flutter_reality/models/ar_anchor.dart';
import 'package:flutter_reality/models/ar_node.dart';
import 'package:flutter_reality/src/generated/messages.g.dart';
import 'package:flutter_reality/utils/json_converters.dart';
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

// Type definitions to enforce a consistent use of the API
typedef NodeTapResultHandler = void Function(List<String> nodes);
typedef NodePanStartHandler = void Function(String node);
typedef NodePanChangeHandler = void Function(String node);
typedef NodePanEndHandler = void Function(String node, Matrix4 transform);
typedef NodeRotationStartHandler = void Function(String node);
typedef NodeRotationChangeHandler = void Function(String node);
typedef NodeRotationEndHandler = void Function(String node, Matrix4 transform);
typedef NodeErrorHandler = void Function(String error);

/// Manages the all node-related actions of an [ARView]
class ARObjectManager {
  late ARObjectHostApi _hostApi;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Callback function that is invoked when the platform detects a tap on a node
  NodeTapResultHandler? onNodeTap;
  NodePanStartHandler? onPanStart;
  NodePanChangeHandler? onPanChange;
  NodePanEndHandler? onPanEnd;
  NodeRotationStartHandler? onRotationStart;
  NodeRotationChangeHandler? onRotationChange;
  NodeRotationEndHandler? onRotationEnd;

  /// Callback that is triggered when the native platform reports a node-related error
  NodeErrorHandler? onError;
  final Map<String, VoidCallback> _transformListeners = {};

  ARObjectManager(int id, {this.debug = false}) {
    final suffix = id.toString();
    _hostApi = ARObjectHostApi(messageChannelSuffix: suffix);
    ARObjectFlutterApi.setUp(_ObjectEventHandler(this),
        messageChannelSuffix: suffix);
    if (debug) {
      print("ARObjectManager initialized");
    }
  }

  /// Sets up the AR Object Manager
  Future<void> onInitialize() => _hostApi.initialize();

  /// Add given node to the given anchor of the underlying AR scene (or to its top-level if no anchor is given) and listen to any changes made to its transformation
  Future<bool?> addNode(ARNode node, {ARPlaneAnchor? planeAnchor}) async {
    try {
      _removeTransformListener(node);
      void listener() {
        _hostApi.transformationChanged(
          node.name,
          MatrixValueNotifierConverter()
              .toJson(node.transformNotifier)
              .cast<double>(),
        );
      }

      _transformListeners[node.name] = listener;
      node.transformNotifier.addListener(listener);
      if (planeAnchor != null) {
        planeAnchor.childNodes.add(node.name);
        final added = await _hostApi.addNodeToPlaneAnchor(
          _toNodeMessage(node),
          _toAnchorMessage(planeAnchor),
        );
        if (added != true) {
          _removeTransformListener(node);
        }
        return added;
      } else {
        final added = await _hostApi.addNode(_toNodeMessage(node));
        if (added != true) {
          _removeTransformListener(node);
        }
        return added;
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
      _removeTransformListener(node);
      return false;
    }
  }

  /// Remove given node from the AR Scene
  Future<void> removeNode(ARNode node) async {
    _removeTransformListener(node);
    await _hostApi.removeNode(node.name);
  }

  void _removeTransformListener(ARNode node) {
    final listener = _transformListeners.remove(node.name);
    if (listener != null) {
      node.transformNotifier.removeListener(listener);
    }
  }

  NodeMessage _toNodeMessage(ARNode node) {
    final map = node.toMap();
    return NodeMessage(
      type: map['type'] as int,
      name: map['name'] as String,
      transformation: (map['transformation'] as List).cast<double>(),
      uri: map['uri'] as String?,
      data: map['data'] as Map<String, dynamic>?,
    );
  }

  AnchorMessage _toAnchorMessage(ARPlaneAnchor anchor) {
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

/// Forwards Pigeon-generated `ARObjectFlutterApi` callbacks to
/// [ARObjectManager]'s public callback fields. Kept as a separate class
/// because the callback field names (`onError`, `onPanEnd`, ...) are
/// intentionally identical to the interface method names, which a class
/// can't both declare as a field and implement as a method.
class _ObjectEventHandler implements ARObjectFlutterApi {
  _ObjectEventHandler(this._manager);

  final ARObjectManager _manager;

  @override
  void onError(String message) {
    if (_manager.debug) {
      print(message);
    }
    _manager.onError?.call(message);
  }

  @override
  void onNodeTap(List<String?> names) {
    _manager.onNodeTap?.call(names.whereType<String>().toList());
  }

  @override
  void onPanStart(String name) => _manager.onPanStart?.call(name);

  @override
  void onPanChange(String name) => _manager.onPanChange?.call(name);

  @override
  void onPanEnd(NodeTransformEventMessage event) {
    _manager.onPanEnd?.call(
      event.name,
      MatrixConverter().fromJson(event.transform),
    );
  }

  @override
  void onRotationStart(String name) => _manager.onRotationStart?.call(name);

  @override
  void onRotationChange(String name) => _manager.onRotationChange?.call(name);

  @override
  void onRotationEnd(NodeTransformEventMessage event) {
    _manager.onRotationEnd?.call(
      event.name,
      MatrixConverter().fromJson(event.transform),
    );
  }
}
