import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/work_mode/work_mode_config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  test('persists group and direct-chat work mode independently', () async {
    final directory = await Directory.systemTemp.createTemp('work-mode-');
    addTearDown(() async {
      await Hive.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    Hive.init(directory.path);
    await Hive.openBox<dynamic>('app_settings');
    final service = WorkModeConfigService(db: DatabaseService());

    await service.setWorkMode('group-1', true);
    await service.setWorkMode('dm:character-1', false);

    expect(service.isWorkMode('group-1'), isTrue);
    expect(service.isWorkMode('dm:character-1'), isFalse);

    await Hive.box<dynamic>('app_settings').close();
    await Hive.openBox<dynamic>('app_settings');
    final reloaded = WorkModeConfigService(db: DatabaseService());
    expect(reloaded.isWorkMode('group-1'), isTrue);
    expect(reloaded.isWorkMode('dm:character-1'), isFalse);
  });

  test('legacy autonomy state does not silently enable work mode', () async {
    final directory =
        await Directory.systemTemp.createTemp('work-mode-legacy-');
    addTearDown(() async {
      await Hive.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    Hive.init(directory.path);
    final box = await Hive.openBox<dynamic>('app_settings');
    await box.put('autonomous_enabled:group-1', true);

    final service = WorkModeConfigService(db: DatabaseService());
    expect(service.isWorkMode('group-1'), isFalse);
  });
}
