import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../filings/filing_models.dart' show PrefileCheck;
import 'it_models.dart';

/// Bumped after an income-tax write so lists reload.
final taxRevisionProvider = NotifierProvider<TaxRevision, int>(TaxRevision.new);

class TaxRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final incomeTaxRepositoryProvider = Provider<IncomeTaxRepository>(
  (ref) => IncomeTaxRepository(ref.watch(apiClientProvider)),
);

extension _Watch on Ref {
  void base() {
    watch(activeCompanyIdProvider);
    watch(taxRevisionProvider);
  }
}

final taxPaymentsProvider = FutureProvider.autoDispose
    .family<List<TaxPayment>, String>((ref, taxYear) {
      ref.base();
      return ref.watch(incomeTaxRepositoryProvider).payments(taxYear);
    });

final caRequiredProvider = FutureProvider.autoDispose
    .family<CaRequired, String>((ref, taxYear) {
      ref.base();
      return ref.watch(incomeTaxRepositoryProvider).caRequired(taxYear);
    });

final itrPackProvider = FutureProvider.autoDispose
    .family<ItrPack, (String, String)>((ref, key) {
      ref.base();
      return ref.watch(incomeTaxRepositoryProvider).itrPack(key.$1, key.$2);
    });

final tdsPrefileProvider = FutureProvider.autoDispose
    .family<TdsPrefile, (String, int)>((ref, key) {
      ref.base();
      return ref.watch(incomeTaxRepositoryProvider).tdsPrefile(key.$1, key.$2);
    });

final tdsDefaultsProvider = FutureProvider.autoDispose
    .family<TdsDefaults, String>((ref, fy) {
      ref.base();
      return ref.watch(incomeTaxRepositoryProvider).tdsDefaults(fy);
    });

/// `GET /tds/prefile-check`.
class TdsPrefile {
  const TdsPrefile({required this.checks, required this.canFile});

  factory TdsPrefile.fromJson(Json j) => TdsPrefile(
    checks: asJsonList(j['checks']).map(PrefileCheck.fromJson).toList(),
    canFile: asBool(j['canFile']),
  );

  final List<PrefileCheck> checks;
  final bool canFile;
}

class IncomeTaxRepository {
  IncomeTaxRepository(this._api);

  final ApiClient _api;

  Future<List<TaxPayment>> payments(String taxYear) async => asJsonList(
    (await _api.getJson(
      '/tax/payments',
      query: {if (taxYear.isNotEmpty) 'taxYear': taxYear},
    ))['data'],
  ).map(TaxPayment.fromJson).toList();

  Future<TaxPayment> recordPayment(Json body) async =>
      TaxPayment.fromJson(await _api.postJson('/tax/payments', body: body));

  Future<void> cancelPayment(String id, String reason) =>
      _api.postJson('/tax/payments/$id/cancel', body: {'reason': reason});

  Future<RegimeResult> regime(Json body) async => RegimeResult.fromJson(
    await _api.postJson('/tax/calc/regime', body: body),
  );

  Future<PresumptiveResult> presumptive(Json body) async =>
      PresumptiveResult.fromJson(
        await _api.postJson('/tax/calc/presumptive', body: body),
      );

  Future<AdvanceTax> advanceTax({
    required String taxYear,
    double? estimatedIncome,
    required String regime,
    required bool presumptive,
  }) async => AdvanceTax.fromJson(
    await _api.getJson(
      '/tax/advance-tax',
      query: {
        'taxYear': taxYear,
        'estimatedIncome': ?estimatedIncome,
        'regime': regime,
        'presumptive': presumptive,
      },
    ),
  );

  Future<ItrPack> itrPack(String taxYear, String form) async =>
      ItrPack.fromJson(
        await _api.getJson(
          '/tax/itr-pack',
          query: {'taxYear': taxYear, 'form': form, 'format': 'json'},
        ),
      );

  Future<String> itrPackCsv(String taxYear, String form) => _api.getText(
    '/tax/itr-pack',
    query: {'taxYear': taxYear, 'form': form, 'format': 'csv'},
  );

  Future<CaRequired> caRequired(String taxYear) async => CaRequired.fromJson(
    await _api.getJson('/tax/ca-required', query: {'taxYear': taxYear}),
  );

  Future<TdsPrefile> tdsPrefile(String fy, int quarter) async =>
      TdsPrefile.fromJson(
        await _api.getJson(
          '/tds/prefile-check',
          query: {'fy': fy, 'quarter': quarter},
        ),
      );

  Future<TdsDefaults> tdsDefaults(String fy) async => TdsDefaults.fromJson(
    await _api.getJson('/tds/defaults', query: {'fy': fy}),
  );

  Future<String> tdsStatementTxt(String fy, int quarter) => _api.getText(
    '/tds/statement',
    query: {'fy': fy, 'quarter': quarter, 'format': 'txt'},
  );
}
