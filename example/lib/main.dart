import 'package:flutter_reality/ar_flutter_plugin.dart';
import 'package:flutter_reality/datatypes/config_planedetection.dart';
import 'package:flutter_reality/datatypes/node_types.dart';
import 'package:flutter_reality/managers/ar_anchor_manager.dart';
import 'package:flutter_reality/managers/ar_location_manager.dart';
import 'package:flutter_reality/managers/ar_object_manager.dart';
import 'package:flutter_reality/managers/ar_session_manager.dart';
import 'package:flutter_reality/models/ar_anchor.dart';
import 'package:flutter_reality/models/ar_hittest_result.dart';
import 'package:flutter_reality/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import 'hit_test_selection.dart';

void main() {
  runApp(const ArExampleApp());
}

class ArExampleApp extends StatelessWidget {
  const ArExampleApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Flutter Plugin Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const ArHomePage(),
    );
  }
}

/// A model placed in the AR scene together with the plane anchor holding it,
/// so both can be torn down together when removed.
class _PlacedModel {
  _PlacedModel(this.anchor, this.node);

  final ARPlaneAnchor anchor;
  final ARNode node;
}

class ArHomePage extends StatefulWidget {
  const ArHomePage({Key? key}) : super(key: key);

  @override
  State<ArHomePage> createState() => _ArHomePageState();
}

class _ArHomePageState extends State<ArHomePage> {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;
  String _status = 'Waiting for camera permission...';
  final List<_PlacedModel> _placedModels = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Flutter Plugin Example')),
      body: Stack(
        children: [
          ARView(
            showPlatformType: true,
            planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
            onARViewCreated: _onARViewCreated,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_status),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed:
                      _placedModels.isEmpty ? null : _removeLastPlacedModel,
                  child: Text('Remove last model (${_placedModels.length})'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _sessionManager = sessionManager;
    _objectManager = objectManager;
    _anchorManager = anchorManager;
    sessionManager.onPlaneOrPointTap = _onPlaneOrPointTap;
    sessionManager.onPlaneDetected = (count) {
      setState(() => _status = '$count plane(s) detected');
    };
    sessionManager.onError = (error) {
      setState(() => _status = 'Error: $error');
    };
    sessionManager.onInitialize(
      showPlanes: true,
      showFeaturePoints: false,
      handleTaps: true,
    );
    objectManager.onInitialize();
    setState(
        () => _status = 'AR session ready. Move the device to scan surfaces.');
  }

  Future<void> _onPlaneOrPointTap(List<ARHitTestResult> hitTestResults) async {
    final hit = selectPlacementHit(hitTestResults);
    if (hit == null) {
      setState(() => _status = 'No plane or point detected under the tap.');
      return;
    }

    final anchorManager = _anchorManager;
    final objectManager = _objectManager;
    if (anchorManager == null || objectManager == null) return;

    setState(() => _status = 'Placing model...');

    final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
    final anchorAdded = await anchorManager.addAnchor(anchor);
    if (anchorAdded != true) {
      setState(() => _status = 'Failed to anchor the tapped surface.');
      return;
    }

    final node = ARNode(
      type: NodeType.localGLTF2,
      uri: 'assets/models/duck.glb',
      scale: Vector3(0.2, 0.2, 0.2),
    );
    final nodeAdded = await objectManager.addNode(node, planeAnchor: anchor);
    if (nodeAdded != true) {
      anchorManager.removeAnchor(anchor);
      setState(() => _status = 'Failed to place the model on the anchor.');
      return;
    }

    setState(() {
      _placedModels.add(_PlacedModel(anchor, node));
      _status = '${_placedModels.length} model(s) placed.';
    });
  }

  Future<void> _removeLastPlacedModel() async {
    if (_placedModels.isEmpty) return;
    final placed = _placedModels.removeLast();
    await _objectManager?.removeNode(placed.node);
    _anchorManager?.removeAnchor(placed.anchor);
    setState(() => _status = '${_placedModels.length} model(s) placed.');
  }

  @override
  void dispose() {
    _sessionManager?.dispose();
    super.dispose();
  }
}
