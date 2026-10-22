import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_supplement_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'work_candidate_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pasteboard');
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5LkAAAAASUVORK5CYII=');
  for (final image in [true, false]) {
    testWidgets('补充窗口粘贴${image ? '图片' : '文件'}并提交原附件', (tester) async {
      final dir = Directory.systemTemp.createTempSync('supplement-dialog-');
      final source = File('${dir.path}/需求.txt')..writeAsStringSync('保留附件正文');
      final db = CandidateTestDatabase(dir);
      List<MediaAttachment>? submitted;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (call) async => switch (call.method) {
                    'files' => image ? <String>[] : [source.path],
                    'image' => image ? png : null,
                    _ => null,
                  });
      try {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: WorkTaskSupplementDialog(
          database: db,
          onSubmit: (text, attachments) async {
            submitted = attachments;
          },
        ))));
        await tester.enterText(
            find.byKey(const Key('work-supplement-input')), '请按附件修改');
        await tester.runAsync(() async {
          if (image) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          } else {
            await tester.tap(find.text('粘贴'));
          }
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          final media = await db.mediaDir;
          while (await media.list().isEmpty) {
            if (DateTime.now().isAfter(deadline)) fail('附件未保存');
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        expect(tester.takeException(), isNull);
        if (!image) expect(find.text('需求.txt'), findsWidgets);
        await tester.runAsync(() async {
          await tester.tap(find.text('提交补充并保持暂停'));
          await Future<void>.delayed(Duration.zero);
        });
        expect(submitted, hasLength(1));
        expect(submitted!.single.type, image ? 'image' : 'file');
        expect(File(submitted!.single.localPath).readAsBytesSync(),
            image ? png : utf8.encode('保留附件正文'));
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        dir.deleteSync(recursive: true);
      }
    });
  }
}
