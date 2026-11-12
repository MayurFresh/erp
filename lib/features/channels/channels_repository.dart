import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'channels_models.dart';

/// Bumped after a channel write so channel lists reload.
final channelsRevisionProvider = NotifierProvider<ChannelsRevision, int>(
  ChannelsRevision.new,
);

class ChannelsRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension ChannelsRevisionRef on WidgetRef {
  void bumpChannels() {
    read(channelsRevisionProvider.notifier).bump();
    read(revisionProvider(DataKind.stock).notifier).bump();
  }
}

final channelsRepositoryProvider = Provider<ChannelsRepository>(
  (ref) => ChannelsRepository(ref.watch(apiClientProvider)),
);

final channelsProvider = FutureProvider.autoDispose<List<Channel>>((ref) async {
  ref.watch(activeCompanyIdProvider);
  ref.watch(channelsRevisionProvider);
  return (await ref.watch(channelsRepositoryProvider).channels()).data;
});

final settlementProvider = FutureProvider.autoDispose
    .family<Settlement, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(channelsRevisionProvider);
      return ref.watch(channelsRepositoryProvider).settlement(id);
    });

final channelHealthProvider = FutureProvider.autoDispose
    .family<ChannelHealth, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(channelsRevisionProvider);
      return ref.watch(channelsRepositoryProvider).health(id);
    });

class ChannelsRepository {
  ChannelsRepository(this._api);

  final ApiClient _api;

  Future<Paged<Channel>> channels() =>
      _api.getPage('/channels', Channel.fromJson);

  Future<void> createChannel({
    required String provider,
    required String name,
    required String locationId,
    required bool pricesIncludeTax,
    required String orderStatus,
  }) => _api.post(
    '/channels',
    body: {
      'provider': provider,
      'name': name,
      'locationId': locationId,
      'pricesIncludeTax': pricesIncludeTax,
      'orderStatus': orderStatus,
    },
  );

  Future<void> updateChannel(String id, Json body) =>
      _api.patch('/channels/$id', body: body);

  Future<Paged<Listing>> listings(
    String id, {
    String? q,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/channels/$id/listings',
    Listing.fromJson,
    query: {
      'q': ?(q != null && q.isNotEmpty ? q : null),
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Paged<UnmappedSku>> unmapped(String id) =>
      _api.getPage('/channels/$id/unmapped', UnmappedSku.fromJson);

  /// Maps a channel SKU; returns how many waiting orders were created.
  Future<int> saveListing(
    String channelId, {
    String? listingId,
    required String channelSku,
    String? title,
    required List<({String itemId, double qty})> components,
  }) async {
    final body = {
      'channelSku': channelSku,
      if (title != null && title.isNotEmpty) 'title': title,
      'components': [
        for (final c in components) {'itemId': c.itemId, 'qty': c.qty},
      ],
    };
    final res = listingId == null
        ? await _api.postJson('/channels/$channelId/listings', body: body)
        : await _api.patchJson(
            '/channels/$channelId/listings/$listingId',
            body: body,
          );
    return asInt(res['ordersCreated']);
  }

  Future<void> deleteListing(String channelId, String listingId) =>
      _api.delete('/channels/$channelId/listings/$listingId');

  Future<InboxPage> inbox({
    String? connectionId,
    String? status,
    String? q,
    int offset = 0,
    int limit = 50,
  }) async {
    final j = await _api.getJson(
      '/channels/inbox',
      query: {
        'connectionId': ?connectionId,
        'status': ?status,
        'q': ?(q != null && q.isNotEmpty ? q : null),
        'offset': offset,
        'limit': limit,
      },
    );
    return InboxPage(
      asJsonList(j['data']).map(InboxOrder.fromJson).toList(),
      asInt(j['total']),
      {for (final e in asJson(j['counts']).entries) e.key: asInt(e.value)},
    );
  }

  Future<void> retry(String inboxId) =>
      _api.post('/channels/inbox/$inboxId/retry');

  Future<ImportPreview> previewOrders(String id, String csv) async =>
      ImportPreview.fromJson(
        await _api.postJson(
          '/channels/$id/orders/import',
          body: {'csv': csv, 'dryRun': true},
        ),
      );

  Future<ImportResult> importOrders(String id, String csv) async =>
      ImportResult.fromJson(
        await _api.postJson(
          '/channels/$id/orders/import',
          body: {'csv': csv, 'dryRun': false},
        ),
      );

  Future<Paged<Settlement>> settlements({
    String? status,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/channels/settlements',
    Settlement.fromJson,
    query: {'status': ?status, 'offset': offset, 'limit': limit},
  );

  Future<Settlement> settlement(String id) async =>
      Settlement.fromJson(await _api.getJson('/channels/settlements/$id'));

  Future<SettlementPreview> previewSettlements(String id, String csv) async =>
      SettlementPreview.fromJson(
        await _api.postJson(
          '/channels/$id/settlements/import',
          body: {'csv': csv, 'dryRun': true},
        ),
      );

  Future<SettlementPreview> importSettlements(String id, String csv) async =>
      SettlementPreview.fromJson(
        await _api.postJson(
          '/channels/$id/settlements/import',
          body: {'csv': csv, 'dryRun': false},
        ),
      );

  Future<Settlement> post(String id) async => Settlement.fromJson(
    await _api.postJson('/channels/settlements/$id/post', body: {}),
  );

  Future<ChannelHealth> health(String id) async =>
      ChannelHealth.fromJson(await _api.getJson('/channels/$id/health'));

  /// Write-only: the server never returns the values.
  Future<void> saveCredentials(String id, Map<String, String> values) =>
      _api.patch('/channels/$id/credentials', body: {'values': values});

  Future<void> removeCredentials(String id) =>
      _api.delete('/channels/$id/credentials');

  /// Returns `(ok, message)`.
  Future<(bool, String)> check(String id) async {
    final j = await _api.postJson('/channels/$id/check', body: {});
    return (asBool(j['ok']), asString(j['message']));
  }

  Future<void> sync(String id, String what) =>
      _api.post('/channels/$id/sync', body: {'what': what});

  Future<String> exportTally(String from, String to) =>
      _api.getText('/export/tally', query: {'from': from, 'to': to});
}
