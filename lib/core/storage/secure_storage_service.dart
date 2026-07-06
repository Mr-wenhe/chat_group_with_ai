import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static const String _apiKeyPrefix = 'api_key_';

  Future<void> saveApiKey(String characterId, String apiKey) async {
    await _storage.write(key: '$_apiKeyPrefix$characterId', value: apiKey);
  }

  Future<String?> getApiKey(String characterId) async {
    return await _storage.read(key: '$_apiKeyPrefix$characterId');
  }

  Future<void> deleteApiKey(String characterId) async {
    await _storage.delete(key: '$_apiKeyPrefix$characterId');
  }

  Future<void> saveDefaultProvider(String provider) async {
    await _storage.write(key: 'default_provider', value: provider);
  }

  Future<String?> getDefaultProvider() async {
    return await _storage.read(key: 'default_provider');
  }
}
