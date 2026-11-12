import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../locations/locations_repository.dart';
import 'wh_models.dart';

/// Bumped after every warehouse write so lists reload.
final whRevisionProvider = NotifierProvider<WhRevision, int>(WhRevision.new);

class WhRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final whRepositoryProvider = Provider<WhRepository>(
  (ref) => WhRepository(ref.watch(apiClientProvider)),
);

/// Location chosen on a warehouse screen; null means the first active one.
final whLocationChoiceProvider = NotifierProvider<WhLocationChoice, String?>(
  WhLocationChoice.new,
);

class WhLocationChoice extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;
}

/// The location in use: the choice if it is still active, else the first one.
final whLocationIdProvider = Provider<String?>((ref) {
  final locs = (ref.watch(locationsLookupProvider).value ?? const [])
      .where((l) => l.isActive)
      .toList();
  final choice = ref.watch(whLocationChoiceProvider);
  if (locs.any((l) => l.id == choice)) return choice;
  if (locs.isEmpty) return null;
  // Open on a location that has bins, so a company whose bins sit in a store
  // room does not land on an empty head office.
  final binned = (ref.watch(whBinsProvider('')).value ?? const <WhBin>[])
      .map((b) => b.locationId)
      .toSet();
  return locs.firstWhere((l) => binned.contains(l.id), orElse: () => locs.first).id;
});

FutureProvider<T> _watched<T>(Future<T> Function(WhRepository r) load) =>
    FutureProvider<T>((ref) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(whRevisionProvider);
      return load(ref.watch(whRepositoryProvider));
    });

final whSettingsProvider = _watched((r) => r.settings());

/// Bins; the key is a location id or '' for all.
final whBinsProvider = FutureProvider.family<List<WhBin>, String>((ref, loc) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(whRevisionProvider);
  return ref.watch(whRepositoryProvider).bins(locationId: loc);
});

/// Stock at a location; the key is `locationId|itemId`.
final whStockProvider = FutureProvider.family<WhStock, String>((ref, key) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(whRevisionProvider);
  final p = key.split('|');
  return ref
      .watch(whRepositoryProvider)
      .stock(p[0], itemId: p.length > 1 ? p[1] : '');
});

/// Serials; the key is `locationId|status|q`.
final whSerialsProvider = FutureProvider.family<List<WhSerial>, String>((
  ref,
  key,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(whRevisionProvider);
  final p = key.split('|');
  return ref
      .watch(whRepositoryProvider)
      .serials(locationId: p[0], status: p[1], q: p[2]);
});

/// Expiry rows; the key is `locationId|days`.
final whExpiryProvider = FutureProvider.family<List<WhExpiryRow>, String>((
  ref,
  key,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(whRevisionProvider);
  final p = key.split('|');
  return ref
      .watch(whRepositoryProvider)
      .expiry(days: int.parse(p[1]), locationId: p[0]);
});

class WhRepository {
  WhRepository(this._api);

  final ApiClient _api;

  static const _b = '/warehouse';

  Future<WhSettings> settings() async =>
      WhSettings.fromJson(await _api.getJson('$_b/settings'));

  /// `PUT /settings` also answers PATCH, because the client has no PUT.
  Future<void> saveSettings(Json body) =>
      _api.patch('$_b/settings', body: body);

  Future<List<WhBin>> bins({String locationId = ''}) async =>
      (await _api.getPage(
        '$_b/bins',
        WhBin.fromJson,
        query: {
          if (locationId.isNotEmpty) 'locationId': locationId,
          'limit': 200,
        },
      )).data;

  Future<void> saveBin({String? id, required Json body}) => id == null
      ? _api.post('$_b/bins', body: body)
      : _api.patch('$_b/bins/$id', body: body);

  Future<WhStock> stock(String locationId, {String itemId = ''}) async =>
      WhStock.fromJson(
        await _api.getJson(
          '$_b/stock',
          query: {
            'locationId': locationId,
            if (itemId.isNotEmpty) 'itemId': itemId,
            'limit': 200,
          },
        ),
      );

  Future<WhFefo> fefo(String locationId, String itemId, {double? qty}) async =>
      WhFefo.fromJson(
        await _api.getJson(
          '$_b/fefo',
          query: {'locationId': locationId, 'itemId': itemId, 'qty': ?qty},
        ),
      );

  Future<List<WhSerial>> serials({
    String locationId = '',
    String status = '',
    String q = '',
  }) async => (await _api.getPage(
    '$_b/serials',
    WhSerial.fromJson,
    query: {
      if (locationId.isNotEmpty) 'locationId': locationId,
      if (status.isNotEmpty) 'status': status,
      if (q.isNotEmpty) 'q': q,
      'limit': 100,
    },
  )).data;

  Future<List<WhExpiryRow>> expiry({
    required int days,
    String locationId = '',
  }) async => (await _api.getPage(
    '$_b/expiry',
    WhExpiryRow.fromJson,
    query: {
      'days': days,
      if (locationId.isNotEmpty) 'locationId': locationId,
      'limit': 200,
    },
  )).data;

  Future<void> receive(Json body) => _api.post('$_b/receipts', body: body);

  Future<void> putaway(Json body) => _api.post('$_b/putaway', body: body);

  /// Records a pick and returns the id that names the pick list.
  Future<String> pick(Json body) async =>
      asString((await _api.postJson('$_b/picks', body: body))['refId']);

  /// Bills a pick list through the invoice service; returns the invoice number.
  Future<String> billPick(String refId, String partyId) async {
    final r = await _api.postJson(
      '$_b/picks/$refId/invoice',
      body: {'partyId': partyId},
    );
    return asString((r['invoice'] as Map?)?['number']);
  }

  Future<WhItemRule> itemRule(String itemId) async =>
      WhItemRule.fromJson(await _api.getJson('$_b/items/$itemId'));

  /// `PUT` also answers PATCH, because the client has no PUT.
  Future<void> saveItemRule(String itemId, Json body) =>
      _api.patch('$_b/items/$itemId', body: body);
}
