import '../../core/business_profile.dart';
import '../../core/json.dart';

/// The words a business uses for memberships. A housing society reads
/// "Flats" and "Maintenance"; a gym or salon reads "Members" and "Plans".
class MemWords {
  const MemWords._({
    required this.society,
    required this.title,
    required this.member,
    required this.plan,
    required this.newMember,
    required this.bills,
    required this.billsRun,
  });

  factory MemWords.of(BusinessProfile profile) {
    if (profile.type == 'housing_society') {
      return const MemWords._(
        society: true,
        title: 'Maintenance',
        member: 'Flat',
        plan: 'Maintenance rate',
        newMember: 'Add flat',
        bills: 'Maintenance bills',
        billsRun: 'Generate maintenance bills',
      );
    }
    return const MemWords._(
      society: false,
      title: 'Memberships',
      member: 'Member',
      plan: 'Plan',
      newMember: 'New member',
      bills: 'Renewal bills',
      billsRun: 'Generate renewal bills',
    );
  }

  final bool society;
  final String title;
  final String member;
  final String plan;
  final String newMember;
  final String bills;
  final String billsRun;

  String get members => '${member}s';
  String get plans => '${plan}s';
  String get memberLower => member.toLowerCase();
  String get membersLower => members.toLowerCase();
}

class MemPlan {
  const MemPlan({
    required this.id,
    required this.name,
    required this.billing,
    required this.rateBasis,
    required this.durationUnit,
    required this.durationCount,
    required this.price,
    required this.gstRate,
    required this.joiningFee,
    required this.freezeDays,
    required this.isActive,
    this.updatedAt,
  });

  factory MemPlan.fromJson(Json j) => MemPlan(
    id: asString(j['id']),
    name: asString(j['name']),
    billing: asString(j['billing'], 'upfront'),
    rateBasis: asString(j['rateBasis'], 'fixed'),
    durationUnit: asString(j['durationUnit'], 'months'),
    durationCount: asInt(j['durationCount'], 1),
    price: asDouble(j['price']),
    gstRate: asDouble(j['gstRate']),
    joiningFee: asDouble(j['joiningFee']),
    freezeDays: asInt(j['freezeDays']),
    isActive: asBool(j['isActive'], true),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String name;
  final String billing;
  final String rateBasis;
  final String durationUnit;
  final int durationCount;
  final double price;
  final double gstRate;
  final double joiningFee;
  final int freezeDays;
  final bool isActive;
  final String? updatedAt;

  bool get perSqft => rateBasis == 'per_sqft';
  bool get monthly => billing == 'monthly';

  String get term => monthly
      ? 'Billed every month'
      : '$durationCount ${durationUnit == 'days' ? 'day' : 'month'}${durationCount == 1 ? '' : 's'}';
}

class MemSummary {
  const MemSummary({
    this.active = 0,
    this.expiring = 0,
    this.expired = 0,
    this.frozen = 0,
    this.total = 0,
    this.visitsToday = 0,
    this.duesMembers = 0,
    this.duesAmount = 0,
  });

  factory MemSummary.fromJson(Json j) => MemSummary(
    active: asInt(j['active']),
    expiring: asInt(j['expiring']),
    expired: asInt(j['expired']),
    frozen: asInt(j['frozen']),
    total: asInt(j['total']),
    visitsToday: asInt(j['visitsToday']),
    duesMembers: asInt(j['duesMembers']),
    duesAmount: asDouble(j['duesAmount']),
  );

  final int active;
  final int expiring;
  final int expired;
  final int frozen;
  final int total;
  final int visitsToday;
  final int duesMembers;
  final double duesAmount;
}

/// A row of the member list.
class MemberBrief {
  const MemberBrief({
    required this.id,
    required this.memberNo,
    required this.name,
    required this.status,
    this.phone,
    this.flatNo,
    this.wing,
    this.areaSqft,
    this.planName,
    this.endDate,
    this.daysLeft,
    this.photoFileId,
    this.occupancy,
  });

  factory MemberBrief.fromJson(Json j) => MemberBrief(
    id: asString(j['id']),
    memberNo: asString(j['memberNo']),
    name: asString(j['name']),
    status: asString(j['status'], 'none'),
    phone: asStringOrNull(j['phone']),
    flatNo: asStringOrNull(j['flatNo']),
    wing: asStringOrNull(j['wing']),
    areaSqft: asDoubleOrNull(j['areaSqft']),
    planName: asJsonOrNull(j['plan'])?['name']?.toString(),
    endDate: asStringOrNull(j['endDate']),
    daysLeft: j['daysLeft'] == null ? null : asInt(j['daysLeft']),
    photoFileId: asStringOrNull(j['photoFileId']),
    occupancy: asStringOrNull(j['occupancy']),
  );

  final String id;
  final String memberNo;
  final String name;
  final String status;
  final String? phone;
  final String? flatNo;
  final String? wing;
  final double? areaSqft;
  final String? planName;
  final String? endDate;
  final int? daysLeft;
  final String? photoFileId;
  final String? occupancy;

