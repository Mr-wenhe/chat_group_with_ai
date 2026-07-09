import 'dart:io';

import 'package:chat_group/features/autonomous/autonomous_directory_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds safe group and direct task directories', () async {
    final root = await Directory.systemTemp.createTemp('autonomous_dirs_');
    addTearDown(() => root.delete(recursive: true));
    const service = AutonomousDirectoryService();

    final groupDir = await service.taskDir(
      root: root,
      conversationId: 'group/../unsafe',
      isDirectChat: false,
      taskId: 'task:1',
    );
    final dmDir = await service.taskDir(
      root: root,
      conversationId: 'dm:character-1',
      isDirectChat: true,
      taskId: 'task:2',
    );

    expect(groupDir.path, contains('group_group_unsafe'));
    expect(groupDir.path, contains('task_task_1'));
    expect(dmDir.path, contains('dm_character-1'));
    expect(await Directory('${groupDir.path}/artifacts').exists(), isTrue);
  });
}
