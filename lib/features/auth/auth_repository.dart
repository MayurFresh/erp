import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import 'auth_models.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);

class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  /// Signs up and stores the returned tokens in the client.
  Future<AuthResult> signup(SignupRequest request) async {
    final result = AuthResult.fromJson(
      await _api.postJson('/auth/signup', body: request.toJson()),
    );
    await _api.setTokens(result.tokens);
    return result;
  }

  /// Logs in and stores the returned tokens in the client.
  Future<AuthResult> login(String email, String password) async {
    final result = AuthResult.fromJson(
      await _api.postJson(
        '/auth/login',
        body: {'email': email, 'password': password},
      ),
    );
    await _api.setTokens(result.tokens);
    return result;
  }

  /// Rotates the tokens using the stored refresh token.
  Future<AuthResult> refresh() async =>
      AuthResult.fromJson(await _api.refreshTokens());

  Future<Me> me() async => Me.fromJson(await _api.getJson('/me'));

  /// Revokes the refresh token (best effort) and clears local tokens.
  Future<void> logout() async {
    final token = _api.refreshToken;
    try {
      if (token != null) {
        await _api.post('/auth/logout', body: {'refreshToken': token});
      }
    } catch (_) {
      // Logging out locally is what matters.
    } finally {
      await _api.clearSession();
    }
  }
}
