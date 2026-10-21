import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'json.dart';

/// Tokens returned by `/auth/login`, `/auth/signup` and `/auth/refresh`.
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    this.expiresIn,
  });

  factory AuthTokens.fromJson(Json json) => AuthTokens(
    accessToken: asString(json['accessToken']),
    refreshToken: asString(json['refreshToken']),
    expiresIn: json['expiresIn'] == null ? null : asInt(json['expiresIn']),
  );

  final String accessToken;
  final String refreshToken;

  /// Access token lifetime in seconds.
  final int? expiresIn;
}

/// Persists what is needed to restore a session: the refresh token and the
/// active company. The access token is kept in memory only.
abstract class TokenStore {
  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);
  Future<String?> readCompanyId();
  Future<void> writeCompanyId(String? companyId);

  /// Removes everything (logout).
  Future<void> clear();
}

class InMemoryTokenStore implements TokenStore {
  String? _refreshToken;
  String? _companyId;

  @override
  Future<String?> readRefreshToken() async => _refreshToken;

  @override
  Future<void> writeRefreshToken(String token) async => _refreshToken = token;

  @override
  Future<String?> readCompanyId() async => _companyId;

  @override
  Future<void> writeCompanyId(String? companyId) async =>
      _companyId = companyId;

  @override
  Future<void> clear() async {
    _refreshToken = null;
    _companyId = null;
  }
}

/// Keychain / Keystore / WebCrypto-backed store. Storage failures are
/// swallowed: losing a persisted session only means signing in again.
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Avoids requiring the Keychain Sharing entitlement on macOS.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _refreshKey = 'progen.refreshToken';
  static const _companyKey = 'progen.companyId';

  final FlutterSecureStorage _storage;

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String? value) async {
    try {
      if (value == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
    } catch (_) {
      // Ignore: see class doc.
    }
  }

  @override
  Future<String?> readRefreshToken() => _read(_refreshKey);

  @override
  Future<void> writeRefreshToken(String token) => _write(_refreshKey, token);

  @override
  Future<String?> readCompanyId() => _read(_companyKey);

  @override
  Future<void> writeCompanyId(String? companyId) =>
      _write(_companyKey, companyId);

  @override
  Future<void> clear() async {
    await _write(_refreshKey, null);
    await _write(_companyKey, null);
  }
}
