import 'package:flutter/foundation.dart';

/// Build-time configuration.
///
/// Override the API base URL with
/// `--dart-define=API_BASE_URL=https://erp.example.com/api/v1`.
abstract final class AppConfig {
  static const String _apiBaseUrlFromEnv = String.fromEnvironment(
    'API_BASE_URL',
  );

  static const Duration requestTimeout = Duration(seconds: 20);

  static String get apiBaseUrl {
    if (_apiBaseUrlFromEnv.isNotEmpty) return _apiBaseUrlFromEnv;
    // The Android emulator reaches the host machine through 10.0.2.2.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8080/api/v1';
    }
    return 'http://localhost:8080/api/v1';
  }
}
