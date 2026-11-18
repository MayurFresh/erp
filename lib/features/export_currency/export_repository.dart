import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'export_models.dart';

/// Bumped after any write here so lists reload.
final exportRevisionProvider = NotifierProvider<ExportRevision, int>(
  ExportRevision.new,
);

class ExportRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final exportRepositoryProvider = Provider<ExportRepository>(
  (ref) => ExportRepository(ref.watch(apiClientProvider)),
);

final challanProvider = FutureProvider.autoDispose.family<Challan, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).challan(id);
});

final currenciesProvider = FutureProvider.autoDispose<List<Currency>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).currencies();
});

final ratesProvider = FutureProvider.autoDispose<List<FxRate>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).rates();
});

final lutsProvider = FutureProvider.autoDispose<List<Lut>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).luts();
});

final tcsNaturesProvider = FutureProvider.autoDispose<List<TcsNature>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).natures();
});

final exportSettingsProvider = FutureProvider.autoDispose<ExportSettings>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(exportRevisionProvider);
  return ref.watch(exportRepositoryProvider).settings();
});

class ExportRepository {
  ExportRepository(this._api);

  final ApiClient _api;

  // Challans.
  Future<Paged<ChallanSummary>> challans({
    String? q,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/delivery-challans',
    ChallanSummary.fromJson,
    query: {'q': q, 'status': status, 'offset': offset, 'limit': limit},
  );

  Future<Challan> challan(String id) async =>
      Challan.fromJson(await _api.getJson('/delivery-challans/$id'));

  Future<Challan> createChallan(ChallanInput input) async => Challan.fromJson(
    await _api.postJson('/delivery-challans', body: input.toJson()),
  );

  Future<Challan> returnGoods(String id, Map<String, double> qtyByLine) async =>
      Challan.fromJson(
        await _api.postJson(
          '/delivery-challans/$id/return',
          body: {
            'lines': [
              for (final e in qtyByLine.entries)
                {'lineId': e.key, 'qty': e.value},
            ],
          },
        ),
      );

  /// Bills the pending quantity (all lines when [qtyByLine] is null). Returns
  /// the new invoice id.
  Future<String> billChallan(String id, {Map<String, double>? qtyByLine}) async {
    final r = await _api.postJson(
      '/delivery-challans/$id/invoice',
      body: {
        if (qtyByLine != null)
          'lines': [
            for (final e in qtyByLine.entries)
              {'lineId': e.key, 'qty': e.value},
          ],
      },
    );
    return asString(asJson(r['invoice'])['id']);
  }

  Future<Challan> cancelChallan(String id, String reason) async =>
      Challan.fromJson(
        await _api.postJson(
          '/delivery-challans/$id/cancel',
          body: {'reason': reason},
        ),
      );

  // Settings, LUT, currencies and rates.
  Future<ExportSettings> settings() async =>
      ExportSettings.fromJson(await _api.getJson('/export/settings'));

  Future<ExportSettings> saveSettings({bool? tcsEnabled, String? tcsBase}) async =>
      ExportSettings.fromJson(
        await _api.patchJson(
          '/export/settings',
          body: withoutNulls({'tcsEnabled': tcsEnabled, 'tcsBase': tcsBase}),
        ),
      );

  Future<List<Lut>> luts() async => [
    for (final j in asJsonList((await _api.getJson('/export/luts'))['data']))
      Lut.fromJson(j),
  ];

  Future<void> addLut({
    required String fy,
    required String lutNo,
    required String validFrom,
    required String validTo,
    String? arn,
  }) async {
    await _api.postJson(
      '/export/luts',
      body: withoutNulls({
        'fy': fy,
        'lutNo': lutNo,
        'arn': arn,
        'validFrom': validFrom,
        'validTo': validTo,
      }),
    );
  }

  Future<List<Currency>> currencies() async => [
    for (final j in asJsonList((await _api.getJson('/fx/currencies'))['data']))
      Currency.fromJson(j),
  ];

  Future<void> addCurrency({
    required String code,
    required String name,
    required String symbol,
    required int decimals,
  }) async {
    await _api.postJson(
      '/fx/currencies',
      body: {'code': code, 'name': name, 'symbol': symbol, 'decimals': decimals},
    );
  }

  Future<List<FxRate>> rates({String? code}) async => [
    for (final j in asJsonList(
      (await _api.getJson('/fx/rates', query: {'code': code}))['data'],
    ))
      FxRate.fromJson(j),
  ];

  Future<void> addRate({
    required String code,
    required String date,
    required double rate,
    String? note,
  }) async {
    await _api.postJson(
      '/fx/rates',
      body: withoutNulls({'code': code, 'date': date, 'rate': rate, 'note': note}),
    );
  }

  /// The latest rate on or before [date], or null when none is entered.
  Future<FxRate?> latestRate(String code, String date) async {
    try {
      final j = await _api.getJson(
        '/fx/rates/latest',
        query: {'code': code, 'date': date},
      );
      return FxRate(
        code: code,
        date: asString(j['date']),
        rate: asDouble(j['rate']),
        note: asStringOrNull(j['note']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Foreign invoices still open for a customer, for the receipt form.
  Future<List<Json>> outstanding(String partyId, String currency) async =>
      asJsonList(
        (await _api.getJson(
          '/fx/outstanding',
          query: {'partyId': partyId, 'currency': currency},
        ))['data'],
      );

  Future<Json> foreignReceipt({
    required String partyId,
    required String accountId,
    required String currency,
    required double fcAmount,
    required double rate,
    String? reference,
  }) => _api.postJson(
    '/fx/receipts',
    body: withoutNulls({
      'partyId': partyId,
      'accountId': accountId,
      'currency': currency,
      'fcAmount': fcAmount,
      'rate': rate,
      'reference': reference,
    }),
  );

  Future<Json> revalue(String asOf, {bool post = false, Map<String, double>? rates}) =>
      _api.postJson(
        post ? '/fx/revaluation' : '/fx/revaluation/preview',
        body: withoutNulls({'asOf': asOf, 'rates': rates}),
      );

  // Foreign payables.
  Future<List<Json>> payables() async =>
      asJsonList((await _api.getJson('/fx/payables'))['data']);

  Future<Json> tagPayable(String purchaseId, String currency, double rate) =>
      _api.patchJson('/fx/payables/$purchaseId', body: {'currency': currency, 'rate': rate});

  Future<Json> revaluePayables(String asOf, {bool post = false, Map<String, double>? rates}) =>
      _api.postJson(
        post ? '/fx/payables/revaluation' : '/fx/payables/revaluation/preview',
        body: withoutNulls({'asOf': asOf, 'rates': rates}),
      );

  // TCS.
  Future<List<TcsNature>> natures() async => [
    for (final j in asJsonList((await _api.getJson('/tcs/natures'))['data']))
      TcsNature.fromJson(j),
  ];

  Future<void> saveNature(String id, {double? rate, bool? isActive}) async {
    await _api.patchJson(
      '/tcs/natures/$id',
      body: withoutNulls({'rate': rate, 'isActive': isActive}),
    );
  }

  Future<TcsReport> tcsReport(String from, String to) async => TcsReport.fromJson(
    await _api.getJson('/tcs/report', query: {'from': from, 'to': to}),
  );
}
