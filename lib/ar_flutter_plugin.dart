export 'package:flutter_reality/widgets/ar_view.dart';

import 'package:flutter_reality/src/generated/messages.g.dart';

/// Plugin-level entry point, mainly used to query the host platform.
///
/// Most consumers won't instantiate this class directly; instead, use the
/// [ARView] widget exported by this library and the managers it hands back
/// through [ARViewCreatedCallback].
class ArFlutterPlugin {
  static final FlutterRealityHostApi _hostApi = FlutterRealityHostApi();

  /// Private constructor to prevent accidental instantiation of the Plugin using the implicit default constructor
  ArFlutterPlugin._();

  /// The platform version string reported by the native Android/iOS side,
  /// e.g. `"Android 14"` or `"iOS 17.4"`. Mainly useful for diagnostics.
  static Future<String> get platformVersion => _hostApi.getPlatformVersion();
}
