import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import '../construction/data/photo_source.dart';
import 'claims_models.dart';

/// Bumped after a claim or loan write so lists and details reload.
final claimsRevisionProvider = NotifierProvider<ClaimsRevision, int>(
  ClaimsRevision.new,
);

class ClaimsRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final claimsRepositoryProvider = Provider<ClaimsRepository>(
  (ref) => ClaimsRepository(ref.watch(apiClientProvider)),
);

T _watchBase<T>(Ref ref, T Function(ClaimsRepository r) f) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(claimsRevisionProvider);
  return f(ref.watch(claimsRepositoryProvider));
}

final claimCategoriesProvider =
    FutureProvider.autoDispose<List<ClaimCategory>>(
      (ref) => _watchBase(ref, (r) => r.categories()),
    );

/// `mine: true` lists the signed-in person's claims; otherwise by [status].
final claimsListProvider = FutureProvider.autoDispose
    .family<List<Claim>, ({bool mine, String? status})>(
      (ref, a) => _watchBase(ref, (r) => r.claims(mine: a.mine, status: a.status)),
    );

final claimProvider = FutureProvider.autoDispose.family<Claim, String>(
  (ref, id) => _watchBase(ref, (r) => r.claim(id)),
);

final claimsSummaryProvider = FutureProvider.autoDispose
    .family<List<SummaryRow>, String>(
      (ref, by) => _watchBase(ref, (r) => r.summary(by)),
    );

final loansListProvider = FutureProvider.autoDispose<List<Loan>>(
  (ref) => _watchBase(ref, (r) => r.loans()),
);

final loanProvider = FutureProvider.autoDispose.family<Loan, String>(
  (ref, id) => _watchBase(ref, (r) => r.loan(id)),
);

class ClaimsRepository {
  ClaimsRepository(this._api);

  final ApiClient _api;

  Future<List<ClaimCategory>> categories() async =>
      asJsonList((await _api.getJson('/claims/categories'))['data'])
          .map(ClaimCategory.fromJson)
          .toList();

  Future<void> saveCategory(String? id, Json body) => id == null
      ? _api.post('/claims/categories', body: body)
      : _api.patch('/claims/categories/$id', body: body);

  Future<List<Claim>> claims({bool mine = false, String? status}) async =>
      (await _api.getPage(
        '/claims',
        Claim.fromJson,
        query: {
          if (mine) 'mine': 'true',
          'status': status,
          'limit': 100,
        },
      )).data;

  Future<Claim> claim(String id) async =>
      Claim.fromJson(await _api.getJson('/claims/$id'));

  Future<Claim> saveClaim(String? id, Json body) async => Claim.fromJson(
    id == null
        ? await _api.postJson('/claims', body: body)
        : await _api.patchJson('/claims/$id', body: body),
  );

  Future<void> deleteClaim(String id) => _api.delete('/claims/$id');
  Future<void> submit(String id) => _api.post('/claims/$id/submit');
  Future<void> approve(String id, Json body) =>
      _api.post('/claims/$id/approve', body: body);
  Future<void> reject(String id, String note) =>
      _api.post('/claims/$id/reject', body: {'note': note});
  Future<void> settle(String id, Json body) =>
      _api.post('/claims/$id/settle', body: body);

  Future<List<SummaryRow>> summary(String groupBy) async =>
      asJsonList((await _api.getJson('/claims/summary', query: {'groupBy': groupBy}))['data'])
          .map(SummaryRow.fromJson)
          .toList();

  /// `POST /files` (multipart, field `file`); returns the file id.
  Future<String> uploadReceipt(PickedPhoto photo) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        photo.bytes,
        filename: photo.name,
        contentType: DioMediaType.parse(photo.mimeType),
      ),
    });
    return asString(asJson(await _api.post('/files', body: form))['id']);
  }

  Future<Uint8List> fileBytes(String id) => _api.getBytes('/files/$id');

  Future<List<Loan>> loans() async =>
      (await _api.getPage('/loans', Loan.fromJson)).data;

  Future<Loan> loan(String id) async =>
      Loan.fromJson(await _api.getJson('/loans/$id'));

  Future<Loan> createLoan(Json body) async =>
      Loan.fromJson(await _api.postJson('/loans', body: body));

  Future<void> loanAction(String id, String action, [Json? body]) =>
      _api.post('/loans/$id/$action', body: body);

  /// Employees for the loan form.
  Future<List<(String, String)>> employees() async => asJsonList(
    (await _api.getJson('/employees', query: {'status': 'active', 'limit': 200}))['data'],
  ).map((e) => (asString(e['id']), '${asString(e['name'])} (${asString(e['code'])})')).toList();

  Future<List<(String, String)>> cashAccounts() async => asJsonList(
    (await _api.getJson('/accounts'))['data'],
  ).where((a) => ['cash', 'bank'].contains(a['subtype'])).map((a) => (asString(a['id']), asString(a['name']))).toList();
}
