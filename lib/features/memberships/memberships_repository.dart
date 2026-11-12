import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'memberships_models.dart';

/// Bumped after any membership write so the open lists reload.
final membershipRevisionProvider = NotifierProvider<MembershipRevision, int>(
  MembershipRevision.new,
);

class MembershipRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

extension MembershipBump on WidgetRef {
  void bumpMemberships({bool money = false}) {
    read(membershipRevisionProvider.notifier).bump();
    if (money) {
      bump(const [DataKind.invoices, DataKind.payments, DataKind.parties]);
    }
  }
}

final membershipsRepositoryProvider = Provider<MembershipsRepository>(
  (ref) => MembershipsRepository(ref.watch(apiClientProvider)),
);

final memSummaryProvider = FutureProvider.autoDispose<MemSummary>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(membershipRevisionProvider);
  return ref.watch(membershipsRepositoryProvider).summary();
});

final memPlansProvider = FutureProvider.autoDispose<List<MemPlan>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(membershipRevisionProvider);
  return ref.watch(membershipsRepositoryProvider).plans();
});

final memMembersProvider = FutureProvider.autoDispose
    .family<List<MemberBrief>, ({String q, String? status})>((ref, key) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(membershipRevisionProvider);
      return ref
          .watch(membershipsRepositoryProvider)
          .members(q: key.q, status: key.status);
    });

final memberFileProvider = FutureProvider.autoDispose
    .family<MemberFile, String>((ref, id) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(membershipRevisionProvider);
      ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
      return ref.watch(membershipsRepositoryProvider).member(id);
    });

final memDuesProvider = FutureProvider.autoDispose<List<DueRow>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(membershipRevisionProvider);
  ref.watchRevisions(const [DataKind.invoices, DataKind.payments]);
  return ref.watch(membershipsRepositoryProvider).dues();
});

class MembershipsRepository {
  MembershipsRepository(this._api);

  final ApiClient _api;

  Future<MemSummary> summary() async =>
      MemSummary.fromJson(await _api.getJson('/memberships/summary'));

  Future<List<MemPlan>> plans() async => asJsonList(
    (await _api.getJson('/memberships/plans'))['data'],
  ).map(MemPlan.fromJson).toList();

  Future<MemPlan> savePlan(String? id, Json body) async => MemPlan.fromJson(
    id == null
        ? await _api.postJson('/memberships/plans', body: body)
        : await _api.patchJson('/memberships/plans/$id', body: body),
  );

  Future<List<MemberBrief>> members({String q = '', String? status}) async =>
      (await _api.getPage(
        '/memberships/members',
        MemberBrief.fromJson,
        query: {if (q.isNotEmpty) 'q': q, 'status': ?status, 'limit': 200},
      )).data;

  Future<MemberFile> member(String id) async =>
      MemberFile.fromJson(await _api.getJson('/memberships/members/$id'));

  Future<Json> createMember(Json body) =>
      _api.postJson('/memberships/members', body: body);

  Future<Json> updateMember(String id, Json body) =>
      _api.patchJson('/memberships/members/$id', body: body);

  /// Uploads a photo through the files module and returns the file id.
  Future<String> uploadPhoto(Uint8List bytes, String name, String mime) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: name,
        contentType: DioMediaType.parse(mime),
      ),
    });
    return asString(asJson(await _api.post('/files', body: form))['id']);
  }

  Future<Uint8List> photoBytes(String fileId) =>
      _api.getBytes('/files/$fileId');

  Future<Json> renew(String id, Json body) =>
      _api.postJson('/memberships/members/$id/renew', body: body);

  Future<Json> freeze(String subId) =>
      _api.postJson('/memberships/subscriptions/$subId/freeze', body: {});

  Future<Json> unfreeze(String subId) =>
      _api.postJson('/memberships/subscriptions/$subId/unfreeze', body: {});

  Future<List<DueRow>> dues() async => asJsonList(
    (await _api.getJson('/memberships/dues'))['data'],
  ).map(DueRow.fromJson).toList();

  Future<Json> collect(String id, Json body) =>
      _api.postJson('/memberships/members/$id/collect', body: body);

  Future<RunPreview> preview(String kind, String period) async =>
      RunPreview.fromJson(
        await _api.getJson(
          '/memberships/bills/preview',
          query: {'kind': kind, 'period': period},
        ),
      );

  Future<Json> generate(String kind, String period) => _api.postJson(
    '/memberships/bills/generate',
    body: {'kind': kind, 'period': period},
  );

  /// Throws an `ApiException` whose message says why the member is refused.
  Future<CheckinResult> checkin({String? memberNo, String? phone}) async =>
      CheckinResult.fromJson(
        await _api.postJson(
          '/memberships/checkin',
          body: {'memberNo': ?memberNo, 'phone': ?phone},
        ),
      );
}
