import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'fa_models.dart';

/// Bumped after a fixed-asset write so lists and details reload.
final faRevisionProvider = NotifierProvider<FaRevision, int>(FaRevision.new);

class FaRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final fixedAssetRepositoryProvider = Provider<FixedAssetRepository>(
  (ref) => FixedAssetRepository(ref.watch(apiClientProvider)),
);

extension _Watch on Ref {
  void base() {
    watch(activeCompanyIdProvider);
    watch(faRevisionProvider);
  }
}

final itBlocksProvider = FutureProvider.autoDispose<List<ItBlock>>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(fixedAssetRepositoryProvider).blocks();
});

final fixedAssetProvider = FutureProvider.autoDispose
    .family<FixedAsset, String>((ref, id) {
      ref.base();
      return ref.watch(fixedAssetRepositoryProvider).asset(id);
    });

final depRunsProvider = FutureProvider.autoDispose.family<List<DepRun>, String>(
  (ref, fy) {
    ref.base();
    return ref.watch(fixedAssetRepositoryProvider).runs(fy);
  },
);

final itScheduleProvider = FutureProvider.autoDispose
    .family<ItSchedule, String>((ref, fy) {
      ref.base();
      return ref.watch(fixedAssetRepositoryProvider).itSchedule(fy);
    });

class FixedAssetRepository {
  FixedAssetRepository(this._api);

  final ApiClient _api;

  Future<List<ItBlock>> blocks() async => asJsonList(
    (await _api.getJson('/fixed-assets/blocks'))['data'],
  ).map(ItBlock.fromJson).toList();

  Future<AssetPage> list({
    String? status,
    String? blockCode,
    String? q,
    int offset = 0,
    int limit = 50,
  }) async {
    final j = await _api.getJson(
      '/fixed-assets',
      query: {
        if (status != null && status.isNotEmpty) 'status': status,
        if (blockCode != null && blockCode.isNotEmpty) 'blockCode': blockCode,
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        'offset': offset,
        'limit': limit,
      },
    );
    return AssetPage(
      data: asJsonList(j['data']).map(FixedAsset.fromJson).toList(),
      total: asInt(j['total']),
      totals: AssetTotals.fromJson(asJson(j['totals'] ?? const {})),
    );
  }

  Future<FixedAsset> asset(String id) async =>
      FixedAsset.fromJson(await _api.getJson('/fixed-assets/$id'));

  Future<FixedAsset> create(Json body) async =>
      FixedAsset.fromJson(await _api.postJson('/fixed-assets', body: body));

  Future<FixedAsset> update(String id, Json body) async => FixedAsset.fromJson(
    await _api.patchJson('/fixed-assets/$id', body: body),
  );

  Future<FixedAsset> dispose(String id, Json body) async => FixedAsset.fromJson(
    await _api.postJson('/fixed-assets/$id/dispose', body: body),
  );

  /// `preview: true` returns the lines without posting.
  Future<DepRun> runDepreciation({
    required String toDate,
    List<String>? assetIds,
    bool preview = false,
  }) async => DepRun.fromJson(
    await _api.postJson(
      preview
          ? '/fixed-assets/depreciation-runs?preview=true'
          : '/fixed-assets/depreciation-runs',
      body: {
        'toDate': toDate,
        if (assetIds != null && assetIds.isNotEmpty) 'assetIds': assetIds,
      },
    ),
  );

  Future<List<DepRun>> runs(String fy) async => asJsonList(
    (await _api.getJson(
      '/fixed-assets/depreciation-runs',
      query: {'fy': fy},
    ))['data'],
  ).map(DepRun.fromJson).toList();

  Future<void> cancelRun(String id, String reason) => _api.postJson(
    '/fixed-assets/depreciation-runs/$id/cancel',
    body: {'reason': reason},
  );

  Future<ItSchedule> itSchedule(String fy) async => ItSchedule.fromJson(
    await _api.getJson('/fixed-assets/it-schedule', query: {'fy': fy}),
  );

  Future<void> setOpening(String fy, String blockCode, double openingWdv) =>
      _api.postJson(
        '/fixed-assets/it-openings',
        body: {'fy': fy, 'blockCode': blockCode, 'openingWdv': openingWdv},
      );
}
