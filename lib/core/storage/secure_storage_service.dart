import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static const String _apiKeyPrefix = 'api_key_';
  static const String _apiConfigKeyPrefix = 'api_config_key_';

  Future<void> saveApiKey(String characterId, String apiKey) async {
    await _storage.write(key: '$_apiKeyPrefix$characterId', value: apiKey);
  }

  Future<String?> getApiKey(String characterId) async {
    return await _storage.read(key: '$_apiKeyPrefix$characterId');
  }

  Future<void> deleteApiKey(String characterId) async {
    await _storage.delete(key: '$_apiKeyPrefix$characterId');
  }

  Future<bool> saveApiConfigKey(String configId, String apiKey) async {
    try {
      await _storage.write(key: '$_apiConfigKeyPrefix$configId', value: apiKey);
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<String?> getApiConfigKey(String configId) async {
    try {
      return await _storage.read(key: '$_apiConfigKeyPrefix$configId');
    } on PlatformException {
      return null;
    }
  }

  Future<void> deleteApiConfigKey(String configId) async {
    try {
      await _storage.delete(key: '$_apiConfigKeyPrefix$configId');
    } on PlatformException {
      // Some macOS debug builds do not have Keychain entitlements. Deleting the
      // Hive row still removes the config from the app in that environment.
    }
  }

  Future<void> saveDefaultProvider(String provider) async {
    await _storage.write(key: 'default_provider', value: provider);
  }

  Future<String?> getDefaultProvider() async {
    return await _storage.read(key: 'default_provider');
  }
}
