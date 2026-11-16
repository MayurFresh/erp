import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';

/// Bumped after a write so the lists reload.
final gstComplianceRevisionProvider =
    NotifierProvider<GstComplianceRevision, int>(GstComplianceRevision.new);

class GstComplianceRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class ImsRow {
  const ImsRow({
    required this.id,
    required this.bucket,
    required this.deemed,
    required this.imsAction,
    required this.imsReason,
    required this.supplierName,
    required this.supplierGstin,
    required this.docType,
    required this.docNo,
    required this.docDate,
    required this.taxable,
    required this.tax,
    required this.purchaseNumber,
  });

  factory ImsRow.fromJson(Json j) => ImsRow(
    id: asString(j['id']),
    bucket: asString(j['bucket']),
    deemed: asBool(j['deemed']),
    imsAction: asString(j['imsAction'], 'none'),
    imsReason: asString(j['imsReason']),
    supplierName: asString(j['supplierName']),
    supplierGstin: asString(j['supplierGstin']),
    docType: asString(j['docType']),
    docNo: asString(j['docNo']),
    docDate: asString(j['docDate']),
    taxable: asDouble(j['taxable']),
    tax: asDouble(j['igst']) + asDouble(j['cgst']) + asDouble(j['sgst']),
    purchaseNumber: asString(j['purchaseNumber']),
  );

  final String id;
  final String bucket;
  final bool deemed;
  final String imsAction;
  final String imsReason;
  final String supplierName;
  final String supplierGstin;
  final String docType;
  final String docNo;
  final String docDate;
  final double taxable;
  final double tax;
  final String purchaseNumber;
}

class ImsBucketSummary {
  const ImsBucketSummary(this.count, this.itc);

  factory ImsBucketSummary.fromJson(Object? v) {
    final j = asJsonOrNull(v);
    return ImsBucketSummary(asInt(j?['count']), asDouble(j?['itc']));
  }

  final int count;
  final double itc;
}

class ImsView {
  const ImsView({
    required this.imported,
    required this.accepted,
    required this.rejected,
    required this.pending,
    required this.notInBooks,
    required this.deemedAccepted,
    required this.rows,
  });

  factory ImsView.fromJson(Json j) {
    final s = asJson(j['summary']);
    return ImsView(
      imported: j['importedAt'] != null,
      accepted: ImsBucketSummary.fromJson(s['inBooksAccepted']),
      rejected: ImsBucketSummary.fromJson(s['inBooksRejected']),
      pending: ImsBucketSummary.fromJson(s['pending']),
      notInBooks: ImsBucketSummary.fromJson(s['notInBooks']),
      deemedAccepted: asInt(s['deemedAccepted']),
      rows: asJsonList(j['rows']).map(ImsRow.fromJson).toList(),
    );
  }

  final bool imported;
  final ImsBucketSummary accepted;
  final ImsBucketSummary rejected;
  final ImsBucketSummary pending;
  final ImsBucketSummary notInBooks;
  final int deemedAccepted;
  final List<ImsRow> rows;
}

class UnreportedInvoice {
  const UnreportedInvoice({
    required this.invoiceId,
    required this.number,
    required this.date,
    required this.partyName,
    required this.total,
    required this.ageDays,
    required this.lastDay,
    required this.state,
  });

  factory UnreportedInvoice.fromJson(Json j) => UnreportedInvoice(
    invoiceId: asString(j['invoiceId']),
    number: asString(j['number']),
    date: asString(j['date']),
    partyName: asString(j['partyName']),
    total: asDouble(j['total']),
    ageDays: asInt(j['ageDays']),
    lastDay: asString(j['lastDay']),
    state: asString(j['state']),
  );

  final String invoiceId;
  final String number;
  final String date;
  final String partyName;
  final double total;
  final int ageDays;
  final String lastDay;
  final String state;
}

class UnreportedView {
  const UnreportedView({
    required this.band,
    required this.ok,
    required this.warn,
    required this.blocked,
    required this.rows,
  });

  factory UnreportedView.fromJson(Json j) {
    final c = asJson(j['counts']);
    return UnreportedView(
      band: asString(j['band']),
      ok: asInt(c['ok']),
      warn: asInt(c['warn']),
      blocked: asInt(c['blocked']),
      rows: asJsonList(j['rows']).map(UnreportedInvoice.fromJson).toList(),
    );
  }

  final String band;
  final int ok;
  final int warn;
  final int blocked;
  final List<UnreportedInvoice> rows;
}

class SlabRow {
  const SlabRow({
    required this.itemId,
    required this.name,
    required this.hsnCode,
    required this.currentRate,
    required this.proposedRate,
    required this.needsCheck,
    required this.reviewed,
  });

  factory SlabRow.fromJson(Json j) => SlabRow(
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    hsnCode: asString(j['hsnCode']),
    currentRate: asDouble(j['currentRate']),
    proposedRate: asDouble(j['proposedRate']),
    needsCheck: asBool(j['needsCheck']),
    reviewed: asBool(j['reviewed']),
  );

