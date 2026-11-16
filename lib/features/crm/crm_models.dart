import '../../core/json.dart';

/// Lead sources in the API's order, with the words shown to people.
const crmSources = <(String, String)>[
  ('walk_in', 'Walk-in'),
  ('phone', 'Phone'),
  ('website', 'Website form'),
  ('indiamart', 'IndiaMART'),
  ('justdial', 'JustDial'),
  ('tradeindia', 'TradeIndia'),
  ('referral', 'Referral'),
  ('whatsapp', 'WhatsApp'),
  ('social', 'Social media'),
  ('other', 'Other'),
];

String crmSourceLabel(String? source) {
  if (source == null || source.isEmpty) return '';
  return crmSources.where((s) => s.$1 == source).map((s) => s.$2).firstOrNull ??
      source;
}

const crmLeadStatuses = <(String, String)>[
  ('open', 'Open'),
  ('new', 'New'),
  ('contacted', 'Contacted'),
  ('qualified', 'Qualified'),
  ('converted', 'Converted'),
  ('lost', 'Lost'),
  ('', 'All'),
];

const crmActivityKinds = <(String, String)>[
  ('call', 'Call'),
  ('meeting', 'Meeting'),
  ('visit', 'Visit'),
  ('task', 'Task'),
  ('whatsapp', 'WhatsApp'),
  ('email', 'Email'),
  ('note', 'Note'),
];

String crmKindLabel(String kind) =>
    crmActivityKinds.where((k) => k.$1 == kind).map((k) => k.$2).firstOrNull ??
    kind;

/// A planned follow-up as shown on leads and deals.
class CrmNext {
  const CrmNext({
    required this.id,
    required this.kind,
    required this.subject,
    this.dueAt,
  });

  factory CrmNext.fromJson(Json j) => CrmNext(
    id: asString(j['id']),
    kind: asString(j['kind'], 'call'),
    subject: asString(j['subject']),
    dueAt: asDateTimeOrNull(j['dueAt']),
  );

  final String id, kind, subject;
  final DateTime? dueAt;

  bool get overdue => dueAt != null && dueAt!.isBefore(DateTime.now());
}

CrmNext? _next(Object? v) => v is Map ? CrmNext.fromJson(asJson(v)) : null;

class PartyBalance {
  const PartyBalance({
    required this.owes,
    required this.overdue,
    this.oldestOverdueDays,
  });

  factory PartyBalance.fromJson(Json j) => PartyBalance(
    owes: asDouble(j['owes']),
    overdue: asDouble(j['overdue']),
    oldestOverdueDays: j['oldestOverdueDays'] == null
        ? null
        : asInt(j['oldestOverdueDays']),
  );

  final double owes, overdue;
  final int? oldestOverdueDays;
}

PartyBalance? _balance(Object? v) =>
    v is Map ? PartyBalance.fromJson(asJson(v)) : null;

/// Words for the "owes" line, or null when nothing is owed.
String? owesText(PartyBalance? b, String Function(num) money) {
  if (b == null || b.owes <= 0) return null;
  final late = b.oldestOverdueDays;
  final tail = b.overdue > 0 && late != null && late > 0
      ? ', $late ${late == 1 ? 'day' : 'days'} late'
      : '';
  return 'owes ${money(b.owes)}$tail';
}

class CrmActivity {
  const CrmActivity({
    required this.id,
    required this.kind,
    required this.subject,
    this.notes,
    this.dueAt,
    this.doneAt,
    this.outcome,
    this.durationMin,
    this.leadId,
    this.dealId,
    this.partyId,
    this.title = '',
    this.value = 0,
    this.source,
    this.phone,
    this.ownerName,
    this.overdue = false,
    this.partyBalance,
    this.createdAt,
  });

  factory CrmActivity.fromJson(Json j) => CrmActivity(
    id: asString(j['id']),
    kind: asString(j['kind'], 'call'),
    subject: asString(j['subject']),
    notes: asStringOrNull(j['notes']),
    dueAt: asDateTimeOrNull(j['dueAt']),
    doneAt: asDateTimeOrNull(j['doneAt']),
    outcome: asStringOrNull(j['outcome']),
    durationMin: j['durationMin'] == null ? null : asInt(j['durationMin']),
    leadId: asStringOrNull(j['leadId']),
    dealId: asStringOrNull(j['dealId']),
    partyId: asStringOrNull(j['partyId']),
    title: asString(j['title']),
    value: asDouble(j['value']),
    source: asStringOrNull(j['source']),
    phone: asStringOrNull(j['phone']),
    ownerName: asStringOrNull(j['ownerName']),
    overdue: asBool(j['overdue']),
    partyBalance: _balance(j['partyBalance']),
    createdAt: asDateTimeOrNull(j['createdAt']),
  );

