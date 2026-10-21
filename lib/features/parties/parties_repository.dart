import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../accounts/account_model.dart';
import '../auth/session.dart';
import 'party_model.dart';

final partiesRepositoryProvider = Provider<PartiesRepository>(
  (ref) => PartiesRepository(ref.watch(apiClientProvider)),
);

final partyProvider = FutureProvider.autoDispose.family<Party, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.parties));
  return ref.watch(partiesRepositoryProvider).get(id);
});

class PartiesRepository {
  PartiesRepository(this._api);

  final ApiClient _api;

  /// [type] is `customer` or `vendor` (server-side filter).
  Future<Paged<Party>> list({
    String? q,
    PartyType? type,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/parties',
    Party.fromJson,
    query: {'q': q, 'type': type?.name, 'offset': offset, 'limit': limit},
  );

  Future<Party> get(String id) async =>
      Party.fromJson(await _api.getJson('/parties/$id'));

  /// The party's receivable / payable ledger (`from`/`to` default to the
  /// financial year to date).
  Future<Ledger> statement(String id, {String? from, String? to}) async =>
      Ledger.fromJson(
        await _api.getJson(
          '/parties/$id/statement',
          query: {'from': from, 'to': to},
        ),
      );

  /// [body] is a create body as produced by [Party.toInputJson].
  Future<Party> create(Json body) async =>
      Party.fromJson(await _api.postJson('/parties', body: withoutNulls(body)));

  /// Sends only the fields that changed from [original].
  Future<Party> update(Party original, Json body) async {
    final changes = changedFields(original.toInputJson(), body);
    if (changes.isEmpty) return original;
    return Party.fromJson(
      await _api.patchJson('/parties/${original.id}', body: changes),
    );
  }
}
