import 'package:ar_flutter_example/hit_test_selection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

ARHitTestResult _hit(ARHitTestResultType type, double distance) {
  return ARHitTestResult(type, distance, Matrix4.identity());
}

void main() {
  group('selectPlacementHit', () {
    test('returns null when there are no hits', () {
      expect(selectPlacementHit(const []), isNull);
    });

    test('picks the closest plane hit when only planes are present', () {
      final far = _hit(ARHitTestResultType.plane, 2.0);
      final near = _hit(ARHitTestResultType.plane, 0.5);

      expect(selectPlacementHit([far, near]), same(near));
    });

    test('prefers a plane hit over a closer point hit', () {
      final closerPoint = _hit(ARHitTestResultType.point, 0.2);
      final fartherPlane = _hit(ARHitTestResultType.plane, 1.0);

      expect(
        selectPlacementHit([closerPoint, fartherPlane]),
        same(fartherPlane),
      );
    });

    test('falls back to the closest point hit when no plane is hit', () {
      final far = _hit(ARHitTestResultType.point, 3.0);
      final near = _hit(ARHitTestResultType.point, 1.0);

      expect(selectPlacementHit([far, near]), same(near));
    });
  });
}
