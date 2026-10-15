import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/chat_group/attachment_path_actions.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves an existing attachment to an absolute path', () async {
    final directory = await Directory.systemTemp.createTemp('attachment-path-');
    try {
      final file = File('${directory.path}/report.txt')
        ..writeAsStringSync('report');
      final result = await inspectAttachmentPath(file.path);
      expect(result.success, isTrue);
      expect(result.absolutePath, file.absolute.path);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('returns stable errors for missing files and data URIs', () async {
    final missing = await inspectAttachmentPath(
      '${Directory.systemTemp.path}/missing-attachment-${DateTime.now().microsecondsSinceEpoch}',
    );
    expect(missing.success, isFalse);
    expect(missing.message, contains('不存在'));

    final inline = await inspectAttachmentPath('data:text/plain;base64,SGk=');
    expect(inline.success, isFalse);
    expect(inline.message, contains('内联数据'));
  });

  test('work artifact operations keep using the original path when it is gone',
      () async {
    final directory = await Directory.systemTemp.createTemp('artifact-path-');
    try {
      final original = '${directory.path}/original.html';
      final cache = File('${directory.path}/cached.html')
        ..writeAsStringSync('<html><body>cache</body></html>');
      final attachment = MediaAttachment(
        type: 'file',
        localPath: original,
        cachePath: cache.path,
        fileName: 'original.html',
      );

      final result = await inspectAttachmentPath(attachment.localPath);

      expect(result.success, isFalse);
      expect(result.message, contains('不存在'));
      expect(await cache.exists(), isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('Windows 定位参数把正斜杠路径归一化为反斜杠', () {
    // 工作模式产物路径是正斜杠风格；explorer.exe 的 /select, 只认反斜杠，
    // 否则只会打开一个默认的资源管理器窗口。
    expect(
      windowsExplorerSelectArgument(r'C:/Users/oray/data/方案.md'),
      r'/select,C:\Users\oray\data\方案.md',
    );
  });

  test('纯文本附件走应用内可读视图，其余交给系统打开', () {
    MediaAttachment withName(String name) =>
        MediaAttachment(type: 'file', localPath: '/tmp/$name', fileName: name);

    for (final name in const [
      'plan.md',
      'notes.txt',
      'config.json',
      'data.yaml',
      'rows.csv',
    ]) {
      expect(isPlainTextAttachment(withName(name)), isTrue, reason: name);
    }
    for (final name in const ['report.pdf', 'brief.docx', 'photo.png']) {
      expect(isPlainTextAttachment(withName(name)), isFalse, reason: name);
    }
  });
}
