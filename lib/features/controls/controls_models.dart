import '../../core/json.dart';

/// Document types an approval rule can cover.
const approvalDocTypes = <String, String>{
  'purchase': 'Purchase bill',
  'payment': 'Payment',
  'expense': 'Expense',
  'journal': 'Journal',
  'credit_note': 'Credit note',
  'purchase_order': 'Purchase order',
};

String approvalDocLabel(String type) => approvalDocTypes[type] ?? type;

class ApprovalLevel {
  const ApprovalLevel({
    required this.level,
    this.approverRoleId,
    this.approverUserId,
    this.label = '',
  });

  factory ApprovalLevel.fromJson(Json json) => ApprovalLevel(
    level: asInt(json['level']),
    approverRoleId: asStringOrNull(json['approverRoleId']),
    approverUserId: asStringOrNull(json['approverUserId']),
    label: asString(json['label']),
  );

  final int level;
  final String? approverRoleId;
  final String? approverUserId;
  final String label;
}

class ApprovalRule {
  const ApprovalRule({
    required this.id,
    required this.docType,
    required this.name,
    required this.minAmount,
    required this.isActive,
    this.locationId,
    this.locationName,
    this.levels = const [],
  });

  factory ApprovalRule.fromJson(Json json) => ApprovalRule(
    id: asString(json['id']),
    docType: asString(json['docType']),
    name: asString(json['name']),
    minAmount: asDouble(json['minAmount']),
    isActive: asBool(json['isActive'], true),
    locationId: asStringOrNull(json['locationId']),
    locationName: asStringOrNull(json['locationName']),
    levels: asJsonList(json['levels']).map(ApprovalLevel.fromJson).toList(),
  );

  final String id;
  final String docType;
  final String name;
  final double minAmount;
  final bool isActive;
  final String? locationId;
  final String? locationName;
  final List<ApprovalLevel> levels;
}

class ApprovalAction {
  const ApprovalAction({
    required this.action,
    required this.byName,
    this.level,
    this.comment,
    this.at,
  });

  factory ApprovalAction.fromJson(Json json) => ApprovalAction(
    action: asString(json['action']),
    byName: asString(asJsonOrNull(json['by'])?['name']),
    level: json['level'] == null ? null : asInt(json['level']),
    comment: asStringOrNull(json['comment']),
    at: asDateTimeOrNull(json['at']),
  );

  final String action;
  final String byName;
  final int? level;
  final String? comment;
  final DateTime? at;
}

class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.number,
    required this.docType,
    required this.status,
    required this.amount,
    required this.date,
    required this.requestedByName,
    this.requestedById = '',
    this.partyName,
    this.locationName,
    this.narration,
    this.payload = const {},
    this.ruleName = '',
    this.levels = const [],
    this.currentLevel = 1,
    this.totalLevels = 1,
    this.requestedAt,
    this.canAct = false,
    this.documentId,
    this.documentNumber,
    this.actions = const [],
    this.decidedAt,
  });

  factory ApprovalRequest.fromJson(Json json) {
    final summary = asJson(json['summary']);
    final document = asJsonOrNull(json['document']);
    final by = asJson(json['requestedBy']);
    return ApprovalRequest(
      id: asString(json['id']),
      number: asString(json['number']),
      docType: asString(json['docType']),
      status: asString(json['status']),
      amount: asDouble(json['amount']),
      date: asString(summary['date']),
      partyName: asStringOrNull(summary['partyName']),
      locationName: asStringOrNull(summary['locationName']),
      narration: asStringOrNull(summary['narration']),
      payload: asJson(json['payload']),
      ruleName: asString(json['ruleName']),
      levels: asJsonList(json['levels']).map(ApprovalLevel.fromJson).toList(),
      currentLevel: asInt(json['currentLevel'], 1),
      totalLevels: asInt(json['totalLevels'], 1),
      requestedById: asString(by['id']),
      requestedByName: asString(by['name']),
      requestedAt: asDateTimeOrNull(json['requestedAt']),
      canAct: asBool(json['canAct']),
      documentId: asStringOrNull(document?['id']),
      documentNumber: asStringOrNull(document?['number']),
      actions: asJsonList(
        json['actions'],
      ).map(ApprovalAction.fromJson).toList(),
      decidedAt: asDateTimeOrNull(json['decidedAt']),
    );
  }

  final String id;
  final String number;
  final String docType;
  final String status;
  final double amount;
  final String date;
  final String? partyName;
  final String? locationName;
  final String? narration;
  final Json payload;
  final String ruleName;
  final List<ApprovalLevel> levels;
  final int currentLevel;
  final int totalLevels;
  final String requestedById;
  final String requestedByName;
  final DateTime? requestedAt;
  final bool canAct;
  final String? documentId;
  final String? documentNumber;
  final List<ApprovalAction> actions;
  final DateTime? decidedAt;

  bool get isPending => status == 'pending';
}

class CustomField {
  const CustomField({
    required this.id,
    required this.entity,
    required this.key,
    required this.label,
    required this.type,
    this.options = const [],
    this.required = false,
    this.showOnPrint = false,
    this.sortOrder = 0,
    this.isActive = true,
  });

  factory CustomField.fromJson(Json json) => CustomField(
    id: asString(json['id']),
    entity: asString(json['entity']),
    key: asString(json['key']),
    label: asString(json['label']),
    type: asString(json['type'], 'text'),
    options: asStringList(json['options']),
    required: asBool(json['required']),
    showOnPrint: asBool(json['showOnPrint']),
    sortOrder: asInt(json['sortOrder']),
    isActive: asBool(json['isActive'], true),
  );