  final String id, kind, subject, title;
  final String? notes, outcome, leadId, dealId, partyId, source, phone;
  final String? ownerName;
  final DateTime? dueAt, doneAt, createdAt;
  final int? durationMin;
  final double value;
  final bool overdue;
  final PartyBalance? partyBalance;

  bool get isDone => doneAt != null;
  bool get hasPhone => (phone ?? '').trim().isNotEmpty;

  /// Where tapping the row goes.
  String? get path => dealId != null
      ? '/crm/deals/$dealId'
      : leadId != null
      ? '/crm/leads/$leadId'
      : partyId != null
      ? '/crm/customers/$partyId'
      : null;
}

class LeadMatch {
  const LeadMatch({
    required this.partyId,
    required this.name,
    this.phone,
    this.gstin,
    this.balance = 0,
  });

  factory LeadMatch.fromJson(Json j) => LeadMatch(
    partyId: asString(j['partyId']),
    name: asString(j['name']),
    phone: asStringOrNull(j['phone']),
    gstin: asStringOrNull(j['gstin']),
    balance: asDouble(j['balance']),
  );

  final String partyId, name;
  final String? phone, gstin;
  final double balance;
}

class CrmLead {
  const CrmLead({
    required this.id,
    required this.name,
    this.companyName,
    this.phone,
    this.email,
    this.city,
    this.stateCode,
    this.requirement,
    this.estimatedValue,
    this.source,
    this.ownerId,
    this.ownerName,
    required this.status,
    this.lostReason,
    this.partyId,
    this.partyName,
    this.dealId,
    this.nextFollowUp,
    this.createdAt,
    this.updatedAt,
  });

