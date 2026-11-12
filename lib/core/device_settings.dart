import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small per-device settings that are not part of a company, such as the
/// receipt paper width. Reads and writes never throw: a device without
/// storage simply forgets.
abstract class DeviceSettings {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureDeviceSettings implements DeviceSettings {
  SecureDeviceSettings([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: 'device.$key');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: 'device.$key', value: value);
    } catch (_) {}
  }
}

/// Keeps values in memory; used by tests.
class InMemoryDeviceSettings implements DeviceSettings {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final deviceSettingsProvider = Provider<DeviceSettings>(
  (ref) => SecureDeviceSettings(),
);
