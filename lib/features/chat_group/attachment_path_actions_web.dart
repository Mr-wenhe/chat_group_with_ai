import 'attachment_path_actions_base.dart';

Future<AttachmentPathActionResult> inspectAttachmentPath(String path) async {
  if (path.trim().isEmpty) {
    return const AttachmentPathActionResult.failure('附件路径为空，无法操作。');
  }
  return const AttachmentPathActionResult.failure(
    'Web 端没有可访问的本地附件路径，暂不支持此操作。',
  );
}

Future<AttachmentPathActionResult> revealAttachmentPath(String path) async {
  return inspectAttachmentPath(path);
}
