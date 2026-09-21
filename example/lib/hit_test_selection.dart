import 'package:flutter_reality/datatypes/hittest_result_types.dart';
import 'package:flutter_reality/models/ar_hittest_result.dart';

/// Picks which hit-test result a tap should place a model on.
///
/// A tap can produce several results at once (plane and feature-point hits
/// mixed together). Plane hits give a more stable anchor than raw feature
/// points, so they are preferred; among same-kind hits, the closest one to
/// the camera is used.
ARHitTestResult? selectPlacementHit(List<ARHitTestResult> hits) {
  if (hits.isEmpty) return null;

  final planeHits =
      hits.where((hit) => hit.type == ARHitTestResultType.plane).toList();
  final candidates = planeHits.isNotEmpty ? planeHits : hits;

  return candidates.reduce(
    (closest, hit) => hit.distance < closest.distance ? hit : closest,
  );
}
