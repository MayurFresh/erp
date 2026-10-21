import '../../../core/json.dart';
import 'common_models.dart';

enum ProjectStatus {
  planning('planning', 'Planning'),
  active('active', 'Active'),
  onHold('on_hold', 'On hold'),
  completed('completed', 'Completed');

  const ProjectStatus(this.api, this.label);

  final String api;
  final String label;

  static ProjectStatus parse(Object? value) => ProjectStatus.values.firstWhere(
    (s) => s.api == value,
    orElse: () => ProjectStatus.planning,
  );
}

class Project {
  const Project({
    required this.id,
    required this.code,
    required this.name,
    this.companyId = '',
    this.clientPartyId,
    this.clientName,
    this.managerUserId,
    this.managerName,
    this.status = ProjectStatus.planning,
    this.startDate,
    this.endDate,
    this.contractValue = 0,
    this.address,
    this.sites = const [],
    this.budgetTotal = 0,
    this.progressPct = 0,
    this.createdAt,
  });

  factory Project.fromJson(Json json) => Project(
    id: asString(json['id']),
    companyId: asString(json['companyId']),
    code: asString(json['code']),
    name: asString(json['name']),
    clientPartyId: asStringOrNull(json['clientPartyId']),
    clientName: asStringOrNull(json['clientName']),
    managerUserId: asStringOrNull(json['managerUserId']),
    managerName: asStringOrNull(json['managerName']),
    status: ProjectStatus.parse(json['status']),
    startDate: asStringOrNull(json['startDate']),
    endDate: asStringOrNull(json['endDate']),
    contractValue: asDouble(json['contractValue']),
    address: asStringOrNull(json['address']),
    sites: asJsonList(json['sites']).map(NamedRef.fromJson).toList(),
    budgetTotal: asDouble(json['budgetTotal']),
    progressPct: asDouble(json['progressPct']),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String companyId;
  final String code;
  final String name;
  final String? clientPartyId;
  final String? clientName;
  final String? managerUserId;
  final String? managerName;
  final ProjectStatus status;
  final String? startDate;
  final String? endDate;
  final double contractValue;
  final String? address;
  final List<NamedRef> sites;

  /// Σ BOQ amount.
  final double budgetTotal;

  /// Amount-weighted BOQ progress, 0–100.
  final double progressPct;
  final DateTime? createdAt;

  String get displayName => code.isEmpty ? name : '$name ($code)';

  bool hasSite(String siteId) => sites.any((s) => s.id == siteId);

  /// Create / PATCH fields as currently stored (see `ProjectsRepository`).
  Json toInputJson() => {
    'code': code,
    'name': name,
    'clientPartyId': clientPartyId,
    'managerUserId': managerUserId,
    'status': status.api,
    'startDate': startDate,
    'endDate': endDate,
    'contractValue': contractValue,
    'address': address,
    'siteIds': [for (final s in sites) s.id],
  };
}

class BoqLine {
  const BoqLine({
    required this.id,
    required this.code,
    required this.description,
    required this.unit,
    this.projectId = '',
    this.qty = 0,
    this.rate = 0,
    this.amount = 0,
    this.materialBudget = 0,
    this.labourBudget = 0,
    this.otherBudget = 0,
    this.executedQty = 0,
    this.progressPct = 0,
    this.sortOrder = 0,
  });

  factory BoqLine.fromJson(Json json) => BoqLine(
    id: asString(json['id']),
    projectId: asString(json['projectId']),
    code: asString(json['code']),
    description: asString(json['description']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
    rate: asDouble(json['rate']),
    amount: asDouble(json['amount']),
    materialBudget: asDouble(json['materialBudget']),
    labourBudget: asDouble(json['labourBudget']),
    otherBudget: asDouble(json['otherBudget']),
    executedQty: asDouble(json['executedQty']),
    progressPct: asDouble(json['progressPct']),
    sortOrder: asInt(json['sortOrder']),
  );

  final String id;
  final String projectId;

  /// e.g. `2.1.3`.
  final String code;
  final String description;
  final String unit;
  final double qty;
  final double rate;

  /// qty × rate.
  final double amount;
  final double materialBudget;
  final double labourBudget;
  final double otherBudget;

  /// Σ approved DPR work entries.
  final double executedQty;

  /// executedQty ÷ qty × 100, max 100.
  final double progressPct;
  final int sortOrder;

  /// `2.1.3 · PCC 1:4:8 in foundation`.
  String get label => code.isEmpty ? description : '$code · $description';

  BoqLineInput toInput() => BoqLineInput(
    code: code,
    description: description,
    unit: unit,
    qty: qty,
    rate: rate,
    materialBudget: materialBudget,
    labourBudget: labourBudget,
    otherBudget: otherBudget,
  );
}

/// Body of `POST /projects/:id/boq` (one line or one of `lines`) and of
/// `PATCH /boq/:id`.
class BoqLineInput {
  const BoqLineInput({
    required this.code,
    required this.description,
    required this.unit,
    required this.qty,
    required this.rate,
    this.materialBudget,
    this.labourBudget,
    this.otherBudget,
  });

