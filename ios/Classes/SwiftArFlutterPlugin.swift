import Flutter
import UIKit

private class FlutterRealityHostApiImpl: FlutterRealityHostApi {
  func getPlatformVersion() async throws -> String {
    return "iOS " + UIDevice.current.systemVersion
  }
}

public class SwiftArFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    FlutterRealityHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: FlutterRealityHostApiImpl())

    let factory = IosARViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "flutter_reality")
  }
}
