import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'count_models.dart';

final stockCountProvider = FutureProvider.autoDispose
    .family<StockCount, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      return ref.watch(stockCountsRepositoryProvider).get(id);
    });

final stockCountsRepositoryProvider = Provider<StockCountsRepository>(
  (ref) => StockCountsRepository(ref.watch(apiClientProvider)),
);

class StockCountsRepository {
  StockCountsRepository(this._api);

  final ApiClient _api;

  Future<Paged<StockCount>> list({
    String? status,
    String? locationId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/stock-counts',
    StockCount.fromJson,
    query: {
      'status': status,
      'locationId': locationId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<StockCount> get(String id) async =>
      StockCount.fromJson(await _api.getJson('/stock-counts/$id'));

  Future<StockCount> create({
    required String locationId,
    List<String>? itemIds,
    String? notes,
  }) async => StockCount.fromJson(
    await _api.postJson(
      '/stock-counts',
      body: withoutNulls({
        'locationId': locationId,
        if (itemIds != null && itemIds.isNotEmpty) 'itemIds': itemIds,
        'notes': notes,
      }),
    ),
  );

  /// One scan or manual entry. [scanId] makes a retry harmless.
  Future<ScanResult> scan(
    String id, {
    required String scanId,
    String? code,
    String? itemId,
    double qty = 1,
    String mode = 'add',
  }) async => ScanResult.fromJson(
    await _api.postJson(
      '/stock-counts/$id/scans',
      body: withoutNulls({
        'scanId': scanId,
        'code': code,
        'itemId': itemId,
        'qty': qty,
        'mode': mode,
      }),
    ),
  );

  Future<StockCount> post(String id, {bool zeroUncounted = false}) async =>
      StockCount.fromJson(
        await _api.postJson(
          '/stock-counts/$id/post',
          body: {'zeroUncounted': zeroUncounted},
        ),
      );

  Future<StockCount> cancel(String id, String reason) async =>
      StockCount.fromJson(
        await _api.postJson(
          '/stock-counts/$id/cancel',
          body: {'reason': reason},
        ),
      );
}
