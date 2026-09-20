import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  const MethodChannel channel = MethodChannel('ar_flutter_plugin_2');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return '42';
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await ArFlutterPlugin.platformVersion, '42');
  });

  test('does not register duplicate transform listeners', () async {
    const objectChannel = MethodChannel('arobjects_1');
    var transformChanges = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(objectChannel, (call) async {
      if (call.method == 'addNode') {
        return true;
      }
      if (call.method == 'transformationChanged') {
        transformChanges++;
      }
      return null;
    });

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
        .setMockMethodCallHandler(objectChannel, null);
  });
}
