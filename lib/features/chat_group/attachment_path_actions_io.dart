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
    if (Platform.isWindows) {
      // explorer 把请求转交给已运行的资源管理器进程后就返回，定位成功时退出码
      // 仍可能是 1，因此不能用退出码判定成败；命令能发出且未抛 ProcessException
      // 即视为已请求定位。
      await Process.run('explorer.exe', [
        windowsExplorerSelectArgument(absolutePath),
      ]);
      return AttachmentPathActionResult.ok(absolutePath);
    }
    final ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', ['-R', absolutePath]);
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

/// explorer.exe 的定位参数：`/select,<路径>`。
///
/// 只接受反斜杠路径 —— 正斜杠会被当成无效选择器，结果是打开一个默认的资源
/// 管理器窗口而不是定位到文件；而工作模式产物路径恰好是正斜杠风格。
String windowsExplorerSelectArgument(String absolutePath) =>
    '/select,${absolutePath.replaceAll('/', r'\')}';
