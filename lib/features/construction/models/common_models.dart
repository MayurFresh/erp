import '../../../core/json.dart';

/// `{ id, name }` as used for `createdBy`, `approvedBy` and project sites.
class NamedRef {
  const NamedRef({required this.id, required this.name});

  factory NamedRef.fromJson(Json json) =>
      NamedRef(id: asString(json['id']), name: asString(json['name']));

  static NamedRef? fromJsonOrNull(Object? value) {
    final json = asJsonOrNull(value);
    return json == null ? null : NamedRef.fromJson(json);
  }

  final String id;
  final String name;

  Json toJson() => {'id': id, 'name': name};
}

/// `snake_case` API value → `Sentence case` label (`on_hold` → `On hold`).
String humanize(String value) {
  if (value.isEmpty) return value;
  final words = value.replaceAll('_', ' ');
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// Percentage clamped to 0–100 (for progress bars).
double clampPct(num? value) {
  final v = (value ?? 0).toDouble();
  if (v.isNaN) return 0;
  return v.clamp(0, 100).toDouble();
}
