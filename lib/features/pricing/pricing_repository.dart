import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'pricing_models.dart';

final pricingRepositoryProvider = Provider<PricingRepository>(
  (ref) => PricingRepository(ref.watch(apiClientProvider)),
);

/// Bumped after a pricing write so lists reload.
final pricingRevisionProvider = NotifierProvider<PricingRevision, int>(
  PricingRevision.new,
);

class PricingRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final priceListsProvider = FutureProvider.autoDispose<List<PriceList>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(pricingRevisionProvider);
  return ref.watch(pricingRepositoryProvider).lists(includeInactive: true);
});

final priceListProvider = FutureProvider.autoDispose.family<PriceList, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(pricingRevisionProvider);
  return ref.watch(pricingRepositoryProvider).list(id);
});

final priceSchemesProvider = FutureProvider.autoDispose<List<PriceScheme>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(pricingRevisionProvider);
  return ref.watch(pricingRepositoryProvider).schemes();
});

final customerPricesProvider = FutureProvider.autoDispose
    .family<List<PriceRow>, String>((ref, partyId) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(pricingRevisionProvider);
      return ref.watch(pricingRepositoryProvider).customerPrices(partyId);
    });

class PricingRepository {
  PricingRepository(this._api);

  final ApiClient _api;

  Future<List<PriceList>> lists({bool includeInactive = false}) async {
    final json = await _api.getJson(
      '/price-lists',
      query: {if (includeInactive) 'includeInactive': 'true'},
    );
    return [for (final j in asJsonList(json['data'])) PriceList.fromJson(j)];
  }

  Future<PriceList> list(String id) async =>
      PriceList.fromJson(await _api.getJson('/price-lists/$id'));

  Future<PriceList> createList(Json body) async =>
      PriceList.fromJson(await _api.postJson('/price-lists', body: body));

  Future<void> updateList(String id, Json body) =>
      _api.patch('/price-lists/$id', body: body);

  Future<void> deleteList(String id) => _api.delete('/price-lists/$id');

  Future<void> saveListItems(String id, List<PriceRow> rows) => _api.patch(
    '/price-lists/$id/items',
    body: {
      'items': [
        for (final r in rows)
          {'itemId': r.itemId, 'minQty': r.minQty, 'rate': r.rate},
      ],
    },
  );

  Future<List<PriceRow>> customerPrices(String partyId) async {
    final json = await _api.getJson(
      '/customer-prices',
      query: {'partyId': partyId},
    );
    return [for (final j in asJsonList(json['data'])) PriceRow.fromJson(j)];
  }

  Future<void> saveCustomerPrices(String partyId, List<PriceRow> rows) =>
      _api.patch(
        '/customer-prices',
        body: {
          'partyId': partyId,
          'items': [for (final r in rows) r.toJson()],
        },
      );

  Future<List<PriceScheme>> schemes() async {
    final json = await _api.getJson('/price-schemes');
    return [for (final j in asJsonList(json['data'])) PriceScheme.fromJson(j)];
  }

  Future<void> createScheme(Json body) =>
      _api.post('/price-schemes', body: body);

  Future<void> updateScheme(String id, Json body) =>
      _api.patch('/price-schemes/$id', body: body);

  Future<void> deleteScheme(String id) => _api.delete('/price-schemes/$id');

  /// Prices for many lines in order. Empty on any failure, so a form keeps the
  /// rate the person already sees.
  Future<List<ResolvedPrice>> resolve(
    String? partyId,
    List<({String itemId, double qty})> lines,
  ) async {
    if (lines.isEmpty) return const [];
    try {
      final json = await _api.postJson(
        '/prices/resolve',
        body: {
          'partyId': ?partyId,
          'lines': [
            for (final l in lines) {'itemId': l.itemId, 'qty': l.qty},
          ],
        },
      );
      return [for (final j in asJsonList(json['data'])) ResolvedPrice.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }
}
