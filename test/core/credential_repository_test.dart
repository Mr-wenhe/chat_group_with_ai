import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCredentialStore implements CredentialStore {
  final values = <String, String>{};
  Object? writeError;
  Object? readError;
  Object? deleteError;
  bool corruptWrites = false;

  @override
  Future<void> delete(String key) async {
    if (deleteError != null) throw deleteError!;
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (readError != null) throw readError!;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (writeError != null) throw writeError!;
    values[key] = corruptWrites ? 'not-the-secret' : value;
  }
}

/// 内存版 [SecureStorageService]，仅实现 [CredentialRepository] 过渡双写所需的
/// 旧前缀（api_config_key_）方法，前缀与正式实现保持一致。
class FakeSecureStorageService extends SecureStorageService {
  final Map<String, String> legacy = {};
  Object? deleteError;

  @override
  Future<bool> saveApiConfigKey(String configId, String apiKey) async {
    legacy['api_config_key_$configId'] = apiKey;
    return true;
  }

  @override
  Future<String?> getApiConfigKey(String configId) async {
    return legacy['api_config_key_$configId'];
  }

  @override
  Future<void> deleteApiConfigKey(String configId) async {
    if (deleteError != null) throw deleteError!;
    legacy.remove('api_config_key_$configId');
  }
}

void main() {
  group('CredentialRepository', () {
    late FakeCredentialStore store;
    late FakeSecureStorageService legacy;
    late CredentialRepository repository;

    setUp(() {
      store = FakeCredentialStore();
      legacy = FakeSecureStorageService();
      repository = CredentialRepository(
        store: store,
        legacyStorage: legacy,
        secureStorageAvailable: true,
      );
    });

    test('saves, verifies, reads and deletes a config credential', () async {
      expect((await repository.save('cfg-1', 'secret')).isSuccess, isTrue);
      expect(store.values.values, contains('secret'));

      final read = await repository.read('cfg-1');
      expect(read.value, 'secret');
      expect(read.failure, isNull);
      expect(await repository.exists('cfg-1'), isTrue);

      expect((await repository.delete('cfg-1')).isSuccess, isTrue);
      expect((await repository.read('cfg-1')).isMissing, isTrue);
    });

    test('does not report success when secure storage cannot read back a write',
        () async {
      store.corruptWrites = true;

      final result = await repository.save('cfg-1', 'secret');

      expect(result.failure, CredentialFailure.systemError);
    });

    test('maps platform permission failures without leaking the platform error',
        () async {
      store.readError = PlatformException(code: 'permission_denied');

      final result = await repository.read('cfg-1');

      expect(result.failure, CredentialFailure.permissionDenied);
      expect(result.value, isNull);
    });

    test('returns unavailable instead of silently using browser storage',
        () async {
      final webRepository = CredentialRepository(
        store: store,
        secureStorageAvailable: false,
      );

      expect(
        (await webRepository.save('cfg-1', 'secret')).failure,
        CredentialFailure.unavailable,
      );
      expect(
        (await webRepository.read('cfg-1')).failure,
        CredentialFailure.unavailable,
      );
      expect(store.values, isEmpty);
    });

    group('CredentialRepository 过渡双写与旧前缀回退', () {
      late FakeCredentialStore store;
      late FakeSecureStorageService legacy;
      late CredentialRepository repository;

      setUp(() {
        store = FakeCredentialStore();
        legacy = FakeSecureStorageService();
        repository = CredentialRepository(
          store: store,
          legacyStorage: legacy,
          secureStorageAvailable: true,
        );
      });

      test('save 同时双写到新前缀与旧 api_config_key_ 前缀', () async {
        expect((await repository.save('cfg-9', 'topsecret')).isSuccess, isTrue);
        expect(
            await store.read(repository.credentialIdFor('cfg-9')), 'topsecret');
        expect(legacy.legacy['api_config_key_cfg-9'], 'topsecret');
      });

      test('read 在新前缀缺失时回退到旧前缀', () async {
        await legacy.saveApiConfigKey('cfg-7', 'legacy-secret');
        final read = await repository.read('cfg-7');
        expect(read.value, 'legacy-secret');
      });

      test('read 新前缀优先于旧前缀（两者都存在）', () async {
        await legacy.saveApiConfigKey('cfg-7', 'legacy-secret');
        await repository.save('cfg-7', 'new-secret');
        final read = await repository.read('cfg-7');
        expect(read.value, 'new-secret');
      });

      test('delete 同时移除新、旧两套 key', () async {
        await repository.save('cfg-3', 'secret');
        expect(legacy.legacy['api_config_key_cfg-3'], 'secret');
        expect(await store.read(repository.credentialIdFor('cfg-3')), 'secret');

        expect((await repository.delete('cfg-3')).isSuccess, isTrue);
        expect(await store.read(repository.credentialIdFor('cfg-3')), isNull);
        expect(legacy.legacy['api_config_key_cfg-3'], isNull);
      });

      test('delete 不会把旧前缀删除失败报告为成功', () async {
        await repository.save('cfg-3', 'secret');
        legacy.deleteError = PlatformException(code: 'permission_denied');

        final result = await repository.delete('cfg-3');

        expect(result.failure, CredentialFailure.permissionDenied);
        expect(legacy.legacy['api_config_key_cfg-3'], 'secret');
      });
    });
  });
}
