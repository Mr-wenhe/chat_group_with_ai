import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  int readCount = 0;

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    readCount++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  setUp(CredentialRepository.clearCache);

  test('does not resolve an unmigrated legacy Hive key', () async {
    final store = _MemoryCredentialStore();
    final resolver = SecureApiCredentialResolver(
      CredentialRepository(store: store, secureStorageAvailable: true),
    );
    final config = ApiConfig(
      id: 'legacy',
      name: 'legacy',
      provider: 'deepseek',
      apiKey: 'legacy-key-must-not-be-used',
    );

    expect(await resolver.resolve(config), isNull);
    expect(store.readCount, 0);
  });

  test('resolves only the configured secure-storage credential', () async {
    final store = _MemoryCredentialStore();
    final repository =
        CredentialRepository(store: store, secureStorageAvailable: true);
    final resolver = SecureApiCredentialResolver(repository);
    final config = ApiConfig(
      id: 'configured',
      name: 'configured',
      provider: 'deepseek',
      credentialId: repository.credentialIdFor('configured'),
      hasCredential: true,
    );
    store.values[repository.credentialIdFor(config.id)] = 'secure-key';

    expect(await resolver.resolve(config), 'secure-key');
  });
}
