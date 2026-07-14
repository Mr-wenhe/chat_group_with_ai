import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerWorkspace is idempotent for the same workspace', () async {
    final root = await Directory.systemTemp.createTemp('bridge_same_');
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: root.path,
    );
    final firstEndpoint = LocalAgentBridgeEndpoint.currentBaseUrl;
    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: root.path,
    );

    expect(LocalAgentBridgeEndpoint.currentBaseUrl, firstEndpoint);
    expect(launcher.isRunning, isTrue);
  });

  test('registerWorkspace routes two conversations to separate workspaces '
      'without restarting the server', () async {
    final root = await Directory.systemTemp.createTemp('bridge_switch_');
    final first = await Directory('${root.path}/旧 工作区').create();
    final second = await Directory('${root.path}/Windows Project 新').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: first.path,
    );
    final firstClient = LocalAgentBridgeClient();
    expect((await firstClient.getHealth())['workspaces'],
        containsAll(['', 'conv-a']));
    await WorkspaceFileTool(firstClient, conversationId: 'conv-a')
        .write('before.txt', 'first');

    // 关键：切换到第二个对话的 workspace 不应 stop/start 服务（旧实现会因此
    // 产生端口竞态 / 404）。新设计仅注册新 conversationId -> workspace 映射。
    final endpointBeforeSwitch = LocalAgentBridgeEndpoint.currentBaseUrl;
    await launcher.registerWorkspace(
      conversationId: 'conv-b',
      workspacePath: second.path,
    );
    expect(LocalAgentBridgeEndpoint.currentBaseUrl, endpointBeforeSwitch);

    final secondClient = LocalAgentBridgeClient();
    await WorkspaceFileTool(secondClient, conversationId: 'conv-b')
        .write(r'nested\windows-path.txt', 'second');

    // 对话 A 的文件仍在原工作区，未被 B 覆盖；对话 B 落在自己的目录。
    expect(File('${first.path}/before.txt').existsSync(), isTrue);
    expect(File('${first.path}/nested/windows-path.txt').existsSync(), isFalse);
    expect(File('${second.path}/nested/windows-path.txt').existsSync(), isTrue);

    // 反向验证：用对话 A 的 conversationId 仍能读到 A 的文件（路由正确）。
    final readback =
        await WorkspaceFileTool(firstClient, conversationId: 'conv-a')
            .read('before.txt');
    expect(readback['content'], 'first');
  });
}
