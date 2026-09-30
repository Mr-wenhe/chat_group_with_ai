import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 与 `DatabaseService._realtimeUserIdKey` 保持一致的存储键。
///
/// 刻意在测试里重复这个字面量而不是导出私有常量：这条用例要断言的正是
/// "这个键在懒生成时不被写入"，键名本身是外部契约的一部分。
const String _realtimeUserIdKey = 'realtime_user_id';

class _TestPathProvider extends PathProviderPlatform {
  final String supportPath;

  _TestPathProvider(this.supportPath);

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => supportPath;
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('realtime_identity_test_');
    PathProviderPlatform.instance = _TestPathProvider(directory.path);
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('懒生成的实时身份不落盘', () async {
    // app_settings 预先打开，这样"没写进去"才是可观察的事实，而不是盒子没开。
    await Hive.openBox<dynamic>('app_settings');
    final database = DatabaseService(userHomePath: directory.path);

    // `realtimeUserId` 会被 widget 的 build 调用（判断"我是不是主人"）。
    // 构建路径上的异步写会发到构建所在的异步区：在 flutter_test 的假时钟区里
    // 那次写永远不完成，会卡住 app_settings 的写队列，让后续每一次写乃至
    // Hive.close() 一起挂死。所以这里必须只生成标识，不落盘。
    final lazyId = database.realtimeUserId;
    expect(lazyId, isNotEmpty);
    expect(Hive.box<dynamic>('app_settings').get(_realtimeUserIdKey), isNull);

    database.dispose();
  });

  // Hive 的 TypeAdapter 在一个进程里只能注册一次，所以本文件只有这一个用例
  // 调用 `DatabaseService.init()`。
  test('init 落盘的身份沿用懒生成的那个，且对新实例立即可见', () async {
    await Hive.openBox<dynamic>('app_settings');
    final database = DatabaseService(userHomePath: directory.path);

    final lazyId = database.realtimeUserId;
    await database.init();

    expect(database.realtimeUserId, lazyId);
    expect(Hive.box<dynamic>('app_settings').get(_realtimeUserIdKey), lazyId);
    database.dispose();

    // 重启后的第二个实例在 init 之前就该读到同一个标识，而不是又生成一个。
    final restarted = DatabaseService(userHomePath: directory.path);
    expect(restarted.realtimeUserId, lazyId);
    restarted.dispose();
  });
}
