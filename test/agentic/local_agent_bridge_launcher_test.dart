import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restart is idempotent for the same workspace', () async {
    final root = await Directory.systemTemp.createTemp('bridge_same_');
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.restart(workspace: root.path);
    final firstEndpoint = LocalAgentBridgeEndpoint.currentBaseUrl;
    await launcher.restart(workspace: root.path);

    expect(LocalAgentBridgeEndpoint.currentBaseUrl, firstEndpoint);
  });

  test('restart switches unicode workspace without stale 400 responses',
      () async {
    final root = await Directory.systemTemp.createTemp('bridge_switch_');
    final first = await Directory('${root.path}/旧 工作区').create();
    final second = await Directory('${root.path}/Windows Project 新').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.start(workspace: first.path);
    final firstClient = LocalAgentBridgeClient();
    expect((await firstClient.getHealth())['workspace'], first.absolute.path);
    await WorkspaceFileTool(firstClient).write('before.txt', 'first');

    await launcher.restart(workspace: second.path);
    final secondClient = LocalAgentBridgeClient();
    expect((await secondClient.getHealth())['workspace'], second.absolute.path);
    await WorkspaceFileTool(secondClient)
        .write(r'nested\windows-path.txt', 'second');

    expect(File('${first.path}/before.txt').existsSync(), isTrue);
    expect(File('${first.path}/nested/windows-path.txt').existsSync(), isFalse);
    expect(File('${second.path}/nested/windows-path.txt').existsSync(), isTrue);
  });
}
