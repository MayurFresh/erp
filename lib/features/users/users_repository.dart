import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../auth/session.dart';
import 'user_models.dart';

final usersRepositoryProvider = Provider<UsersRepository>(
  (ref) => UsersRepository(ref.watch(apiClientProvider)),
);

final rolesProvider = FutureProvider.autoDispose<List<Role>>((ref) async {
  ref.watch(activeCompanyIdProvider);
  return (await ref.watch(usersRepositoryProvider).roles()).data;
});

class UsersRepository {
  UsersRepository(this._api);

  final ApiClient _api;

  Future<Paged<UserRow>> users({String? q, int offset = 0, int limit = 50}) =>
      _api.getPage(
        '/users',
        UserRow.fromJson,
        query: {'q': q, 'offset': offset, 'limit': limit},
      );

  Future<Paged<Role>> roles() => _api.getPage('/roles', Role.fromJson);

  Future<UserRow> create(NewUser user) async =>
      UserRow.fromJson(await _api.postJson('/users', body: user.toJson()));
}