  final String itemId;
  final String name;
  final String hsnCode;
  final double currentRate;
  final double proposedRate;
  final bool needsCheck;
  final bool reviewed;
}

class SlabReview {
  const SlabReview(this.effectiveFrom, this.note, this.rows);

  factory SlabReview.fromJson(Json j) => SlabReview(
    asString(j['effectiveFrom']),
    asString(j['note']),
    asJsonList(j['rows']).map(SlabRow.fromJson).toList(),
  );

  final String effectiveFrom;
  final String note;
  final List<SlabRow> rows;
}

class RateEntry {
  const RateEntry(this.rate, this.effectiveFrom, this.reason);

  factory RateEntry.fromJson(Json j) => RateEntry(
    asDouble(j['rate']),
    asString(j['effectiveFrom']),
    asString(j['reason']),
  );

  final double rate;
  final String effectiveFrom;
  final String reason;
}

class MsmeBhRow {
  const MsmeBhRow({
    required this.number,
    required this.billDate,
    required this.dueDate,
    required this.partyName,
    required this.category,
    required this.outstanding,
    required this.daysOverdue,
  });

  factory MsmeBhRow.fromJson(Json j) => MsmeBhRow(
    number: asString(j['number']),
    billDate: asString(j['billDate']),
    dueDate: asString(j['dueDate']),
    partyName: asString(j['partyName']),
    category: asString(j['category']),
    outstanding: asDouble(j['outstanding']),
    daysOverdue: asInt(j['daysOverdue']),
  );

  final String number;
  final String billDate;
  final String dueDate;
  final String partyName;
  final String category;
  final double outstanding;
  final int daysOverdue;
}

class MsmeBh {
  const MsmeBh(this.asOf, this.total, this.rows);

  factory MsmeBh.fromJson(Json j) => MsmeBh(
    asString(j['asOf']),
    asDouble(j['total']),
    asJsonList(j['rows']).map(MsmeBhRow.fromJson).toList(),
  );

  final String asOf;
  final double total;
  final List<MsmeBhRow> rows;
}

class GstComplianceRepository {
  GstComplianceRepository(this._api);

  final ApiClient _api;

  Future<ImsView> ims(String period) async =>
      ImsView.fromJson(await _api.getJson('/gst/ims', query: {'period': period}));

  Future<int> imsAction(List<String> ids, String action, {String? reason}) async {
    final r = await _api.postJson(
      '/gst/ims/actions',
      body: {'ids': ids, 'action': action, 'reason': ?reason},
    );
    return asInt(r['updated']);
  }

  Future<UnreportedView> unreported() async =>
      UnreportedView.fromJson(await _api.getJson('/gst/einvoice/unreported'));

  Future<SlabReview> slabReview() async =>
      SlabReview.fromJson(await _api.getJson('/gst/slab-review'));

  Future<int> applySlab(String effectiveFrom, Map<String, double> picks) async {
    final r = await _api.postJson(
      '/gst/slab-review/apply',
      body: {
        'effectiveFrom': effectiveFrom,
        'items': [
          for (final e in picks.entries) {'itemId': e.key, 'newRate': e.value},
        ],
      },
    );
    return asInt(r['applied']);
  }

  Future<List<RateEntry>> itemRates(String itemId) async {
    final r = await _api.getJson('/items/$itemId/gst-rates');
    return asJsonList(r['data']).map(RateEntry.fromJson).toList();
  }

  Future<MsmeBh> msme43bh(String taxYear) async => MsmeBh.fromJson(
    await _api.getJson('/reports/msme-43bh', query: {'taxYear': taxYear}),
  );
}

final gstComplianceRepositoryProvider = Provider<GstComplianceRepository>(
  (ref) => GstComplianceRepository(ref.watch(apiClientProvider)),
);

final imsProvider = FutureProvider.autoDispose.family<ImsView, String>((
  ref,
  period,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(gstComplianceRevisionProvider);
  return ref.watch(gstComplianceRepositoryProvider).ims(period);
});

final unreportedProvider = FutureProvider.autoDispose<UnreportedView>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(gstComplianceRevisionProvider);
  return ref.watch(gstComplianceRepositoryProvider).unreported();
});

final slabReviewProvider = FutureProvider.autoDispose<SlabReview>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(gstComplianceRevisionProvider);
  return ref.watch(gstComplianceRepositoryProvider).slabReview();
});

final itemRatesProvider = FutureProvider.autoDispose
    .family<List<RateEntry>, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
  ref.watch(gstComplianceRevisionProvider);
      return ref.watch(gstComplianceRepositoryProvider).itemRates(id);
    });

final msme43bhProvider = FutureProvider.autoDispose.family<MsmeBh, String>((
  ref,
  taxYear,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(gstComplianceRevisionProvider);
  return ref.watch(gstComplianceRepositoryProvider).msme43bh(taxYear);
});
