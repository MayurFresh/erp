import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'transfer_model.dart';

final transfersRepositoryProvider = Provider<TransfersRepository>(
  (ref) => TransfersRepository(ref.watch(apiClientProvider)),
);

final transferProvider = FutureProvider.autoDispose.family<Transfer, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.transfers));
  return ref.watch(transfersRepositoryProvider).get(id);
});

class TransfersRepository {
  TransfersRepository(this._api);

  final ApiClient _api;

  /// [locationId] matches either side.
  Future<Paged<Transfer>> list({
    String? q,
    TransferStatus? status,
    String? locationId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/transfers',
    Transfer.fromJson,
    query: {
      'q': q,
      'status': status?.value,
      'locationId': locationId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Transfer> get(String id) async =>
      Transfer.fromJson(await _api.getJson('/transfers/$id'));

  Future<Transfer> create(TransferDraft draft) async => Transfer.fromJson(
    await _api.postJson('/transfers', body: draft.toJson()),
  );

  Future<Transfer> receive(String id) async =>
      Transfer.fromJson(await _api.postJson('/transfers/$id/receive'));

  Future<Transfer> cancel(String id, String reason) async => Transfer.fromJson(
    await _api.postJson('/transfers/$id/cancel', body: {'reason': reason}),
  );
}
