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

  test('prefers an explicit local project path over the desktop fallback', () {
    const service = WorkModeDirectoryService();

    expect(
      service.requestedWorkspacePath(
        '读取/Volumes/new_disk/work/flutter/guess 的所有文件并生成文档',
      ),
      '/Volumes/new_disk/work/flutter/guess',
    );
    expect(
      service.requestedWorkspacePath('请把报告保存到桌面'),
      contains('/Desktop'),
    );
    expect(
      service.requestedLocalPath('参考 https://example.com/Volumes/demo 的说明'),
      isNull,
    );
  });

  test('does not include sentence punctuation in an explicit local path', () {
    const service = WorkModeDirectoryService();

    expect(
      service.requestedLocalPath(
        'The selected workspace root is /Users/fengye/Desktop. Bind it now.',
      ),
      '/Users/fengye/Desktop',
    );
    expect(
      service.requestedLocalPath(
        'Use /Users/fengye/project.v2/output for this task.',
      ),
      '/Users/fengye/project.v2/output',
    );
  });
}
