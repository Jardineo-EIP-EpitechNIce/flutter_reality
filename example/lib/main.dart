import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:flutter/material.dart';

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

class ArHomePage extends StatefulWidget {
  const ArHomePage({Key? key}) : super(key: key);

  @override
  State<ArHomePage> createState() => _ArHomePageState();
}

class _ArHomePageState extends State<ArHomePage> {
  ARSessionManager? _sessionManager;
  String _status = 'Waiting for camera permission...';

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
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status),
              ),
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
    sessionManager.onPlaneOrPointTap = (hits) {
      setState(() => _status = '${hits.length} hit result(s) detected');
    };
    sessionManager.onPlaneDetected = (count) {
      setState(() => _status = '$count plane(s) detected');
    };
    sessionManager.onError = (error) {
      setState(() => _status = error);
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

  @override
  void dispose() {
    _sessionManager?.dispose();
    super.dispose();
  }
}