  final String id;
  final String entity;
  final String key;
  final String label;
  final String type;
  final List<String> options;
  final bool required;
  final bool showOnPrint;
  final int sortOrder;
  final bool isActive;
}

const customFieldEntities = <String, String>{
  'item': 'Items',
  'party': 'Parties',
  'invoice': 'Invoices',
  'purchase': 'Purchases',
  'project': 'Projects',
};

const customFieldTypes = <String, String>{
  'text': 'Text',
  'number': 'Number',
  'date': 'Date',
  'boolean': 'Yes / no',
  'select': 'Choice list',
};

/// Display text of a stored custom value.
String customValueText(CustomField field, Object? value) {
  if (value == null) return '';
  if (field.type == 'boolean') return value == true ? 'Yes' : 'No';
  return value.toString();
}

class CostCentre {
  const CostCentre({
    required this.id,
    required this.code,
    required this.name,
    this.parentId,
    this.isActive = true,
    this.updatedAt,
  });

  factory CostCentre.fromJson(Json json) => CostCentre(
    id: asString(json['id']),
    code: asString(json['code']),
    name: asString(json['name']),
    parentId: asStringOrNull(json['parentId']),
    isActive: asBool(json['isActive'], true),
    updatedAt: asDateTimeOrNull(json['updatedAt']),
  );

  final DateTime? updatedAt;
  final String id;
  final String code;
  final String name;
  final String? parentId;
  final bool isActive;

  String get label => '$code · $name';
}

class CostCentreRow {
  const CostCentreRow({
    required this.name,
    required this.income,
    required this.expense,
    required this.net,
    this.id,
    this.code,
  });

  factory CostCentreRow.fromJson(Json json) => CostCentreRow(
    id: asStringOrNull(json['costCentreId']),
    code: asStringOrNull(json['code']),
    name: asString(json['name']),
    income: asDouble(json['income']),
    expense: asDouble(json['expense']),
    net: asDouble(json['net']),
  );

  final String? id;
  final String? code;
  final String name;
  final double income;
  final double expense;
  final double net;
}

class CostCentreReport {
  const CostCentreReport({
    required this.from,
    required this.to,
    required this.rows,
    required this.totals,
  });

  factory CostCentreReport.fromJson(Json json) => CostCentreReport(
    from: asString(json['from']),
    to: asString(json['to']),
    rows: asJsonList(json['rows']).map(CostCentreRow.fromJson).toList(),
    totals: CostCentreRow.fromJson({
      ...asJson(json['totals']),
      'name': 'Total',
    }),
  );

  final String from;
  final String to;
  final List<CostCentreRow> rows;
  final CostCentreRow totals;
}

const importKinds = <String, String>{
  'items': 'Items',
  'parties': 'Parties',
  'opening_stock': 'Opening stock',
  'account_balances': 'Account balances',
};

const importKindsNeedingAsOf = {'parties', 'opening_stock', 'account_balances'};

class ImportRowError {
  const ImportRowError({required this.row, this.column, this.message = ''});

  factory ImportRowError.fromJson(Json json) => ImportRowError(
    row: asInt(json['row']),
    column: asStringOrNull(json['column']),
    message: asString(json['message']),
  );

  final int row;
  final String? column;
  final String message;
}

class ImportJob {
  const ImportJob({
    required this.id,
    required this.kind,
    required this.status,
    this.fileName,
    this.totalRows = 0,
    this.validRows = 0,
    this.errors = const [],
    this.preview = const [],
    this.asOf,
    this.updateExisting = false,
    this.created = 0,
    this.updated = 0,
    this.skipped = 0,
    this.hasResult = false,
    this.error,
    this.createdByName = '',
    this.createdAt,
    this.finishedAt,
  });

  factory ImportJob.fromJson(Json json) {
    final options = asJson(json['options']);
    final result = asJsonOrNull(json['result']);
    return ImportJob(
      id: asString(json['id']),
      kind: asString(json['kind']),
      status: asString(json['status']),
      fileName: asStringOrNull(json['fileName']),
      totalRows: asInt(json['totalRows']),
      validRows: asInt(json['validRows']),
      errors: asJsonList(json['errors']).map(ImportRowError.fromJson).toList(),
      preview: asJsonList(json['preview']),
      asOf: asStringOrNull(options['asOf']),
      updateExisting: asBool(options['updateExisting']),
      hasResult: result != null,
      created: asInt(result?['created']),
      updated: asInt(result?['updated']),
      skipped: asInt(result?['skipped']),
      error: asStringOrNull(json['error']),
      createdByName: asString(asJson(json['createdBy'])['name']),
      createdAt: asDateTimeOrNull(json['createdAt']),
      finishedAt: asDateTimeOrNull(json['finishedAt']),
    );
  }

  final String id;
  final String kind;
  final String status;
  final String? fileName;
  final int totalRows;
  final int validRows;
  final List<ImportRowError> errors;
  final List<Json> preview;
  final String? asOf;
  final bool updateExisting;
  final bool hasResult;
  final int created;
  final int updated;
  final int skipped;
  final String? error;
  final String createdByName;
  final DateTime? createdAt;
  final DateTime? finishedAt;

  bool get inProgress => status == 'queued' || status == 'running';
  bool get isFinal => status == 'done' || status == 'failed';
}
