export 'package:flutter_reality/widgets/ar_view.dart';

import 'package:flutter_reality/src/generated/messages.g.dart';

class ArFlutterPlugin {
  static final FlutterRealityHostApi _hostApi = FlutterRealityHostApi();

  /// Private constructor to prevent accidental instantiation of the Plugin using the implicit default constructor
  ArFlutterPlugin._();

  static Future<String> get platformVersion => _hostApi.getPlatformVersion();
}
