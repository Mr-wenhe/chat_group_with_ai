import 'dart:io';

import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds isolated safe group and direct-chat workspaces', () async {
    final root = await Directory.systemTemp.createTemp('work_mode_dirs_');
    addTearDown(() => root.delete(recursive: true));
    const service = WorkModeDirectoryService();

    final groupDir = await service.conversationDir(
      root: root,
      conversationId: 'group/../unsafe',
      isDirectChat: false,
    );
    final dmDir = await service.conversationDir(
      root: root,
      conversationId: 'dm:character-1',
      isDirectChat: true,
    );

    expect(groupDir.path, contains('group_group_unsafe'));
    expect(dmDir.path, contains('dm_character-1'));
    expect(groupDir.path, isNot(dmDir.path));
  });
}
