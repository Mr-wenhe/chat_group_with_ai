import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
// The platform interface is the supported test seam for path_provider.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPathProvider extends PathProviderPlatform {
  final String supportPath;

  _TestPathProvider(this.supportPath);

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => supportPath;
}

void main() {
  late Directory supportDirectory;

  setUp(() async {
    supportDirectory =
        await Directory.systemTemp.createTemp('database_adapter_test_');
    PathProviderPlatform.instance = _TestPathProvider(supportDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test(
      'DatabaseService registers enum adapters before writing permanent memory',
      () async {
    final database = DatabaseService();
    await database.init();

    final memory = PermanentMemory(
      id: 'adapter-smoke',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: 'adapter smoke',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    await database.permanentMemoryBox.put(memory.id, memory);

    expect(
        database.permanentMemoryBox.get(memory.id)?.content, 'adapter smoke');
    database.dispose();
  });
}
