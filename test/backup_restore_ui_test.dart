import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/settings/backup_restore_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('import preview shows compatibility, conflicts and missing keys',
      (tester) async {
    final manifest = BackupManifest(
      formatVersion: 1,
      schemaVersion: 1,
      appVersion: '1.1.0',
      createdAt: DateTime.utc(2026, 7, 16),
      scope: BackupScope.all,
      counts: const {
        'characters': 3,
        'groups': 2,
        'messages': 42,
        'attachments': 4,
      },
      files: const {},
      missingAttachments: const ['missing.jpg'],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BackupPreviewPanel(
          preview: BackupPreview(
            manifest: manifest,
            packageBytes: 2048,
            attachmentCount: 4,
            credentialsToRebind: 2,
            conflicts: 5,
            checksumsValid: true,
          ),
        ),
      ),
    ));

    expect(find.textContaining('schema v1'), findsOneWidget);
    expect(find.textContaining('42 条消息'), findsOneWidget);
    expect(find.textContaining('5 个冲突'), findsOneWidget);
    expect(find.textContaining('缺失附件：1 个'), findsOneWidget);
    expect(find.textContaining('2 个 API 配置需要重新绑定 Key'), findsOneWidget);
  });
}
