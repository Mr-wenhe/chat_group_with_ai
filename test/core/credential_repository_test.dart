import 'package:chat_group/core/storage/credential_repository.dart';
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

void main() {
  group('CredentialRepository', () {
    late FakeCredentialStore store;
    late CredentialRepository repository;

    setUp(() {
      store = FakeCredentialStore();
      repository =
          CredentialRepository(store: store, secureStorageAvailable: true);
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
  });
}
