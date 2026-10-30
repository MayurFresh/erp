import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'settings_models.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(apiClientProvider)),
);

final settingsCompanyProvider = FutureProvider.autoDispose<Company>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.company));
  return ref.watch(settingsRepositoryProvider).company();
});

final permissionDefsProvider = FutureProvider.autoDispose<List<PermissionDef>>((
  ref,
) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(settingsRepositoryProvider).permissions();
});

/// Roles, built-in first. Invalidate after a role is saved.
final adminRolesProvider = FutureProvider.autoDispose<List<Role>>((ref) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.users));
  return ref.watch(settingsRepositoryProvider).roles();
});

/// One user of the active company (the contract has no `GET /users/:id`,
/// so the list is searched).
final adminUserProvider = FutureProvider.autoDispose.family<UserRow, String>((
  ref,
  id,
) {
  ref.watch(activeCompanyIdProvider);
  ref.watch(revisionProvider(DataKind.users));
  return ref.watch(settingsRepositoryProvider).user(id);
});

class SettingsRepository {
  SettingsRepository(this._api);

  final ApiClient _api;

  Future<Company> company() async =>
      Company.fromJson(await _api.getJson('/company'));

  /// [changes] from [companyPatch]; an empty body returns the profile.
  Future<Company> updateCompany(Json changes) async =>
      Company.fromJson(await _api.patchJson('/company', body: changes));

  Future<List<PermissionDef>> permissions() async {
    final body = await _api.get('/permissions');
    // A bare array per the contract; tolerate `{data: [...]}` too.
    final list = body is List ? body : asJson(body)['data'];
    return asJsonList(list).map(PermissionDef.fromJson).toList();
  }

  Future<List<Role>> roles() async =>
      (await _api.getPage('/roles', Role.fromJson, query: {'limit': 200})).data;

  Future<Role> createRole(RoleInput input) async =>
      Role.fromJson(await _api.postJson('/roles', body: input.toCreateJson()));

  Future<Role> updateRole(Role original, RoleInput input) async {
    final changes = input.toPatchJson(original);
    if (changes.isEmpty) return original;
    return Role.fromJson(
      await _api.patchJson('/roles/${original.id}', body: changes),
    );
  }

  /// Pages through `GET /users` until [id] is found.
  Future<UserRow> user(String id) async {
    var offset = 0;
    for (var guard = 0; guard < 50; guard++) {
      final page = await _api.getPage(
        '/users',
        UserRow.fromJson,
        query: {'limit': 200, 'offset': offset},
      );
      for (final u in page.data) {
        if (u.id == id) return u;
      }
      offset += page.data.length;
      if (page.data.isEmpty || offset >= page.total) break;
    }
    throw const UserNotFound();
  }

  Future<UserRow> updateUser(String id, Json changes) async =>
      UserRow.fromJson(await _api.patchJson('/users/$id', body: changes));

  /// Sets a new password and ends that user's sessions.
  Future<void> resetPassword(String id, String password) =>
      _api.post('/users/$id/password', body: {'password': password});

  Future<void> changeMyPassword(String current, String next) => _api.post(
    '/me/password',
    body: {'currentPassword': current, 'newPassword': next},
  );
}

class UserNotFound implements Exception {
  const UserNotFound();

  @override
  String toString() => 'This user is not in the active company.';
}