  final String code;
  final String description;
  final String unit;
  final double qty;
  final double rate;
  final double? materialBudget;
  final double? labourBudget;
  final double? otherBudget;

  double get amount => qty * rate;

  Json toJson() => withoutNulls({
    'code': code,
    'description': description,
    'unit': unit,
    'qty': qty,
    'rate': rate,
    'materialBudget': materialBudget,
    'labourBudget': labourBudget,
    'otherBudget': otherBudget,
  });

  @override
  bool operator ==(Object other) =>
      other is BoqLineInput &&
      other.code == code &&
      other.description == description &&
      other.unit == unit &&
      other.qty == qty &&
      other.rate == rate &&
      other.materialBudget == materialBudget &&
      other.labourBudget == labourBudget &&
      other.otherBudget == otherBudget;

  @override
  int get hashCode => Object.hash(
    code,
    description,
    unit,
    qty,
    rate,
    materialBudget,
    labourBudget,
    otherBudget,
  );

  @override
  String toString() => 'BoqLineInput(${toJson()})';
}

class CostSplit {
  const CostSplit({
    this.material = 0,
    this.labour = 0,
    this.other = 0,
    this.total = 0,
  });

  /// [otherKey] is `other` for budgets and `expenses` for actuals.
  factory CostSplit.fromJson(Json json, {String otherKey = 'other'}) =>
      CostSplit(
        material: asDouble(json['material']),
        labour: asDouble(json['labour']),
        other: asDouble(json[otherKey]),
        total: asDouble(json['total']),
      );

  final double material;
  final double labour;

  /// Budget: other; actual: expenses at project sites.
  final double other;
  final double total;
}

class BoqCostRow {
  const BoqCostRow({
    required this.boqLineId,
    required this.code,
    required this.description,
    this.qty = 0,
    this.executedQty = 0,
    this.progressPct = 0,
    this.materialBudget = 0,
    this.materialActual = 0,
  });

  factory BoqCostRow.fromJson(Json json) => BoqCostRow(
    boqLineId: asString(json['boqLineId']),
    code: asString(json['code']),
    description: asString(json['description']),
    qty: asDouble(json['qty']),
    executedQty: asDouble(json['executedQty']),
    progressPct: asDouble(json['progressPct']),
    materialBudget: asDouble(json['materialBudget']),
    materialActual: asDouble(json['materialActual']),
  );

  final String boqLineId;
  final String code;
  final String description;
  final double qty;
  final double executedQty;
  final double progressPct;
  final double materialBudget;
  final double materialActual;

  double get materialVariance => materialBudget - materialActual;
}

class ProjectCosts {
  const ProjectCosts({
    required this.projectId,
    this.from,
    this.to,
    this.budget = const CostSplit(),
    this.actual = const CostSplit(),
    this.byBoqLine = const [],
  });

  factory ProjectCosts.fromJson(Json json) => ProjectCosts(
    projectId: asString(json['projectId']),
    from: asStringOrNull(json['from']),
    to: asStringOrNull(json['to']),
    budget: CostSplit.fromJson(asJson(json['budget'])),
    actual: CostSplit.fromJson(asJson(json['actual']), otherKey: 'expenses'),
    byBoqLine: asJsonList(json['byBoqLine']).map(BoqCostRow.fromJson).toList(),
  );

  final String projectId;
  final String? from;
  final String? to;
  final CostSplit budget;
  final CostSplit actual;
  final List<BoqCostRow> byBoqLine;
}
