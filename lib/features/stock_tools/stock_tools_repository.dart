import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'stock_tools_models.dart';

final stockToolsRepositoryProvider = Provider<StockToolsRepository>(
  (ref) => StockToolsRepository(ref.watch(apiClientProvider)),
);

final itemUnitsProvider = FutureProvider.autoDispose.family<ItemUnits, String>((
  ref,
  itemId,
) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(stockToolsRepositoryProvider).units(itemId);
});

final valuationSettingProvider = FutureProvider.autoDispose<ValuationSetting>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(stockToolsRepositoryProvider).setting();
});

final valuationTotalProvider = FutureProvider.autoDispose
    .family<ValuationTotal, String>((ref, method) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(stockToolsRepositoryProvider).valuation(method);
    });

final stockAgeingProvider = FutureProvider.autoDispose
    .family<AgeingReport, String?>((ref, locationId) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(stockToolsRepositoryProvider).ageing(locationId);
    });

/// Key: mode, days, cover days and location.
typedef MovementKey = ({String mode, int days, int coverDays, String? locationId});

final stockMovementProvider = FutureProvider.autoDispose
    .family<List<MovementRow>, MovementKey>((ref, k) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(stockToolsRepositoryProvider).movement(k);
    });

class StockToolsRepository {
  StockToolsRepository(this._api);

  final ApiClient _api;

  Future<ItemUnits> units(String itemId) async =>
      ItemUnits.fromJson(await _api.getJson('/items/$itemId/units'));

  Future<ItemUnits> saveUnits(
    String itemId, {
    required List<UnitDef> units,
    String? defaultPurchaseUnit,
    String? defaultSaleUnit,
  }) async => ItemUnits.fromJson(
    await _api.patchJson(
      '/items/$itemId/units',
      body: {
        'units': [for (final u in units) u.toJson()],
        'defaultPurchaseUnit': defaultPurchaseUnit,
        'defaultSaleUnit': defaultSaleUnit,
      },
    ),
  );

  Future<ValuationSetting> setting() async =>
      ValuationSetting.fromJson(await _api.getJson('/stock/valuation-method'));

  Future<ValuationSetting> saveSetting(String method, {String? effectiveFrom}) async =>
      ValuationSetting.fromJson(
        await _api.patchJson(
          '/stock/valuation-method',
          body: {'method': method, 'effectiveFrom': ?effectiveFrom},
        ),
      );

  Future<ValuationTotal> valuation(String method) async => ValuationTotal.fromJson(
    await _api.getJson('/reports/stock-valuation', query: {'method': method}),
  );

  Future<AgeingReport> ageing(String? locationId) async => AgeingReport.fromJson(
    await _api.getJson('/reports/stock-ageing', query: {'locationId': locationId}),
  );

  Future<List<MovementRow>> movement(MovementKey k) async {
    final json = await _api.getJson(
      '/reports/stock-movement',
      query: {
        'mode': k.mode,
        'days': k.days,
        'coverDays': k.coverDays,
        'locationId': k.locationId,
      },
    );
    return [for (final r in asJsonList(json['rows'])) MovementRow.fromJson(r)];
  }
}
