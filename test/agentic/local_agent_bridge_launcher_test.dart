import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:dio/dio.dart';
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

  test('concurrent registrations share one bridge and preserve both mappings',
      () async {
    final root = await Directory.systemTemp.createTemp('bridge_concurrent_');
    final first = await Directory('${root.path}/first').create();
    final second = await Directory('${root.path}/second').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await Future.wait([
      launcher.registerWorkspace(
        conversationId: 'conv-a',
        workspacePath: first.path,
      ),
      launcher.registerWorkspace(
        conversationId: 'conv-b',
        workspacePath: second.path,
      ),
    ]);

    final client = LocalAgentBridgeClient();
    await WorkspaceFileTool(client, conversationId: 'conv-a')
        .write('a.txt', 'a');
    await WorkspaceFileTool(client, conversationId: 'conv-b')
        .write('b.txt', 'b');

    expect(await File('${first.path}/a.txt').readAsString(), 'a');
    expect(await File('${second.path}/b.txt').readAsString(), 'b');
    expect(launcher.isRunning, isTrue);
  });

  test('stale workspace lease cannot unregister a newer registration',
      () async {
    final root = await Directory.systemTemp.createTemp('bridge_lease_');
    final first = await Directory('${root.path}/first').create();
    final second = await Directory('${root.path}/second').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    final firstLease = await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: first.path,
    );
    final secondLease = await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: second.path,
    );
    expect(firstLease, isNotNull);
    expect(secondLease, isNotNull);

    // A task from the first registration may finish after the conversation has
    // already been rebound. It must not remove the newer route.
    await launcher.unregisterWorkspace(
      conversationId: 'conv-a',
      registration: firstLease,
    );
    await File('${second.path}/marker.txt').writeAsString('second');

    final client = LocalAgentBridgeClient();
    final readback = await WorkspaceFileTool(
      client,
      conversationId: 'conv-a',
    ).read('marker.txt');
    expect(readback['content'], 'second');

    await launcher.unregisterWorkspace(
      conversationId: 'conv-a',
      registration: secondLease,
    );
    expect(launcher.isRunning, isFalse);
  });

  test(
      'registerWorkspace routes two conversations to separate workspaces '
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
    expect((await firstClient.getHealth())['ok'], isTrue);
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

  test('changing one conversation workspace preserves the other mapping',
      () async {
    final root = await Directory.systemTemp.createTemp('bridge_rebind_');
    final first = await Directory('${root.path}/first').create();
    final second = await Directory('${root.path}/second').create();
    final replacement = await Directory('${root.path}/replacement').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: first.path,
    );
    await launcher.registerWorkspace(
      conversationId: 'conv-b',
      workspacePath: second.path,
    );
    final secondClient = LocalAgentBridgeClient();
    await WorkspaceFileTool(secondClient, conversationId: 'conv-b')
        .write('survives.txt', 'second');

    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: replacement.path,
    );

    final readback = await WorkspaceFileTool(
      secondClient,
      conversationId: 'conv-b',
    ).read('survives.txt');
    expect(readback['content'], 'second');
    expect(File('${replacement.path}/survives.txt').existsSync(), isFalse);
  });

  test('unregistering one conversation keeps the bridge for another', () async {
    final root = await Directory.systemTemp.createTemp('bridge_unregister_');
    final first = await Directory('${root.path}/first').create();
    final second = await Directory('${root.path}/second').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: first.path,
    );
    await launcher.registerWorkspace(
      conversationId: 'conv-b',
      workspacePath: second.path,
    );
    final secondClient = LocalAgentBridgeClient();
    await WorkspaceFileTool(secondClient, conversationId: 'conv-b')
        .write('survives.txt', 'second');

    await launcher.unregisterWorkspace(conversationId: 'conv-a');

    final readback = await WorkspaceFileTool(
      secondClient,
      conversationId: 'conv-b',
    ).read('survives.txt');
    expect(readback['content'], 'second');
    expect(launcher.isRunning, isTrue);
  });

  test('switching one conversation workspace preserves the session and remaps',
      () async {
    final root = await Directory.systemTemp.createTemp('bridge_rotate_');
    final first = await Directory('${root.path}/first').create();
    final second = await Directory('${root.path}/second').create();
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: first.path,
    );
    final oldToken = LocalAgentBridgeEndpoint.currentToken!;
    final oldEndpoint = LocalAgentBridgeEndpoint.currentBaseUrl;
    await launcher.registerWorkspace(
      conversationId: 'conv-a',
      workspacePath: second.path,
    );
    await File('${second.path}/marker.txt').writeAsString('second');

    expect(LocalAgentBridgeEndpoint.currentToken, oldToken);
    final client = LocalAgentBridgeClient(
      baseUrl: oldEndpoint,
      token: oldToken,
    );
    final readback = await WorkspaceFileTool(
      client,
      conversationId: 'conv-a',
    ).read('marker.txt');
    expect(readback['content'], 'second');
  });

  test('stop and restart invalidate the previous session token', () async {
    final root = await Directory.systemTemp.createTemp('bridge_restart_');
    final launcher = LocalAgentBridgeLauncher(preferredPort: 0);
    addTearDown(() async {
      await launcher.stop();
      await root.delete(recursive: true);
    });

    await launcher.start(workspace: root.path);
    final oldToken = LocalAgentBridgeEndpoint.currentToken!;
    await launcher.stop();
    expect(LocalAgentBridgeEndpoint.currentToken, isNull);

    await launcher.start(workspace: root.path);
    expect(LocalAgentBridgeEndpoint.currentToken, isNot(oldToken));
    final staleClient = LocalAgentBridgeClient(
      baseUrl: LocalAgentBridgeEndpoint.currentBaseUrl,
      token: oldToken,
    );
    await expectLater(staleClient.getHealth(), throwsA(isA<DioException>()));
  });
}
