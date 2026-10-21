import '../../../core/json.dart';
import 'common_models.dart';
import 'labour_models.dart';

enum DprStatus {
  draft('Draft'),
  submitted('Submitted'),
  approved('Approved');

  const DprStatus(this.label);

  final String label;

  static DprStatus parse(Object? value) => DprStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => DprStatus.draft,
  );
}

/// Weather values the app sends (`Dpr.weather` is free text on the server).
const List<String> weatherKeys = ['sunny', 'cloudy', 'rain', 'hot', 'cold'];

/// `rain` → `Rain`; unknown values are shown as sent.
String weatherLabel(String? value) {
  if (value == null || value.isEmpty) return '';
  return humanize(value);
}

/// `POST /files` response.
class FileRef {
  const FileRef({
    required this.id,
    this.name = '',
    this.mimeType = '',
    this.size = 0,
    this.url = '',
  });

  factory FileRef.fromJson(Json json) => FileRef(
    id: asString(json['id']),
    name: asString(json['name']),
    mimeType: asString(json['mimeType']),
    size: asInt(json['size']),
    url: asString(json['url']),
  );

  final String id;
  final String name;
  final String mimeType;
  final int size;

  /// `/api/v1/files/<id>`; fetch with the Authorization header.
  final String url;

  bool get isImage => mimeType.startsWith('image/');
}

class DprWork {
  const DprWork({
    required this.description,
    this.id,
    this.boqLineId,
    this.boqCode,
    this.qty,
    this.unit,
  });

  factory DprWork.fromJson(Json json) => DprWork(
    id: asStringOrNull(json['id']),
    boqLineId: asStringOrNull(json['boqLineId']),
    boqCode: asStringOrNull(json['boqCode']),
    description: asString(json['description']),
    qty: asDoubleOrNull(json['qty']),
    unit: asStringOrNull(json['unit']),
  );

  final String? id;
  final String? boqLineId;
  final String? boqCode;
  final String description;
  final double? qty;
  final String? unit;

  Json toJson() => withoutNulls({
    'boqLineId': boqLineId,
    'description': description,
    'qty': qty,
    'unit': unit,
  });
}

class DprLabour {
  const DprLabour({required this.trade, required this.count});

  factory DprLabour.fromJson(Json json) =>
      DprLabour(trade: asString(json['trade']), count: asInt(json['count']));

  /// A [Trade.api] value (or free text from other clients).
  final String trade;
  final int count;

  String get label => tradeLabel(trade);

  Json toJson() => {'trade': trade, 'count': count};
}

class DprEquipment {
  const DprEquipment({required this.name, required this.hours});

  factory DprEquipment.fromJson(Json json) => DprEquipment(
    name: asString(json['name']),
    hours: asDouble(json['hours']),
  );

  final String name;
  final double hours;

  Json toJson() => {'name': name, 'hours': hours};
}

class DprPhoto {
  const DprPhoto({required this.fileId, this.url, this.caption});

  factory DprPhoto.fromJson(Json json) => DprPhoto(
    fileId: asString(json['fileId']),
    url: asStringOrNull(json['url']),
    caption: asStringOrNull(json['caption']),
  );

  final String fileId;
  final String? url;
  final String? caption;

  Json toJson() => withoutNulls({'fileId': fileId, 'caption': caption});
}

/// Daily progress report.
class Dpr {
  const Dpr({
    required this.id,
    required this.locationId,
    required this.locationName,
    required this.date,
    this.projectId,
    this.weather,
    this.status = DprStatus.draft,
    this.summary,
    this.hindrances,
    this.workDone = const [],
    this.labour = const [],
    this.equipment = const [],
    this.photos = const [],
    this.createdAt,
    this.createdBy,
    this.submittedAt,
    this.approvedAt,
    this.approvedBy,
  });

  factory Dpr.fromJson(Json json) => Dpr(
    id: asString(json['id']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    projectId: asStringOrNull(json['projectId']),
    date: asString(json['date']),
    weather: asStringOrNull(json['weather']),
    status: DprStatus.parse(json['status']),
    summary: asStringOrNull(json['summary']),
    hindrances: asStringOrNull(json['hindrances']),
    workDone: asJsonList(json['workDone']).map(DprWork.fromJson).toList(),
    labour: asJsonList(json['labour']).map(DprLabour.fromJson).toList(),
    equipment: asJsonList(
      json['equipment'],
    ).map(DprEquipment.fromJson).toList(),
    photos: asJsonList(json['photos']).map(DprPhoto.fromJson).toList(),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    submittedAt: asDateTimeOrNull(json['submittedAt']),
    approvedAt: asDateTimeOrNull(json['approvedAt']),
    approvedBy: NamedRef.fromJsonOrNull(json['approvedBy']),
  );

  final String id;
  final String locationId;
  final String locationName;
  final String? projectId;
  final String date;
  final String? weather;
  final DprStatus status;
  final String? summary;
  final String? hindrances;
  final List<DprWork> workDone;
  final List<DprLabour> labour;
  final List<DprEquipment> equipment;
  final List<DprPhoto> photos;
  final DateTime? createdAt;
  final NamedRef? createdBy;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final NamedRef? approvedBy;

  int get labourTotal => labour.fold(0, (sum, l) => sum + l.count);

  double get equipmentHours => equipment.fold(0, (sum, e) => sum + e.hours);

  bool get isDraft => status == DprStatus.draft;
}

/// Body of `POST /dprs` and `PATCH /dprs/:id`.
class DprDraft {
  const DprDraft({
    required this.locationId,
    required this.date,
    this.weather,
    this.summary,
    this.hindrances,
    this.workDone = const [],
    this.labour = const [],
    this.equipment = const [],
    this.photos = const [],
    this.submit = false,
  });

  final String locationId;
  final String date;
  final String? weather;
  final String? summary;
  final String? hindrances;
  final List<DprWork> workDone;
  final List<DprLabour> labour;
  final List<DprEquipment> equipment;
  final List<DprPhoto> photos;
  final bool submit;

  Json _fields() => {
    'weather': weather,
    'summary': summary,
    'hindrances': hindrances,
    'workDone': [for (final w in workDone) w.toJson()],
    'labour': [
      for (final l in labour)
        if (l.count > 0) l.toJson(),
    ],
    'equipment': [
      for (final e in equipment)
        if (e.name.trim().isNotEmpty) e.toJson(),
    ],
    'photos': [for (final p in photos) p.toJson()],
  };

  Json toCreateJson() => withoutNulls({
    'locationId': locationId,
    'date': date,
    ..._fields(),
    if (submit) 'submit': true,
  });

  /// Every editable field; `null` clears weather, summary and hindrances.
  Json toPatchJson() => {'locationId': locationId, 'date': date, ..._fields()};
}
