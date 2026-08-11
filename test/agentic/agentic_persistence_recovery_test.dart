// These tests intentionally exercise retired compatibility entry points.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  test('关闭并重开 Hive 后压缩记忆和部分任务仍可恢复', () async {
    final directory = await Directory.systemTemp.createTemp('agent-recovery-');
    addTearDown(() async {
      await Hive.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    Hive.init(directory.path);
    _registerAdapters();
    var taskBox = await Hive.openBox<AgentTask>('tasks');
    final character = _character();
    final memory = CharacterMemory(groupId: 'dm:c1', characterId: 'c1');
    const manager = ContextWindowManager(complete: _unusedCompletion);

    await expectLater(
      manager.persistToCharacterMemory(
        character: character,
        memory: memory,
        summary: const ContextSummary(summary: '恢复摘要'),
        saveCharacter: (_) async {},
        saveMemory: (_) async {},
      ),
      throwsA(isA<UnsupportedError>()),
    );
    final task = AgentTask(
      id: 'task-1',
      groupId: 'dm:c1',
      characterId: 'c1',
      userRequest: '生成页面',
      completedOperations: const ['{"tool":"workspace.patch"}'],
    )..markPartiallyCompleted('HTTP 503');
    await taskBox.put(task.id, task);

    await taskBox.close();
    taskBox = await Hive.openBox<AgentTask>('tasks');

    expect(taskBox.get('task-1')!.status, AgentTaskStatus.partiallyCompleted);
    expect(taskBox.get('task-1')!.canResume, isTrue);
  });
}

void _registerAdapters() {
  if (!Hive.isAdapterRegistered(10)) {
    Hive.registerAdapter(ToolPermissionAdapter());
  }
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(AgentTaskStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(13)) {
    Hive.registerAdapter(AgentTaskAdapter());
  }
}

Future<Map<String, dynamic>> _unusedCompletion(
  List<Map<String, dynamic>> messages,
) async =>
    {'success': true, 'message': '{}'};

AICharacter _character() => AICharacter(
      id: 'c1',
      name: '恢复测试角色',
      avatar: '🧠',
      age: 28,
      role: '助理',
      personalityTags: const [],
      systemPrompt: '保留长期记忆。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );
