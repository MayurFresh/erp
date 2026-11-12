import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'legal_models.dart';

/// Bumped after any legal write; every legal provider watches it.
final legalRevisionProvider = NotifierProvider<LegalRevision, int>(
  LegalRevision.new,
);

class LegalRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension LegalBump on WidgetRef {
  /// Reload legal data; [money] also reloads invoices, receipts and parties.
  void bumpLegal({bool money = false}) {
    read(legalRevisionProvider.notifier).bump();
    if (money) {
      bump(const [DataKind.invoices, DataKind.payments, DataKind.parties]);
    }
  }
}

final legalRepositoryProvider = Provider<LegalRepository>(
  (ref) => LegalRepository(ref.watch(apiClientProvider)),
);

void _watch(Ref ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(legalRevisionProvider);
}

final legalHomeProvider = FutureProvider.autoDispose<LegalHome>((ref) {
  _watch(ref);
  return ref.watch(legalRepositoryProvider).home();
});

final legalMatterProvider = FutureProvider.autoDispose.family<Matter, String>((
  ref,
  id,
) {
  _watch(ref);
  return ref.watch(legalRepositoryProvider).matter(id);
});

final legalEntriesProvider = FutureProvider.autoDispose
    .family<List<Entry>, String>((ref, matterId) {
      _watch(ref);
      ref.watchRevisions(const [DataKind.invoices]);
      return ref.watch(legalRepositoryProvider).entries(matterId);
    });

final legalTasksProvider = FutureProvider.autoDispose
    .family<List<LegalTask>, String>((ref, matterId) {
      _watch(ref);
      return ref.watch(legalRepositoryProvider).tasks(matterId);
    });

final legalBillsProvider = FutureProvider.autoDispose.family<Bills, String>((
  ref,
  matterId,
) {
  _watch(ref);
  ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
  return ref.watch(legalRepositoryProvider).bills(matterId);
});

final legalDocsProvider = FutureProvider.autoDispose
    .family<List<MatterDoc>, String>((ref, matterId) {
      _watch(ref);
      return ref.watch(legalRepositoryProvider).documents(matterId);
    });

final legalStaffProvider = FutureProvider.autoDispose<List<Person>>((ref) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(legalRepositoryProvider).staff();
});

class LegalRepository {
  LegalRepository(this._api);

  final ApiClient _api;

  Future<LegalHome> home() async =>
      LegalHome.fromJson(await _api.getJson('/legal/home'));

  /// Hourly rate card: `(userId, name, hourlyRate)`; the rate is null until set.
  Future<List<(String, String, double?)>> rates() async => [
    for (final r in asJsonList((await _api.getJson('/legal/rates'))['data']))
      (
        asString(r['userId']),
        asString(r['name']),
        r['hourlyRate'] == null ? null : asDouble(r['hourlyRate']),
      ),
  ];

  Future<void> setRate(String userId, double hourlyRate) =>
      _api.patchJson('/legal/rates/$userId', body: {'hourlyRate': hourlyRate});

  Future<List<Person>> staff() async =>
      (await _api.getPage('/legal/staff', Person.fromJson)).data;

  Future<Paged<Matter>> matters({
    String? q,
    String? status,
    String? advocateId,
    String? court,
    int offset = 0,
    int limit = 50,
  }) => _api.getPage(
    '/legal/matters',
    Matter.fromJson,
    query: {
      'q': q,
      'status': status,
      'advocateId': advocateId,
      'court': court,
      'offset': offset,
      'limit': limit,
    },
  );

  Future<Matter> matter(String id) async =>
      Matter.fromJson(await _api.getJson('/legal/matters/$id'));

  Future<Matter> saveMatter(String? id, Json body) async => Matter.fromJson(
    id == null
        ? await _api.postJson('/legal/matters', body: body)
        : await _api.patchJson('/legal/matters/$id', body: body),
  );

  Future<Hearing> addHearing(String matterId, Json body) async =>
      Hearing.fromJson(
        await _api.postJson('/legal/matters/$matterId/hearings', body: body),
      );

  /// Returns the warning text when no next date was set, else null.
  Future<String?> recordOutcome(String hearingId, Json body) async {
    final j = await _api.postJson(
      '/legal/hearings/$hearingId/outcome',
      body: body,
    );
    return asStringOrNull(j['warning']);
  }

  Future<List<LegalTask>> tasks(String matterId) async => (await _api.getPage(
    '/legal/tasks',
    LegalTask.fromJson,
    query: {'matterId': matterId},
  )).data;

  Future<void> addTask(String matterId, Json body) =>
      _api.postJson('/legal/matters/$matterId/tasks', body: body);

  Future<void> patchTask(String id, Json body) =>
      _api.patchJson('/legal/tasks/$id', body: body);

  Future<List<Entry>> entries(String matterId) async => (await _api.getPage(
    '/legal/entries',
    Entry.fromJson,
    query: {'matterId': matterId},
  )).data;

  Future<Entry> addEntry(String matterId, Json body) async => Entry.fromJson(
    await _api.postJson('/legal/matters/$matterId/entries', body: body),
  );

  Future<void> deleteEntry(String id) => _api.delete('/legal/entries/$id');

  Future<Bills> bills(String matterId) async =>
      Bills.fromJson(await _api.getJson('/legal/matters/$matterId/bills'));

  /// Creates the fee bill; returns the invoice number.
  Future<String> bill(String matterId, Json body) async {
    final j = await _api.postJson('/legal/matters/$matterId/bill', body: body);
    return asString(asJson(j['invoice'])['number']);
  }

  Future<void> receipt(String matterId, Json body) =>
      _api.postJson('/legal/matters/$matterId/receipts', body: body);

  Future<List<MatterDoc>> documents(String matterId) async => asJsonList(
    (await _api.getJson('/legal/matters/$matterId/documents'))['data'],
  ).map(MatterDoc.fromJson).toList();

  Future<void> attach(
    String matterId,
    Uint8List bytes,
    String name,
    String mime,
  ) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: name,
        contentType: DioMediaType.parse(mime),
      ),
    });
    final file = asJson(await _api.post('/files', body: form));
    await _api.postJson(
      '/legal/matters/$matterId/documents',
      body: {'fileId': file['id'], 'label': name},
    );
  }

  Future<void> removeDocument(String id) => _api.delete('/legal/documents/$id');

  /// Cash and bank accounts for receipts: `(id, name)`.
  Future<List<(String, String)>> cashAccounts() async {
    final page = await _api.getPage('/accounts', (j) => j);
    return [
      for (final a in page.data)
        if (['cash', 'bank'].contains(asString(a['subtype'])) &&
            asBool(a['isActive'], true))
          (asString(a['id']), asString(a['name'])),
    ];
  }
}