  String get flatLabel => [wing, flatNo].whereType<String>().join(' ');
}

String memStatusLabel(String s) => switch (s) {
  'active' => 'Active',
  'expiring' => 'Expiring soon',
  'expired' => 'Expired',
  'frozen' => 'Frozen',
  _ => 'No plan',
};

class MemSubscription {
  const MemSubscription({
    required this.id,
    required this.planId,
    required this.planName,
    required this.startDate,
    required this.price,
    required this.status,
    required this.freezeDaysUsed,
    required this.freezeDaysAllowed,
    this.endDate,
    this.frozenFrom,
  });

  factory MemSubscription.fromJson(Json j) => MemSubscription(
    id: asString(j['id']),
    planId: asString(j['planId']),
    planName: asString(j['planName']),
    startDate: asString(j['startDate']),
    endDate: asStringOrNull(j['endDate']),
    price: asDouble(j['price']),
    status: asString(j['status'], 'active'),
    frozenFrom: asStringOrNull(j['frozenFrom']),
    freezeDaysUsed: asInt(j['freezeDaysUsed']),
    freezeDaysAllowed: asInt(j['freezeDaysAllowed']),
  );

  final String id;
  final String planId;
  final String planName;
  final String startDate;
  final String? endDate;
  final double price;
  final String status;
  final String? frozenFrom;
  final int freezeDaysUsed;
  final int freezeDaysAllowed;

  bool get frozen => status == 'frozen';
  int get freezeLeft => freezeDaysAllowed - freezeDaysUsed;
}

class MemBill {
  const MemBill({
    required this.invoiceId,
    required this.number,
    required this.date,
    required this.total,
    required this.amountPaid,
    required this.period,
  });

  factory MemBill.fromJson(Json j) => MemBill(
    invoiceId: asString(j['invoiceId']),
    number: asString(j['number']),
    date: asString(j['date']),
    total: asDouble(j['total']),
    amountPaid: asDouble(j['amountPaid']),
    period: asString(j['period']),
  );

  final String invoiceId;
  final String number;
  final String date;
  final double total;
  final double amountPaid;
  final String period;

  double get due => total - amountPaid;
}

class MemberFile {
  const MemberFile({
    required this.brief,
    required this.subscriptions,
    required this.bills,
    required this.visits,
    required this.dueAmount,
    this.emergencyName,
    this.emergencyPhone,
    this.notes,
    this.occupancy,
  });

  factory MemberFile.fromJson(Json j) => MemberFile(
    brief: MemberBrief.fromJson(j),
    subscriptions: asJsonList(
      j['subscriptions'],
    ).map(MemSubscription.fromJson).toList(),
    bills: asJsonList(j['bills']).map(MemBill.fromJson).toList(),
    visits: asJsonList(j['visits']).map((v) => asString(v['date'])).toList(),
    dueAmount: asDouble(j['dueAmount']),
    emergencyName: asStringOrNull(j['emergencyName']),
    emergencyPhone: asStringOrNull(j['emergencyPhone']),
    notes: asStringOrNull(j['notes']),
    occupancy: asStringOrNull(j['occupancy']),
  );

  final MemberBrief brief;
  final List<MemSubscription> subscriptions;
  final List<MemBill> bills;
  final List<String> visits;
  final double dueAmount;
  final String? emergencyName;
  final String? emergencyPhone;
  final String? notes;
  final String? occupancy;

  MemSubscription? get current =>
      subscriptions.isEmpty ? null : subscriptions.first;
}

class DueRow {
  const DueRow({
    required this.memberId,
    required this.memberNo,
    required this.name,
    required this.due,
    required this.bills,
    required this.reminder,
    this.phone,
    this.flatNo,
    this.wing,
  });

  factory DueRow.fromJson(Json j) => DueRow(
    memberId: asString(j['memberId']),
    memberNo: asString(j['memberNo']),
    name: asString(j['name']),
    phone: asStringOrNull(j['phone']),
    flatNo: asStringOrNull(j['flatNo']),
    wing: asStringOrNull(j['wing']),
    due: asDouble(j['due']),
    bills: asInt(j['bills']),
    reminder: asString(j['reminder']),
  );

  final String memberId;
  final String memberNo;
  final String name;
  final String? phone;
  final String? flatNo;
  final String? wing;
  final double due;
  final int bills;
  final String reminder;
}

class CheckinResult {
  const CheckinResult({
    required this.name,
    required this.memberNo,
    required this.expiringSoon,
    required this.repeatToday,
    this.endDate,
    this.daysLeft,
  });

  factory CheckinResult.fromJson(Json j) => CheckinResult(
    name: asString(j['name']),
    memberNo: asString(j['memberNo']),
    endDate: asStringOrNull(j['endDate']),
    daysLeft: j['daysLeft'] == null ? null : asInt(j['daysLeft']),
    expiringSoon: asBool(j['expiringSoon']),
    repeatToday: asBool(j['repeatToday']),
  );

  final String name;
  final String memberNo;
  final String? endDate;
  final int? daysLeft;
  final bool expiringSoon;
  final bool repeatToday;
}

class RunPreview {
  const RunPreview({
    required this.count,
    required this.alreadyBilled,
    required this.skipped,
  });

  factory RunPreview.fromJson(Json j) => RunPreview(
    count: asInt(j['count']),
    alreadyBilled: asInt(j['alreadyBilled']),
    skipped: asJsonList(j['skipped'])
        .map((s) => '${asString(s['memberNo'])}: ${asString(s['reason'])}')
        .toList(),
  );

  final int count;
  final int alreadyBilled;
  final List<String> skipped;
}
