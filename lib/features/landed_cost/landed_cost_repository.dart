import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'landed_cost_models.dart';

final landedCostRepositoryProvider = Provider<LandedCostRepository>(
  (ref) => LandedCostRepository(ref.watch(apiClientProvider)),
);

final landedCostProvider = FutureProvider.autoDispose
    .family<LandedCost, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watchRevisions(const [DataKind.purchases, DataKind.stock]);
      return ref.watch(landedCostRepositoryProvider).get(id);
    });

final landedCostReportProvider = FutureProvider.autoDispose<Json>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watchRevisions(const [DataKind.purchases, DataKind.stock]);
  return ref.watch(landedCostRepositoryProvider).report();
});

class LandedCostRepository {
  LandedCostRepository(this._api);

  final ApiClient _api;

  Future<Paged<LandedCost>> list({
    String? q,
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/landed-costs',
    LandedCost.fromJson,
    query: {'q': q, 'status': status, 'offset': offset, 'limit': limit},
  );

  Future<LandedCost> get(String id) async =>
      LandedCost.fromJson(await _api.getJson('/landed-costs/$id'));

  Future<LandedCost> preview(Json body) async => LandedCost.fromJson(
    await _api.postJson('/landed-costs/preview', body: body),
  );

  Future<LandedCost> create(Json body) async =>
      LandedCost.fromJson(await _api.postJson('/landed-costs', body: body));

  Future<LandedCost> cancel(String id, String reason) async =>
      LandedCost.fromJson(
        await _api.postJson('/landed-costs/$id/cancel', body: {'reason': reason}),
      );

  Future<Json> report({String? from, String? to}) =>
      _api.getJson('/landed-costs/report', query: {'from': from, 'to': to});

  /// Recent bills or goods receipts to pick from.
  Future<List<Json>> documents(String type, String q) async {
    final path = type == 'grn' ? '/goods-receipts' : '/purchases';
    final page = await _api.getJson(
      path,
      query: {'q': q, 'limit': 30, 'status': 'posted'},
    );
    return asJsonList(page['data']);
  }

  Future<List<Json>> accounts() async {
    final page = await _api.getJson('/accounts', query: {'limit': 200});
    return asJsonList(page['data']);
  }
}
