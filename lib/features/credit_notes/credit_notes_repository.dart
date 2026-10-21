import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import 'credit_note_model.dart';

final creditNotesRepositoryProvider = Provider<CreditNotesRepository>(
  (ref) => CreditNotesRepository(ref.watch(apiClientProvider)),
);

final creditNoteProvider = FutureProvider.autoDispose
    .family<CreditNote, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(revisionProvider(DataKind.creditNotes));
      return ref.watch(creditNotesRepositoryProvider).get(id);
    });

class CreditNotesRepository {
  CreditNotesRepository(this._api);

  final ApiClient _api;

  Future<Paged<CreditNote>> list({
    String? q,
    DocStatus? status,
    String? from,
    String? to,
    String? invoiceId,
    String? partyId,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/credit-notes',
    CreditNote.fromJson,
    query: {
      'q': q,
      'status': status?.name,
      'from': from,
      'to': to,
      'invoiceId': invoiceId,
      'partyId': partyId,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<CreditNote> get(String id) async =>
      CreditNote.fromJson(await _api.getJson('/credit-notes/$id'));

  Future<CreditNote> preview(CreditNoteDraft draft) async =>
      CreditNote.fromJson(
        await _api.postJson('/credit-notes/preview', body: draft.toJson()),
      );

  Future<CreditNote> create(CreditNoteDraft draft) async => CreditNote.fromJson(
    await _api.postJson('/credit-notes', body: draft.toJson()),
  );

  Future<CreditNote> cancel(String id, String reason) async =>
      CreditNote.fromJson(
        await _api.postJson(
          '/credit-notes/$id/cancel',
          body: {'reason': reason},
        ),
      );
}
