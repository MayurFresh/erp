import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'report_models.dart';

final reportsRepositoryProvider = Provider<ReportsRepository>(
  (ref) => ReportsRepository(ref.watch(apiClientProvider)),
);

/// Writes that can change any report.
const reportKinds = [
  ...moneyKinds,
  DataKind.accounts,
  DataKind.expenses,
  DataKind.stock,
  DataKind.transfers,
  DataKind.items,
];

/// `from`/`to` as `YYYY-MM-DD`, plus an optional location.
typedef PeriodKey = ({String from, String to, String? locationId});

extension on Ref {
  ReportsRepository reports() {
    watch(activeCompanyIdProvider);
    watchRevisions(reportKinds);
    return watch(reportsRepositoryProvider);
  }
}

final trialBalanceProvider = FutureProvider.autoDispose
    .family<TrialBalance, String>(
      (ref, asOf) => ref.reports().trialBalance(asOf: asOf),
    );

final profitLossProvider = FutureProvider.autoDispose
    .family<ProfitLoss, PeriodKey>(
      (ref, k) => ref.reports().profitLoss(from: k.from, to: k.to),
    );

final balanceSheetProvider = FutureProvider.autoDispose
    .family<BalanceSheet, String>(
      (ref, asOf) => ref.reports().balanceSheet(asOf: asOf),
    );

final salesRegisterProvider = FutureProvider.autoDispose
    .family<Register, PeriodKey>(
      (ref, k) => ref.reports().salesRegister(
        from: k.from,
        to: k.to,
        locationId: k.locationId,
      ),
    );

final purchaseRegisterProvider = FutureProvider.autoDispose
    .family<Register, PeriodKey>(
      (ref, k) => ref.reports().purchaseRegister(
        from: k.from,
        to: k.to,
        locationId: k.locationId,
      ),
    );

final gstSummaryProvider = FutureProvider.autoDispose
    .family<GstSummary, PeriodKey>(
      (ref, k) => ref.reports().gstSummary(from: k.from, to: k.to),
    );

/// Keyed by location id (`null` = all locations in scope).
final stockValuationProvider = FutureProvider.autoDispose
    .family<StockValuation, String?>(
      (ref, locationId) =>
          ref.reports().stockValuation(locationId: locationId),
    );

final ageingProvider = FutureProvider.autoDispose
    .family<Ageing, ({AgeingType type, String asOf})>(
      (ref, k) => ref.reports().ageing(k.type, asOf: k.asOf),
    );

class ReportsRepository {
  ReportsRepository(this._api);

  final ApiClient _api;

  Future<TrialBalance> trialBalance({String? asOf}) async =>
      TrialBalance.fromJson(
        await _api.getJson('/reports/trial-balance', query: {'asOf': asOf}),
      );

  Future<ProfitLoss> profitLoss({String? from, String? to}) async =>
      ProfitLoss.fromJson(
        await _api.getJson(
          '/reports/profit-loss',
          query: {'from': from, 'to': to},
        ),
      );

  Future<BalanceSheet> balanceSheet({String? asOf}) async =>
      BalanceSheet.fromJson(
        await _api.getJson('/reports/balance-sheet', query: {'asOf': asOf}),
      );

  Future<Register> salesRegister({
    String? from,
    String? to,
    String? locationId,
  }) async => Register.fromJson(
    await _api.getJson(
      '/reports/sales-register',
      query: {'from': from, 'to': to, 'locationId': locationId},
    ),
  );

  Future<Register> purchaseRegister({
    String? from,
    String? to,
    String? locationId,
  }) async => Register.fromJson(
    await _api.getJson(
      '/reports/purchase-register',
      query: {'from': from, 'to': to, 'locationId': locationId},
    ),
  );

  Future<GstSummary> gstSummary({String? from, String? to}) async =>
      GstSummary.fromJson(
        await _api.getJson(
          '/reports/gst-summary',
          query: {'from': from, 'to': to},
        ),
      );

  Future<StockValuation> stockValuation({String? locationId}) async =>
      StockValuation.fromJson(
        await _api.getJson(
          '/reports/stock-valuation',
          query: {'locationId': locationId},
        ),
      );

  Future<Ageing> ageing(AgeingType type, {String? asOf}) async =>
      Ageing.fromJson(
        await _api.getJson(
          '/reports/ageing',
          query: {'type': type.name, 'asOf': asOf},
        ),
      );
}
