// The code in this file is adapted from Oleksandr Leuschenko' ARKit Flutter Plugin (https://github.com/olexale/arkit_flutter_plugin)
import 'package:json_annotation/json_annotation.dart';
import 'package:vector_math/vector_math_64.dart';

/// Converts a [Matrix4] to and from the flat 16-value list representation
/// used on the wire by the generated Pigeon messages.
class MatrixConverter implements JsonConverter<Matrix4, List<dynamic>> {
  const MatrixConverter();

  /// Rebuilds a [Matrix4] from a flat, column-major list of 16 doubles.
  @override
  Matrix4 fromJson(List<dynamic> json) {
    return Matrix4.fromList(json.cast<double>());
  }

  /// Flattens [matrix] into a column-major list of 16 doubles.
  @override
  List<dynamic> toJson(Matrix4 matrix) {
    final list = List<double>.filled(16, 0.0);
    matrix.copyIntoArray(list);
    return list;
  }
}
