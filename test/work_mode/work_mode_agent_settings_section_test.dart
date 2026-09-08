import 'dart:io';

import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/settings/work_mode_agent_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory hiveDirectory;
  late Box<dynamic> settingsBox;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('agent-settings-');
    Hive.init(hiveDirectory.path);
    settingsBox = await Hive.openBox<dynamic>('app_settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  testWidgets('shows grant controls, limits, and non-disableable confirmations',
      (tester) async {
    final root = await tester.runAsync(
      () => Directory('${hiveDirectory.path}/project').create(),
    );
    final rootDirectory = root!;
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
    );
    await tester.runAsync(() => service.addDirectory(rootDirectory.path));
    await tester.runAsync(() => service.load());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkModeAgentSettingsSection(service: service),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(WorkModeAgentSettingsSection), findsOneWidget);

    expect(find.byKey(const Key('work-mode-agent-settings')), findsOneWidget);
    expect(find.text('授权目录'), findsOneWidget);
    expect(find.textContaining('30 天'), findsOneWidget);
    expect(find.textContaining('2 GB'), findsOneWidget);
    expect(find.textContaining('100 步'), findsOneWidget);
    expect(find.textContaining('60 分钟'), findsOneWidget);
    expect(find.textContaining('删除文件和不可撤销覆盖始终需要确认'), findsOneWidget);
    expect(find.textContaining('移除授权只停止 App 访问'), findsOneWidget);
    expect(find.byKey(const Key('work-folder-confirm-writes')), findsOneWidget);
    expect(find.byKey(Key('work-folder-remove:${service.grants.single.path}')),
        findsOneWidget);
  });

  testWidgets(
      'adding a picked directory and disabling ordinary write prompts persist',
      (tester) async {
    final picked = await tester.runAsync(
      () => Directory('${hiveDirectory.path}/picked').create(),
    );
    final pickedDirectory = picked!;
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
    );
    await tester.runAsync(() => service.load());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkModeAgentSettingsSection(
            service: service,
            pickDirectory: () async => pickedDirectory.path,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(
      () => tester.tap(find.byKey(const Key('work-folder-add'))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const Key('work-folder-grant-consent-dialog')),
      findsOneWidget,
    );
    await tester.runAsync(
      () => tester.tap(
        find.byKey(const Key('work-folder-grant-consent-confirm')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.isPathAuthorized('${pickedDirectory.path}/file.md'), isTrue);
    expect(service.grants.single.cloudDisclosureConfirmedAt, isNotNull);

    await tester.runAsync(
      () => tester.tap(find.byKey(const Key('work-folder-confirm-writes'))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.settings.ordinaryWriteConfirmation, isFalse);
  });

  testWidgets('authorizes multiple picked directories from one confirmation',
      (tester) async {
    final first = await tester.runAsync(
      () => Directory('${hiveDirectory.path}/first').create(),
    );
    final second = await tester.runAsync(
      () => Directory('${hiveDirectory.path}/second').create(),
    );
    final firstDirectory = first!;
    final secondDirectory = second!;
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    await tester.runAsync(() => service.load());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkModeAgentSettingsSection(
            service: service,
            pickDirectories: () async => <String>[
              firstDirectory.path,
              secondDirectory.path,
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(
      () => tester.tap(find.byKey(const Key('work-folder-add'))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const Key('work-folder-grant-batch-consent-dialog')),
      findsOneWidget,
    );
    expect(find.text(firstDirectory.path), findsOneWidget);
    expect(find.text(secondDirectory.path), findsOneWidget);

    await tester.runAsync(
      () => tester.tap(
        find.byKey(const Key('work-folder-grant-batch-consent-confirm')),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.grants, hasLength(2));
    expect(
      service.grants.every((grant) => grant.cloudDisclosureConfirmedAt != null),
      isTrue,
    );
  });
}
