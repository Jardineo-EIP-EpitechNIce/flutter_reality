import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reality/datatypes/config_planedetection.dart';
import 'package:flutter_reality/managers/ar_anchor_manager.dart';
import 'package:flutter_reality/managers/ar_location_manager.dart';
import 'package:flutter_reality/managers/ar_object_manager.dart';
import 'package:flutter_reality/managers/ar_session_manager.dart';
import 'package:flutter_reality/src/generated/messages.g.dart';

/// Simulates a native -> Dart Pigeon `FlutterApi` call arriving on
/// [channelName], the way real native code would invoke it through the
/// generated `BasicMessageChannel`.
Future<void> simulateNativeCall(
  String channelName,
  MessageCodec<Object?> codec,
  List<Object?> args,
) {
  final data = codec.encodeMessage(args);
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channelName, data, (ByteData? _) {});
}

String _channel(String api, String method, int suffix) =>
    'dev.flutter.pigeon.flutter_reality.$api.$method.$suffix';

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
      await simulateNativeCall(
        _channel('ARSessionFlutterApi', 'onPlaneDetected', 2),
        ARSessionFlutterApi.pigeonChannelCodec,
        <Object?>[3],
      );
      await simulateNativeCall(
        _channel('ARSessionFlutterApi', 'onPlaneOrPointTap', 2),
        ARSessionFlutterApi.pigeonChannelCodec,
        <Object?>[<HitTestResultMessage>[]],
      );
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

      await simulateNativeCall(
        _channel('ARSessionFlutterApi', 'onPlaneDetected', 3),
        ARSessionFlutterApi.pigeonChannelCodec,
        <Object?>[5],
      );

      expect(reportedCount, 5);
    });

    testWidgets('forwards hit test results to onPlaneOrPointTap',
        (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(Builder(builder: (context) {
        capturedContext = context;
        return const SizedBox();
      }));

      final manager = ARSessionManager(
        6,
        capturedContext,
        PlaneDetectionConfig.horizontalAndVertical,
      );

      int? reportedCount;
      manager.onPlaneOrPointTap = (hits) => reportedCount = hits.length;

      await simulateNativeCall(
        _channel('ARSessionFlutterApi', 'onPlaneOrPointTap', 6),
        ARSessionFlutterApi.pigeonChannelCodec,
        <Object?>[
          <HitTestResultMessage>[
            HitTestResultMessage(
              type: 1,
              distance: 1.5,
              worldTransform: List<double>.filled(16, 0)..[0] = 1,
            ),
          ],
        ],
      );

      expect(reportedCount, 1);
    });
  });

  group('ARAnchorManager', () {
    test('forwards a native error to onError', () async {
      final manager = ARAnchorManager(4);
      String? reportedError;
      manager.onError = (error) => reportedError = error;

      await simulateNativeCall(
        _channel('ARAnchorFlutterApi', 'onError', 4),
        ARAnchorFlutterApi.pigeonChannelCodec,
        <Object?>['anchor failed'],
      );

      expect(reportedError, 'anchor failed');
    });

    test('returns the downloaded anchor name back to native by default',
        () async {
      ARAnchorManager(7);

      final data = ARAnchorFlutterApi.pigeonChannelCodec.encodeMessage(
        <Object?>[
          AnchorMessage(
            type: 0,
            name: 'downloaded-anchor',
            transformation: List<double>.filled(16, 0),
          ),
        ],
      );
      ByteData? response;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _channel('ARAnchorFlutterApi', 'onAnchorDownloadSuccess', 7),
        data,
        (ByteData? reply) => response = reply,
      );

      final decoded = ARAnchorFlutterApi.pigeonChannelCodec
          .decodeMessage(response) as List<Object?>;
      expect(decoded[0], 'downloaded-anchor');
    });
  });

  group('ARObjectManager', () {
    test('forwards a native error to onError', () async {
      final manager = ARObjectManager(5);
      String? reportedError;
      manager.onError = (error) => reportedError = error;

      await simulateNativeCall(
        _channel('ARObjectFlutterApi', 'onError', 5),
        ARObjectFlutterApi.pigeonChannelCodec,
        <Object?>['node failed'],
      );

      expect(reportedError, 'node failed');
    });

    test('forwards onPanEnd with the decoded transform', () async {
      final manager = ARObjectManager(8);
      String? reportedName;
      manager.onPanEnd = (name, transform) => reportedName = name;

      await simulateNativeCall(
        _channel('ARObjectFlutterApi', 'onPanEnd', 8),
        ARObjectFlutterApi.pigeonChannelCodec,
        <Object?>[
          NodeTransformEventMessage(
            name: 'node-1',
            transform: List<double>.filled(16, 0)..[0] = 1,
          ),
        ],
      );

      expect(reportedName, 'node-1');
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