  factory CrmLead.fromJson(Json j) => CrmLead(
    id: asString(j['id']),
    name: asString(j['name']),
    companyName: asStringOrNull(j['companyName']),
    phone: asStringOrNull(j['phone']),
    email: asStringOrNull(j['email']),
    city: asStringOrNull(j['city']),
    stateCode: asStringOrNull(j['stateCode']),
    requirement: asStringOrNull(j['requirement']),
    estimatedValue: asDoubleOrNull(j['estimatedValue']),
    source: asStringOrNull(j['source']),
    ownerId: asStringOrNull(j['ownerId']),
    ownerName: asStringOrNull(j['ownerName']),
    status: asString(j['status'], 'new'),
    lostReason: asStringOrNull(j['lostReason']),
    partyId: asStringOrNull(j['partyId']),
    partyName: asStringOrNull(j['partyName']),
    dealId: asStringOrNull(j['dealId']),
    nextFollowUp: _next(j['nextFollowUp']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id, name, status;
  final String? companyName, phone, email, city, stateCode, requirement;
  final String? source, ownerId, ownerName, lostReason, partyId, partyName;
  final String? dealId, updatedAt;
  final double? estimatedValue;
  final CrmNext? nextFollowUp;
  final DateTime? createdAt;

  bool get isClosed => status == 'converted' || status == 'lost';
}

class LeadDetail {
  const LeadDetail(this.lead, this.activities, this.matches);

  factory LeadDetail.fromJson(Json j) => LeadDetail(
    CrmLead.fromJson(j),
    asJsonList(j['activities']).map(CrmActivity.fromJson).toList(),
    asJsonList(j['matches']).map(LeadMatch.fromJson).toList(),
  );

  final CrmLead lead;
  final List<CrmActivity> activities;
  final List<LeadMatch> matches;
}

class CrmStage {
  const CrmStage({
    required this.id,
    required this.name,
    required this.probability,
    required this.kind,
    this.isActive = true,
  });

  factory CrmStage.fromJson(Json j) => CrmStage(
    id: asString(j['id']),
    name: asString(j['name']),
    probability: asInt(j['probability']),
    kind: asString(j['kind'], 'open'),
    isActive: asBool(j['isActive'], true),
  );

  final String id, name, kind;
  final int probability;
  final bool isActive;
}

class CrmDeal {
  const CrmDeal({
    required this.id,
    required this.title,
    this.partyId,
    this.partyName,
    this.leadId,
    required this.stageId,
    required this.stageName,
    required this.stageKind,
    required this.value,
    required this.effectiveProbability,
    required this.weightedValue,
    this.expectedClose,
    this.ownerId,
    this.ownerName,
    required this.status,
    this.lostReason,
    this.daysInStage = 0,
    this.notes,
    this.nextFollowUp,
    this.followUpOverdue = false,
    this.partyBalance,
    this.quotationCount = 0,
    this.updatedAt,
  });

  factory CrmDeal.fromJson(Json j) => CrmDeal(
    id: asString(j['id']),
    title: asString(j['title']),
    partyId: asStringOrNull(j['partyId']),
    partyName: asStringOrNull(j['partyName']),
    leadId: asStringOrNull(j['leadId']),
    stageId: asString(j['stageId']),
    stageName: asString(j['stageName']),
    stageKind: asString(j['stageKind'], 'open'),
    value: asDouble(j['value']),
    effectiveProbability: asDouble(j['effectiveProbability']),
    weightedValue: asDouble(j['weightedValue']),
    expectedClose: asStringOrNull(j['expectedClose']),
    ownerId: asStringOrNull(j['ownerId']),
    ownerName: asStringOrNull(j['ownerName']),
    status: asString(j['status'], 'open'),
    lostReason: asStringOrNull(j['lostReason']),
    daysInStage: asInt(j['daysInStage']),
    notes: asStringOrNull(j['notes']),
    nextFollowUp: _next(j['nextFollowUp']),
    followUpOverdue: asBool(j['followUpOverdue']),
    partyBalance: _balance(j['partyBalance']),
    quotationCount: asInt(j['quotationCount']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id, title, stageId, stageName, stageKind, status;
  final String? partyId, partyName, leadId, expectedClose, ownerId, ownerName;
  final String? lostReason, notes, updatedAt;
  final double value, effectiveProbability, weightedValue;
  final int daysInStage, quotationCount;
  final CrmNext? nextFollowUp;
  final bool followUpOverdue;
  final PartyBalance? partyBalance;

  bool get isOpen => status == 'open';
}

class DealQuotation {
  const DealQuotation({
    required this.id,
    required this.number,
    required this.kind,
    required this.status,
    required this.total,
    this.quoteDate,
  });

  factory DealQuotation.fromJson(Json j) => DealQuotation(
    id: asString(j['id']),
    number: asString(j['number']),
    kind: asString(j['kind'], 'quotation'),
    status: asString(j['status']),
    total: asDouble(j['total']),
    quoteDate: asStringOrNull(j['quoteDate']),
  );

  final String id, number, kind, status;
  final double total;
  final String? quoteDate;
}

class StageChange {
  const StageChange({this.fromStage, required this.toStage, this.changedAt, this.changedBy});

  factory StageChange.fromJson(Json j) => StageChange(
    fromStage: asStringOrNull(j['fromStage']),
    toStage: asString(j['toStage']),
    changedAt: asDateTimeOrNull(j['changedAt']),
    changedBy: asStringOrNull(j['changedBy']),
  );

  final String? fromStage, changedBy;
  final String toStage;
  final DateTime? changedAt;
}

class DealDetail {
  const DealDetail(this.deal, this.activities, this.quotations, this.history);

  factory DealDetail.fromJson(Json j) => DealDetail(
    CrmDeal.fromJson(j),
    asJsonList(j['activities']).map(CrmActivity.fromJson).toList(),
    asJsonList(j['quotations']).map(DealQuotation.fromJson).toList(),
    asJsonList(j['stageHistory']).map(StageChange.fromJson).toList(),
  );

  final CrmDeal deal;
  final List<CrmActivity> activities;
  final List<DealQuotation> quotations;
  final List<StageChange> history;
}

class PipelineStage {
  const PipelineStage({
    required this.stageId,
    required this.name,
    required this.probability,
    required this.count,
    required this.value,
    required this.weightedValue,
  });

  factory PipelineStage.fromJson(Json j) => PipelineStage(
    stageId: asString(j['stageId']),
    name: asString(j['name']),
    probability: asInt(j['probability']),
    count: asInt(j['count']),
    value: asDouble(j['value']),
    weightedValue: asDouble(j['weightedValue']),
  );

  final String stageId, name;
  final int probability, count;
  final double value, weightedValue;
}

class Pipeline {
  const Pipeline({
    required this.openCount,
    required this.openValue,
    required this.weightedValue,
    required this.stages,
  });

  factory Pipeline.fromJson(Json j) => Pipeline(
    openCount: asInt(j['openCount']),
    openValue: asDouble(j['openValue']),
    weightedValue: asDouble(j['weightedValue']),
    stages: asJsonList(j['stages']).map(PipelineStage.fromJson).toList(),
  );

  final int openCount;
  final double openValue, weightedValue;
  final List<PipelineStage> stages;
}

class MonthCard {
  const MonthCard({
    required this.month,
    required this.target,
    required this.won,
    required this.openCount,
    required this.openValue,
    required this.weightedValue,
  });

  factory MonthCard.fromJson(Json j) => MonthCard(
    month: asString(j['month']),
    target: asDouble(j['target']),
    won: asDouble(j['won']),
    openCount: asInt(j['openCount']),
    openValue: asDouble(j['openValue']),
    weightedValue: asDouble(j['weightedValue']),
  );

  final String month;
  final double target, won, openValue, weightedValue;
  final int openCount;
}

class TodayData {
  const TodayData({
    required this.dueToday,
    required this.overdueCount,
    required this.newLeads,
    required this.overdue,
    required this.today,
    required this.upcoming,
    required this.month,
  });

  factory TodayData.fromJson(Json j) {
    final c = asJson(j['counts']);
    List<CrmActivity> list(String k) =>
        asJsonList(j[k]).map(CrmActivity.fromJson).toList();
    return TodayData(
      dueToday: asInt(c['dueToday']),
      overdueCount: asInt(c['overdue']),
      newLeads: asInt(c['newLeads']),
      overdue: list('overdue'),
      today: list('today'),
      upcoming: list('upcoming'),
      month: MonthCard.fromJson(asJson(j['month'])),
    );
  }

  final int dueToday, overdueCount, newLeads;
  final List<CrmActivity> overdue, today, upcoming;
  final MonthCard month;
}

class SourceStat {
  const SourceStat(this.source, this.leads, this.converted, this.rate);
  final String source;
  final int leads, converted;
  final double rate;
}

class StageStat {
  const StageStat(this.name, this.entered, this.advanced, this.rate);
  final String name;
  final int entered, advanced;
  final double rate;
}

class OwnerStat {
  const OwnerStat(this.name, this.wonValue, this.wonCount, this.openValue);
  final String name;
  final double wonValue, openValue;
  final int wonCount;
}

class CrmStats {
  const CrmStats({
    required this.openCount,
    required this.openValue,
    required this.weightedValue,
    required this.wonCount,
    required this.wonValue,
    required this.lostCount,
    this.winRate,
    required this.avgDealSize,
    this.avgCycleDays,
    required this.target,
    required this.achievement,
    required this.gap,
    required this.achievementPct,
    this.coverage,
    this.avgResponseHours,
    required this.stageConversion,
    required this.bySource,
    required this.lostReasons,
    this.byOwner,
  });

  factory CrmStats.fromJson(Json j) => CrmStats(
    openCount: asInt(j['openCount']),
    openValue: asDouble(j['openValue']),
    weightedValue: asDouble(j['weightedValue']),
    wonCount: asInt(j['wonCount']),
    wonValue: asDouble(j['wonValue']),
    lostCount: asInt(j['lostCount']),
    winRate: asDoubleOrNull(j['winRate']),
    avgDealSize: asDouble(j['avgDealSize']),
    avgCycleDays: asDoubleOrNull(j['avgCycleDays']),
    target: asDouble(j['target']),
    achievement: asDouble(j['achievement']),
    gap: asDouble(j['gap']),
    achievementPct: asDouble(j['achievementPct']),
    coverage: asDoubleOrNull(j['coverage']),
    avgResponseHours: asDoubleOrNull(j['avgResponseHours']),
    stageConversion: [
      for (final s in asJsonList(j['stageConversion']))
        StageStat(
          asString(s['name']),
          asInt(s['entered']),
          asInt(s['advanced']),
          asDouble(s['rate']),
        ),
    ],
    bySource: [
      for (final s in asJsonList(j['bySource']))
        SourceStat(
          asString(s['source']),
          asInt(s['leads']),
          asInt(s['converted']),
          asDouble(s['rate']),
        ),
    ],
    lostReasons: [
      for (final s in asJsonList(j['lostReasons']))
        (asString(s['reason']), asInt(s['count'])),
    ],
    byOwner: j['byOwner'] is List
        ? [
            for (final s in asJsonList(j['byOwner']))
              OwnerStat(
                asString(s['name']),
                asDouble(s['wonValue']),
                asInt(s['wonCount']),
                asDouble(s['openValue']),
              ),
          ]
        : null,
  );

  final int openCount, wonCount, lostCount;
  final double openValue, weightedValue, wonValue, avgDealSize;
  final double? winRate, avgCycleDays, coverage, avgResponseHours;
  final double target, achievement, gap, achievementPct;
  final List<StageStat> stageConversion;
  final List<SourceStat> bySource;
  final List<(String, int)> lostReasons;
  final List<OwnerStat>? byOwner;
}

class TimelineItem {
  const TimelineItem({
    this.at,
    required this.kind,
    required this.title,
    this.detail,
    this.refId,
    this.amount,
  });

  factory TimelineItem.fromJson(Json j) => TimelineItem(
    at: asDateTimeOrNull(j['at']),
    kind: asString(j['kind']),
    title: asString(j['title']),
    detail: asStringOrNull(j['detail']),
    refId: asStringOrNull(j['refId']),
    amount: asDoubleOrNull(j['amount']),
  );

  final DateTime? at;
  final String kind, title;
  final String? detail, refId;
  final double? amount;
}

class PartyOverview {
  const PartyOverview({
    required this.partyId,
    required this.name,
    this.phone,
    this.email,
    this.gstin,
    required this.owes,
    required this.overdue,
    this.oldestOverdueDays,
    this.creditLimit,
    this.creditUsedPct,
    required this.sales12m,
    this.avgDaysToPay,
    this.lastInvoiceDate,
    required this.openDeals,
    required this.contacts,
    required this.timeline,
  });

  factory PartyOverview.fromJson(Json j) {
    final p = asJson(j['party']);
    return PartyOverview(
      partyId: asString(p['id']),
      name: asString(p['name']),
      phone: asStringOrNull(p['phone']),
      email: asStringOrNull(p['email']),
      gstin: asStringOrNull(p['gstin']),
      owes: asDouble(j['owes']),
      overdue: asDouble(j['overdue']),
      oldestOverdueDays: j['oldestOverdueDays'] == null
          ? null
          : asInt(j['oldestOverdueDays']),
      creditLimit: asDoubleOrNull(j['creditLimit']),
      creditUsedPct: asDoubleOrNull(j['creditUsedPct']),
      sales12m: asDouble(j['sales12m']),
      avgDaysToPay: asDoubleOrNull(j['avgDaysToPay']),
      lastInvoiceDate: asStringOrNull(j['lastInvoiceDate']),
      openDeals: asJsonList(j['openDeals']).map(CrmDeal.fromJson).toList(),
      contacts: asJsonList(j['contacts']),
      timeline: asJsonList(j['timeline']).map(TimelineItem.fromJson).toList(),
    );
  }

  final String partyId, name;
  final String? phone, email, gstin, lastInvoiceDate;
  final double owes, overdue, sales12m;
  final int? oldestOverdueDays;
  final double? creditLimit, creditUsedPct, avgDaysToPay;
  final List<CrmDeal> openDeals;
  final List<Json> contacts;
  final List<TimelineItem> timeline;
}

class CrmSettings {
  const CrmSettings({
    this.defaultOwnerId,
    required this.lostReasons,
    required this.hasIndiamartKey,
    this.indiamartLastPullAt,
    this.indiamartLastError,
  });

  factory CrmSettings.fromJson(Json j) => CrmSettings(
    defaultOwnerId: asStringOrNull(j['defaultOwnerId']),
    lostReasons: asStringList(j['lostReasons']),
    hasIndiamartKey: asBool(j['hasIndiamartKey']),
    indiamartLastPullAt: asDateTimeOrNull(j['indiamartLastPullAt']),
    indiamartLastError: asStringOrNull(j['indiamartLastError']),
  );

  final String? defaultOwnerId, indiamartLastError;
  final List<String> lostReasons;
  final bool hasIndiamartKey;
  final DateTime? indiamartLastPullAt;
}

class CrmOwner {
  const CrmOwner(this.id, this.name);
  final String id, name;
}

class TargetRow {
  const TargetRow({this.userId, required this.userName, required this.amount});

  factory TargetRow.fromJson(Json j) => TargetRow(
    userId: asStringOrNull(j['userId']),
    userName: asString(j['userName']),
    amount: asDouble(j['amount']),
  );

  final String? userId;
  final String userName;
  final double amount;
}

class IndiamartResult {
  const IndiamartResult(this.added, this.skipped);
  final int added, skipped;
}

/// Local time as ISO 8601 with its UTC offset, e.g. `2026-11-14T11:00:00+05:30`.
String isoWithOffset(DateTime t) {
  final l = t.toLocal();
  final o = l.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final h = o.inHours.abs().toString().padLeft(2, '0');
  final m = (o.inMinutes.abs() % 60).toString().padLeft(2, '0');
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}'
      'T${two(l.hour)}:${two(l.minute)}:${two(l.second)}$sign$h:$m';
}
