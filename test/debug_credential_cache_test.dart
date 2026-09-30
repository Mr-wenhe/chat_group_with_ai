import 'dart:io';

import 'package:chat_group/core/storage/debug_credential_cache.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 调试镜像的核心契约：钥匙串至多被读一次，之后一律由 Hive 应答。
/// 这是 macOS ad-hoc 签名下「每次重建都弹密码框」的唯一收敛手段。
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dev_credential_cache_');
    Hive.init(directory.path);
    await Hive.openBox<dynamic>(DebugCredentialCache.boxName);
  });

  tearDown(() async {
    DebugCredentialCache.bind(null);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('mirrored value is served without touching secure storage', () async {
    await DebugCredentialCache.mirror('k', 'secret');

    var secureReads = 0;
    final value = await DebugCredentialCache.read('k', () async {
      secureReads++;
      return 'from-keychain';
    });

    expect(value, 'secret');
    expect(secureReads, 0, reason: '命中镜像就不该再问钥匙串');
  });

  test('a miss reads secure storage once and then answers from the mirror',
      () async {
    var secureReads = 0;
    Future<String?> readSecure() async {
      secureReads++;
      return 'from-keychain';
    }

    expect(await DebugCredentialCache.read('k', readSecure), 'from-keychain');
    expect(await DebugCredentialCache.read('k', readSecure), 'from-keychain');
    expect(secureReads, 1, reason: '第二次必须由镜像应答');
  });

  test('a miss that finds nothing is not cached, so a later value is seen',
      () async {
    var value = '';
    Future<String?> readSecure() async => value.isEmpty ? null : value;

    expect(await DebugCredentialCache.read('k', readSecure), isNull);
    value = 'later';
    expect(await DebugCredentialCache.read('k', readSecure), 'later');
  });

  test('a deleted key never falls back to secure storage again', () async {
    await DebugCredentialCache.mirror('k', 'secret');
    var secureDeletes = 0;

    await DebugCredentialCache.delete('k', () async => secureDeletes++);

    expect(secureDeletes, 1);
    expect(
      await DebugCredentialCache.read('k', () async => 'still-in-keychain'),
      isNull,
      reason: '墓碑必须盖过钥匙串里残留的副本，否则删除后被静默复活',
    );
  });

  test('a denied secure deletion is swallowed and still blocks the key',
      () async {
    await DebugCredentialCache.mirror('k', 'secret');

    await DebugCredentialCache.delete('k', () async {
      throw const FileSystemException('keychain prompt denied');
    });

    expect(
      await DebugCredentialCache.read('k', () async => 'still-in-keychain'),
      isNull,
    );
  });

  test('writing clears an earlier tombstone', () async {
    await DebugCredentialCache.delete('k', () async {});
    await DebugCredentialCache.write('k', 'fresh', () async {});

    expect(await DebugCredentialCache.read('k', () async => null), 'fresh');
  });

  test('writes never reach secure storage while the mirror is bound', () async {
    var secureWrites = 0;
    await DebugCredentialCache.write('k', 'secret', () async => secureWrites++);

    expect(secureWrites, 0, reason: '重建后的二进制作任何钥匙串写入都可能弹框');
  });

  test('with no mirror bound every operation passes through', () async {
    DebugCredentialCache.bind(null);
    await Hive.close();

    expect(DebugCredentialCache.enabled, isTrue);
    expect(
      await DebugCredentialCache.read('k', () async => 'from-keychain'),
      'from-keychain',
    );
    var secureWrites = 0;
    await DebugCredentialCache.write('k', 'secret', () async => secureWrites++);
    expect(secureWrites, 1, reason: '没有镜像时必须落回安全存储，不能静默丢值');
    var secureDeletes = 0;
    await DebugCredentialCache.delete('k', () async => secureDeletes++);
    expect(secureDeletes, 1);
    expect(await DebugCredentialCache.mirror('k', 'secret'), isFalse);
  });

  test('SecureStorageService answers from the mirror without the plugin',
      () async {
    // 插件在测试环境不可用（MissingPluginException）。镜像命中时压根不该调用它，
    // 所以这条用例能同时证明接线正确与短路生效。
    await DebugCredentialCache.mirror('api_config_key_demo', 'secret');

    final service = SecureStorageService();
    expect(await service.getApiConfigKey('demo'), 'secret');
    expect(await service.saveApiConfigKey('demo', 'rotated'), isTrue);
    expect(await service.getApiConfigKey('demo'), 'rotated');

    // 删除会尽力调用插件并吞掉失败，不能因此抛出。
    await service.deleteApiConfigKey('demo');
    expect(
      await DebugCredentialCache.read('api_config_key_demo', () async => null),
      isNull,
    );
  });
}
