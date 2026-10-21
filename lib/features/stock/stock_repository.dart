import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import 'stock_models.dart';

final stockRepositoryProvider = Provider<StockRepository>(
  (ref) => StockRepository(ref.watch(apiClientProvider)),
);

class StockRepository {
  StockRepository(this._api);

  final ApiClient _api;

  Future<Paged<StockBalance>> balances({
    String? locationId,
    String? q,
    bool lowOnly = false,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/stock',
    StockBalance.fromJson,
    query: {
      'locationId': locationId,
      'q': q,
      if (lowOnly) 'lowOnly': true,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<StockMove> adjust(StockAdjustment adjustment) async =>
      StockMove.fromJson(
        await _api.postJson('/stock/adjustments', body: adjustment.toJson()),
      );

  Future<Paged<StockMove>> moves({
    String? itemId,
    String? locationId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/stock/moves',
    StockMove.fromJson,
    query: {
      'itemId': itemId,
      'locationId': locationId,
      'offset': offset,
      'limit': limit,
    },
  );
}
