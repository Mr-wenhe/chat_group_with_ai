import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/chat_group/attachment_path_actions.dart';
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
}
