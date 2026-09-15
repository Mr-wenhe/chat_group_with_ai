import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'media_attachment.g.dart';

/// 聊天气泡内的附件（图片 / 视频 / 文件）。
///
/// 普通用户附件仍把 [localPath] 作为 app 媒体目录路径；工作模式产物
/// 则把 [localPath] 保留为用户指定的原路径，并用 [cachePath] 保存投递
/// 缓存。这样“打开附件”不会悄悄改指向缓存副本。
@HiveType(typeId: 9)
class MediaAttachment {
  /// 附件唯一 id（用于去重、移除预览）。
  @HiveField(0)
  final String id;

  /// 附件类型：'image' | 'video' | 'file'。
  @HiveField(1)
  final String type;

  /// 复制到媒体目录后的绝对路径。
  @HiveField(2)
  final String localPath;

  /// 原始文件名（可选，便于展示）。
  @HiveField(3)
  final String? fileName;

  /// 文件字节大小（可选）。
  @HiveField(4)
  final int? fileSize;

  /// MIME 类型，如 image/jpeg、video/mp4（可选，用于多模态 base64 前缀）。
  @HiveField(5)
  final String? mimeType;

  /// 视频时长（毫秒，可选）。图片为 null。
  @HiveField(6)
  final int? durationMs;

  /// Optional app-managed cache for a work-mode artifact whose visible
  /// attachment path intentionally remains the original workspace path.
  @HiveField(7)
  final String? cachePath;

  MediaAttachment({
    String? id,
    required this.type,
    required this.localPath,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.durationMs,
    this.cachePath,
  }) : id = id ?? const Uuid().v4();

  /// Path that may be reclaimed by the app's media lifecycle. External
  /// originals are never treated as managed files.
  String get managedPath =>
      cachePath?.trim().isNotEmpty == true ? cachePath!.trim() : localPath;
}
