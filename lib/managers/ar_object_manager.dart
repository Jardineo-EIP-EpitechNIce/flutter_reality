import 'package:flutter_reality/models/ar_anchor.dart';
import 'package:flutter_reality/models/ar_node.dart';
import 'package:flutter_reality/utils/json_converters.dart';
import 'package:flutter/services.dart';

// Type definitions to enforce a consistent use of the API
typedef NodeTapResultHandler = void Function(List<String> nodes);
typedef NodePanStartHandler = void Function(String node);
typedef NodePanChangeHandler = void Function(String node);
typedef NodePanEndHandler = void Function(String node, Matrix4 transform);
typedef NodeRotationStartHandler = void Function(String node);
typedef NodeRotationChangeHandler = void Function(String node);
typedef NodeRotationEndHandler = void Function(String node, Matrix4 transform);

/// Manages the all node-related actions of an [ARView]
class ARObjectManager {
  /// Platform channel used for communication from and to [ARObjectManager]
  late MethodChannel _channel;

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
  final Map<String, VoidCallback> _transformListeners = {};

  ARObjectManager(int id, {this.debug = false}) {
    _channel = MethodChannel('arobjects_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    if (debug) {
      print("ARObjectManager initialized");
    }
  }

  Future<void> _platformCallHandler(MethodCall call) {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          print(call.arguments);
          break;
        case 'onNodeTap':
          if (onNodeTap != null) {
            final tappedNodes = call.arguments as List<dynamic>;
            onNodeTap!(
              tappedNodes.map((tappedNode) => tappedNode.toString()).toList(),
            );
          }
          break;
        case 'onPanStart':
          if (onPanStart != null) {
            final tappedNode = call.arguments as String;
            // Notify callback
            onPanStart!(tappedNode);
          }
          break;
        case 'onPanChange':
          if (onPanChange != null) {
            final tappedNode = call.arguments as String;
            // Notify callback
            onPanChange!(tappedNode);
          }
          break;
        case 'onPanEnd':
          if (onPanEnd != null) {
            final tappedNodeName = call.arguments["name"] as String;
            final transform = MatrixConverter().fromJson(
              call.arguments['transform'] as List,
            );

            // Notify callback
            onPanEnd!(tappedNodeName, transform);
          }
          break;
        case 'onRotationStart':
          if (onRotationStart != null) {
            final tappedNode = call.arguments as String;
            onRotationStart!(tappedNode);
          }
          break;
        case 'onRotationChange':
          if (onRotationChange != null) {
            final tappedNode = call.arguments as String;
            onRotationChange!(tappedNode);
          }
          break;
        case 'onRotationEnd':
          if (onRotationEnd != null) {
            final tappedNodeName = call.arguments["name"] as String;
            final transform = MatrixConverter().fromJson(
              call.arguments['transform'] as List,
            );

            // Notify callback
            onRotationEnd!(tappedNodeName, transform);
          }
          break;
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
    }
    return Future.value();
  }

  /// Sets up the AR Object Manager
  onInitialize() {
    _channel.invokeMethod<void>('init', {});
  }

  /// Add given node to the given anchor of the underlying AR scene (or to its top-level if no anchor is given) and listen to any changes made to its transformation
  Future<bool?> addNode(ARNode node, {ARPlaneAnchor? planeAnchor}) async {
    try {
      _removeTransformListener(node);
      final listener = () {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation': MatrixValueNotifierConverter().toJson(
            node.transformNotifier,
          ),
        });
      };
      _transformListeners[node.name] = listener;
      node.transformNotifier.addListener(listener);
      if (planeAnchor != null) {
        planeAnchor.childNodes.add(node.name);
        final added = await _channel.invokeMethod<bool>(
          'addNodeToPlaneAnchor',
          {'node': node.toMap(), 'anchor': planeAnchor.toJson()},
        );
        if (added != true) {
          _removeTransformListener(node);
        }
        return added;
      } else {
        final added = await _channel.invokeMethod<bool>(
          'addNode',
          node.toMap(),
        );
        if (added != true) {
          _removeTransformListener(node);
        }
        return added;
      }
    } on PlatformException {
      _removeTransformListener(node);
      return false;
    }
  }

  /// Remove given node from the AR Scene
  Future<void> removeNode(ARNode node) async {
    _removeTransformListener(node);
    await _channel.invokeMethod<void>('removeNode', {'name': node.name});
  }

  void _removeTransformListener(ARNode node) {
    final listener = _transformListeners.remove(node.name);
    if (listener != null) {
      node.transformNotifier.removeListener(listener);
    }
  }
}
