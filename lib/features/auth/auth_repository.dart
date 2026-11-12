import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json.dart';
import '../../core/providers.dart';
import '../platform/platform_models.dart' show SsoDiscovery;
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

  /// Password step. Returns an [MfaChallenge] when 2FA is on (no tokens yet).
  Future<LoginOutcome> signIn(String email, String password) async {
    final json = await _api.postJson(
      '/auth/login',
      body: {'email': email, 'password': password},
    );
    if (asBool(json['mfaRequired'])) {
      return MfaChallenge(
        mfaToken: asString(json['mfaToken']),
        methods: asStringList(json['methods']),
      );
    }
    final result = AuthResult.fromJson(json);
    await _api.setTokens(result.tokens);
    return LoggedIn(result);
  }

  /// Second step: exactly one of [code] and [recoveryCode].
  Future<AuthResult> completeMfa(
    String mfaToken, {
    String? code,
    String? recoveryCode,
  }) async {
    final result = AuthResult.fromJson(
      await _api.postJson(
        '/auth/login/mfa',
        body: {
          'mfaToken': mfaToken,
          'code': ?code,
          'recoveryCode': ?recoveryCode,
        },
      ),
    );
    await _api.setTokens(result.tokens);
    return result;
  }

  Future<void> forgotPassword(String email) =>
      _api.post('/auth/password/forgot', body: {'email': email});

  Future<void> resetPassword(String token, String newPassword) => _api.post(
    '/auth/password/reset',
    body: {'token': token, 'newPassword': newPassword},
  );

  Future<SsoDiscovery> discoverSso(String email) async => SsoDiscovery.fromJson(
    await _api.getJson('/auth/sso/discover', query: {'email': email}),
  );

  /// Browser URL that starts the SSO round trip.
  String ssoStartUrl(String providerId, String returnTo) => Uri.parse(
    '${_api.baseUrl}/auth/sso/$providerId/start',
  ).replace(queryParameters: {'returnTo': returnTo}).toString();

  Future<AuthResult> redeemSso(String ticket) async {
    final result = AuthResult.fromJson(
      await _api.postJson('/auth/sso/redeem', body: {'ticket': ticket}),
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
