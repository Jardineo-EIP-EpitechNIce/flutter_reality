import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reality/datatypes/config_planedetection.dart';
import 'package:flutter_reality/managers/ar_anchor_manager.dart';
import 'package:flutter_reality/managers/ar_location_manager.dart';
import 'package:flutter_reality/managers/ar_object_manager.dart';
import 'package:flutter_reality/managers/ar_session_manager.dart';

/// Simulates a native platform call arriving on [channelName], the way real
/// native code would invoke a Dart-side `setMethodCallHandler`.
Future<void> simulateNativeCall(
  String channelName,
  String method,
  dynamic arguments,
) {
  final data = const StandardMethodCodec()
      .encodeMethodCall(MethodCall(method, arguments));
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channelName, data, (ByteData? _) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ARSessionManager', () {
    testWidgets(
        'does not throw when a plane/tap event arrives with no callback set',
        (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }));

      ARSessionManager(
        2,
        capturedContext,
        PlaneDetectionConfig.horizontalAndVertical,
      );

      // onPlaneOrPointTap and onPlaneDetected are left unset (null) on purpose.
      await simulateNativeCall('arsession_2', 'onPlaneDetected', 3);
      await simulateNativeCall('arsession_2', 'onPlaneOrPointTap', <dynamic>[]);
    });

    testWidgets('forwards a detected plane count to onPlaneDetected',
        (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }));

      final manager = ARSessionManager(
        3,
        capturedContext,
        PlaneDetectionConfig.horizontalAndVertical,
      );

      int? reportedCount;
      manager.onPlaneDetected = (count) => reportedCount = count;

      await simulateNativeCall('arsession_3', 'onPlaneDetected', 5);

      expect(reportedCount, 5);
    });
  });

  group('ARAnchorManager', () {
    test('forwards a native error to onError', () async {
      final manager = ARAnchorManager(4);
      String? reportedError;
      manager.onError = (error) => reportedError = error;

      await simulateNativeCall('aranchors_4', 'onError', 'anchor failed');

      expect(reportedError, 'anchor failed');
    });
  });

  group('ARObjectManager', () {
    test('forwards a native error to onError', () async {
      final manager = ARObjectManager(5);
      String? reportedError;
      manager.onError = (error) => reportedError = error;

      await simulateNativeCall('arobjects_5', 'onError', 'node failed');

      expect(reportedError, 'node failed');
    });
  });

  group('ARLocationManager', () {
    test('stopLocationUpdates is a no-op if updates were never started',
        () async {
      final manager = ARLocationManager();
      await manager.stopLocationUpdates();
    });
  });
}
