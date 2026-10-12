import 'package:chat_group/core/models/media_attachment.dart';

/// 工作模式详情留档在事件目录里的固定子路径。
///
/// 与 `WorkTaskEventStore` 的 `_eventsDirectory` 同源，但只取这段标记而不是
/// 完整路径：识别发生在 widget 里，那里拿不到 app-support 目录，而详情文件
/// 永远落在这个目录下，路径中段足以定性。
const String _eventsDirectoryMarker = '/work_mode_agent/events/';

/// `WorkTaskEventStore.writeDiscussionDetail` 的落盘文件名形状。
///
/// taskId 只允许 `[A-Za-z0-9_-]`（见 `_validateTaskId`），不含点，所以
/// `.detail.<摘要>.json` 后缀没有歧义；摘要固定 24 位小写十六进制。
final RegExp _detailFileName =
    RegExp(r'^[A-Za-z0-9_-]{1,128}\.detail\.[0-9a-f]{24}\.json$');

/// 是否是工作模式写给自己看的详情留档（方案与验收详情、调查来源与结果、
/// 完整公开正文、工作项交接）。
///
/// 判据取**落盘形状**而不是文件名清单：这几类详情只是同一个写入函数的不同
/// 文件名参数，按名字列举既漏将来新增的，又会被用户上传的同名文件误命中。
/// 走通用附件卡片会让它们显示「待解析」并按其体积与解析状态排版，而它们在
/// 聊天气泡里是台账留档、不是用户附件，也不是交付物。
bool isWorkModeDetailAttachment(MediaAttachment attachment) {
  if (attachment.type != 'file') return false;
  final path = attachment.localPath;
  if (!path.contains(_eventsDirectoryMarker)) return false;
  final name = path.substring(path.lastIndexOf('/') + 1);
  return _detailFileName.hasMatch(name);
}
