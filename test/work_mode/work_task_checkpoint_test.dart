import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('durable tool checkpoint omits file content and shell command', () {
    const request = ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '写入包含 token=super-secret 的报告',
      args: <String, dynamic>{
        'path': '/Users/alice/private/report.md',
        'content': 'PRIVATE FILE BODY',
        'overwrite': true,
      },
    );

    final checkpoint = safeToolRequestCheckpoint(request);
    expect(checkpoint, isNot(contains('PRIVATE FILE BODY')));
    expect(checkpoint, isNot(contains('super-secret')));
    expect(checkpoint, contains('contentLength'));
    expect(checkpoint, contains('report.md'));
  });

  test('backup task codec redacts legacy raw operation payloads', () {
    final task = AgentTask(
      id: 'checkpoint-task',
      groupId: 'group',
      characterId: 'worker',
      userRequest: '生成报告',
      workModeTask: true,
      completedOperations: const [
        '{"tool":"workspace.patch","reason":"写入","args":{"path":"report.md","content":"PRIVATE"}}',
      ],
      pendingToolRequestJson:
          '{"tool":"command.run","args":{"command":"curl SECRET"}}',
    );

    final encoded = BackupEntityCodec.task(task);
    final serialized = jsonEncode(encoded);
    expect(serialized, isNot(contains('PRIVATE')));
    expect(serialized, isNot(contains('curl SECRET')));
    expect(serialized, contains('contentLength'));
    expect(serialized, contains('commandPresent'));
  });
}
