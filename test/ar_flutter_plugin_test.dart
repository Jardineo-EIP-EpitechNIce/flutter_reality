import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reality/ar_flutter_plugin.dart';
import 'package:flutter_reality/datatypes/node_types.dart';
import 'package:flutter_reality/managers/ar_object_manager.dart';
import 'package:flutter_reality/models/ar_node.dart';
import 'package:flutter_reality/src/generated/messages.g.dart';
import 'package:vector_math/vector_math_64.dart';

/// Installs a mock handler for a Pigeon `HostApi` channel, the way real
/// native code would answer a Dart -> native call.
void mockHostApiChannel(
  String channelName,
  MessageCodec<Object?> codec,
  Object? Function(List<Object?> args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler(channelName, (ByteData? message) async {
    final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
    final result = handler(args);
    return codec.encodeMessage(<Object?>[result]);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const versionChannel =
      'dev.flutter.pigeon.flutter_reality.FlutterRealityHostApi.getPlatformVersion';

  setUp(() {
    mockHostApiChannel(
      versionChannel,
      FlutterRealityHostApi.pigeonChannelCodec,
      (args) => '42',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(versionChannel, null);
  });

  test('getPlatformVersion', () async {
    expect(await ArFlutterPlugin.platformVersion, '42');
  });

  test('does not register duplicate transform listeners', () async {
    const addNodeChannel =
        'dev.flutter.pigeon.flutter_reality.ARObjectHostApi.addNode.1';
    const transformChannel =
        'dev.flutter.pigeon.flutter_reality.ARObjectHostApi.transformationChanged.1';
    const initChannel =
        'dev.flutter.pigeon.flutter_reality.ARObjectHostApi.initialize.1';
    const removeNodeChannel =
        'dev.flutter.pigeon.flutter_reality.ARObjectHostApi.removeNode.1';
    var transformChanges = 0;

    mockHostApiChannel(
      initChannel,
      ARObjectHostApi.pigeonChannelCodec,
      (args) => null,
    );
    mockHostApiChannel(
      removeNodeChannel,
      ARObjectHostApi.pigeonChannelCodec,
      (args) => null,
    );
    mockHostApiChannel(
      addNodeChannel,
      ARObjectHostApi.pigeonChannelCodec,
      (args) => true,
    );
    mockHostApiChannel(
      transformChannel,
      ARObjectHostApi.pigeonChannelCodec,
      (args) {
        transformChanges++;
        return null;
      },
    );

    final manager = ARObjectManager(1);
    final node = ARNode(
      type: NodeType.localGLTF2,
      uri: 'model.gltf',
      position: Vector3.zero(),
    );

    expect(await manager.addNode(node), isTrue);
    expect(await manager.addNode(node), isTrue);
    node.position = Vector3(1, 0, 0);
    await Future<void>.delayed(Duration.zero);

    expect(transformChanges, 1);

    await manager.removeNode(node);
    node.position = Vector3(2, 0, 0);
    await Future<void>.delayed(Duration.zero);
    expect(transformChanges, 1);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(addNodeChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(transformChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(initChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(removeNodeChannel, null);
  });
}
