/// Lenient JSON helpers shared by the hand-written models.
library;

typedef Json = Map<String, dynamic>;

Json asJson(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  return <String, dynamic>{};
}

Json? asJsonOrNull(Object? value) => value is Map ? asJson(value) : null;

List<Json> asJsonList(Object? value) =>
    value is List ? value.map(asJson).toList() : const <Json>[];

String asString(Object? value, [String fallback = '']) =>
    value == null ? fallback : value.toString();

String? asStringOrNull(Object? value) => value?.toString();

double asDouble(Object? value, [double fallback = 0]) =>
    asDoubleOrNull(value) ?? fallback;

double? asDoubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool asBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return fallback;
}

DateTime? asDateTimeOrNull(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

List<String> asStringList(Object? value) =>
    value is List ? value.map((e) => e.toString()).toList() : const <String>[];

/// `null` stays `null` (e.g. "all locations"); a list becomes a string list.
List<String>? asStringListOrNull(Object? value) =>
    value is List ? asStringList(value) : null;

/// Removes `null` values; used for create bodies where optional fields are
/// omitted rather than sent as `null`.
Json withoutNulls(Json json) =>
    Map.of(json)..removeWhere((key, value) => value == null);

/// Keys of [updated] whose values differ from [original]; used for PATCH.
Json changedFields(Json original, Json updated) {
  final result = <String, dynamic>{};
  updated.forEach((key, value) {
    if (!original.containsKey(key) || original[key] != value) {
      result[key] = value;
    }
  });
  return result;
}

/// A page of a list endpoint: `{ data: [...], total }`.
class Paged<T> {
  const Paged(this.data, this.total);

  factory Paged.fromJson(Json json, T Function(Json) fromItem) => Paged(
    asJsonList(json['data']).map(fromItem).toList(),
    asInt(json['total']),
  );

  final List<T> data;
  final int total;
}
