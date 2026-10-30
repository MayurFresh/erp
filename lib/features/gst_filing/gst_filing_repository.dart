import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../filings/filings_repository.dart';
import 'gst_filing_models.dart';

/// Bumped after a ledger snapshot or GST payment is written.
final gstFilingRevisionProvider = NotifierProvider<GstFilingRevision, int>(
  GstFilingRevision.new,
);

class GstFilingRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final gstFilingRepositoryProvider = Provider<GstFilingRepository>(
  (ref) => GstFilingRepository(ref.watch(apiClientProvider)),
);

void _base(Ref ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(gstFilingRevisionProvider);
  ref.watch(filingsRevisionProvider);
}

final prefileProvider = FutureProvider.autoDispose
    .family<PrefileResult, (String, String)>((ref, key) {
      _base(ref);
      return ref.watch(gstFilingRepositoryProvider).prefile(key.$1, key.$2);
    });

final setoffProvider = FutureProvider.autoDispose
    .family<Setoff, (String, String)>((ref, key) {
      _base(ref);
      return ref.watch(gstFilingRepositoryProvider).setoff(key.$1, key.$2);
    });

final gstr3bSheetProvider = FutureProvider.autoDispose
    .family<Gstr3bSheet, String>((ref, period) {
      _base(ref);
      return ref.watch(gstFilingRepositoryProvider).gstr3b(period);
    });

final ledgerSnapshotsProvider =
    FutureProvider.autoDispose<List<LedgerSnapshot>>((ref) {
      _base(ref);
      return ref.watch(gstFilingRepositoryProvider).ledgerBalances();
    });

final gstPaymentsProvider = FutureProvider.autoDispose
    .family<List<GstPayment>, String>((ref, fy) {
      _base(ref);
      return ref.watch(gstFilingRepositoryProvider).payments(fy);
    });

final itcReversalsProvider = FutureProvider.autoDispose
    .family<ItcReversals, String>((ref, period) {
      _base(ref);
      return ref.watch(gstFilingRepositoryProvider).itcReversals(period);
    });

final gstr9Provider = FutureProvider.autoDispose.family<Gstr9Pack, String>((
  ref,
  fy,
) {
  _base(ref);
  return ref.watch(gstFilingRepositoryProvider).gstr9(fy);
});

class GstFilingRepository {
  GstFilingRepository(this._api);

  final ApiClient _api;

  Future<PrefileResult> prefile(String period, String returnType) async =>
      PrefileResult.fromJson(
        await _api.getJson(
          '/gst/prefile-check',
          query: {'period': period, 'return': returnType},
        ),
      );

  Future<String> gstr1Gstn(String period) =>
      _api.getText('/gst/gstr1', query: {'period': period, 'format': 'gstn'});

  Future<Gstr3bSheet> gstr3b(String period) async => Gstr3bSheet.fromJson(
    await _api.getJson('/gst/gstr3b', query: {'period': period}),
  );

  Future<Setoff> setoff(String period, String igstSplit) async =>
      Setoff.fromJson(
        await _api.getJson(
          '/gst/setoff',
          query: {'period': period, 'igstSplit': igstSplit},
        ),
      );

  Future<List<LedgerSnapshot>> ledgerBalances() async {
    final j = await _api.getJson('/gst/ledger-balances');
    return asJsonList(j['data']).map(LedgerSnapshot.fromJson).toList();
  }

  Future<void> addLedgerBalance(Map<String, dynamic> body) =>
      _api.postJson('/gst/ledger-balances', body: body);

  Future<List<GstPayment>> payments(String fy) async {
    final page = await _api.getPage(
      '/gst/payments',
      GstPayment.fromJson,
      query: {'fy': fy},
    );
    return page.data;
  }

  Future<GstPayment> createPayment(Map<String, dynamic> body) async =>
      GstPayment.fromJson(await _api.postJson('/gst/payments', body: body));

  Future<void> cancelPayment(String id, String reason) =>
      _api.postJson('/gst/payments/$id/cancel', body: {'reason': reason});

  Future<ItcReversals> itcReversals(String period) async =>
      ItcReversals.fromJson(
        await _api.getJson('/gst/itc-reversals', query: {'period': period}),
      );

  Future<String> itcReversalsCsv(String period) => _api.getText(
    '/gst/itc-reversals',
    query: {'period': period, 'format': 'csv'},
  );

  Future<Gstr9Pack> gstr9(String fy) async =>
      Gstr9Pack.fromJson(await _api.getJson('/gst/gstr9', query: {'fy': fy}));

  Future<String> gstr9Csv(String fy) =>
      _api.getText('/gst/gstr9', query: {'fy': fy, 'format': 'csv'});
}
