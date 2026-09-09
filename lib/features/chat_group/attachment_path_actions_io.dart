import 'dart:io';

import 'package:chat_group/core/models/attachment_data_uri.dart';

import 'attachment_path_actions_base.dart';

Future<AttachmentPathActionResult> inspectAttachmentPath(String path) async {
  final raw = path.trim();
  if (raw.isEmpty) {
    return const AttachmentPathActionResult.failure('附件路径为空，无法操作。');
  }
  if (isAttachmentDataUri(raw)) {
    return const AttachmentPathActionResult.failure(
      '当前附件是内联数据，暂不支持在文件管理器中定位或复制本地路径。',
    );
  }

  final file = File(raw).absolute;
  try {
    final type = await FileSystemEntity.type(file.path, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      return const AttachmentPathActionResult.failure('附件文件不存在，无法操作。');
    }
    if (type != FileSystemEntityType.file) {
      return const AttachmentPathActionResult.failure('附件路径不是可操作的文件。');
    }
    await file.stat();
    return AttachmentPathActionResult.ok(file.path);
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode == 13) {
      return const AttachmentPathActionResult.failure('没有权限访问该附件文件。');
    }
    return const AttachmentPathActionResult.failure('无法访问附件文件，请检查文件权限。');
  } on Object {
    return const AttachmentPathActionResult.failure('无法访问附件文件，请稍后重试。');
  }
}

Future<AttachmentPathActionResult> revealAttachmentPath(String path) async {
  final inspected = await inspectAttachmentPath(path);
  if (!inspected.success || inspected.absolutePath == null) return inspected;
  final absolutePath = inspected.absolutePath!;

  try {
    final ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', ['-R', absolutePath]);
    } else if (Platform.isWindows) {
      // explorer.exe accepts /select,<absolute path> as one argument. Passing
      // argv directly avoids shell interpolation and path injection.
      result = await Process.run('explorer.exe', ['/select,$absolutePath']);
    } else if (Platform.isLinux) {
      result = await Process.run(
        'xdg-open',
        [File(absolutePath).parent.path],
      );
    } else {
      return const AttachmentPathActionResult.failure(
        '当前平台不支持在文件管理器中显示附件。',
      );
    }
    if (result.exitCode != 0) {
      return const AttachmentPathActionResult.failure(
        '系统未能在文件管理器中显示附件。',
      );
    }
    return AttachmentPathActionResult.ok(absolutePath);
  } on ProcessException {
    return const AttachmentPathActionResult.failure(
      '系统未找到可用的文件管理器，无法显示附件。',
    );
  } on Object {
    return const AttachmentPathActionResult.failure('显示附件位置失败，请稍后重试。');
  }
}
