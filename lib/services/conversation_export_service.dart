import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 对话导出 / 分享服务：把群聊内容生成为 Markdown 或 JSON，并落盘到本机、
/// 调用系统分享面板。
///
/// ⚠️ 安全红线（与架构一致）：导出内容**只**取展示性字段（name / avatar / role /
/// personalityTags / age + 消息内容），**绝不**包含 apiKey / apiProvider /
/// apiConfigId / apiConfig，避免密钥外泄。这一点在 [toJson] / [toMarkdown] 中
/// 通过「只读取 AICharacter 的展示字段」来硬保证。
class ConversationExportService {
  /// 导出目录名（位于 ApplicationDocumentsDirectory 下）。
  static const String exportDirName = 'chat_group_exports';

  /// 生成为 Markdown：标题（群组名 / 主题）+ 按时间排序的「角色名：内容」段落。
  String toMarkdown(
    ChatGroup group,
    List<Message> messages,
    Map<String, AICharacter> charById,
  ) {
    final sorted = _sortByTime(messages);
    final buf = StringBuffer();
    buf.writeln('# ${group.name}');
    if (group.theme.trim().isNotEmpty) {
      buf.writeln('> 主题：${group.theme.trim()}');
    }
    buf.writeln();
    buf.writeln('导出时间：${_formatDateTime(DateTime.now())}');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();
    for (final m in sorted) {
      final name = _senderName(m, charById);
      final role = _senderRole(m, charById);
      final who = role.isNotEmpty ? '$name（$role）' : name;
      buf.writeln('**$who** · ${_formatTime(m.timestamp)}');
      buf.writeln();
      buf.writeln(m.content.trim().isEmpty ? '（空消息）' : m.content);
      buf.writeln();
    }
    return buf.toString();
  }

  /// 生成为 JSON 结构：{ group:{id,name,theme}, exportedAt, messages:[...] }。
  ///
  /// 每条消息仅含 sender / senderType / name / role / content / timestamp，
  /// **不**含任何密钥或配置字段（见 [toMarkdown] 的安全说明）。
  Map<String, dynamic> toJson(
    ChatGroup group,
    List<Message> messages,
    Map<String, AICharacter> charById,
  ) {
    final sorted = _sortByTime(messages);
    return {
      'group': {
        'id': group.id,
        'name': group.name,
        'theme': group.theme,
      },
      'exportedAt': DateTime.now().toIso8601String(),
      'messages': sorted.map((m) {
        final c = m.senderType == 'user' ? null : charById[m.senderId];
        return {
          'sender': m.senderId,
          'senderType': m.senderType,
          'name': c?.name ?? (m.senderType == 'user' ? '用户' : m.senderId),
          'role': c?.role ?? (m.senderType == 'user' ? '用户' : ''),
          'content': m.content,
          'timestamp': m.timestamp.toIso8601String(),
        };
      }).toList(),
    };
  }

  /// 把内容写入 `<baseDirectory>/chat_group_exports/<fileName>`。
  ///
  /// [fileName] 由调用方负责拼接（含群组名 + 时间戳 + 扩展名），本方法只负责落盘。
  /// [baseDirectory] 可选：默认使用 `path_provider` 的 ApplicationDocumentsDirectory；
  /// 留出该参数仅为单测可注入临时目录，业务调用仍走默认路径。
  Future<File> saveToFile(
    String content,
    String fileName, {
    Directory? baseDirectory,
  }) async {
    final dir = baseDirectory ?? (await getApplicationDocumentsDirectory());
    final exportDir = Directory('${dir.path}/$exportDirName');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    final file = File('${exportDir.path}/$fileName');
    return file.writeAsString(content, flush: true);
  }

  /// 调用系统分享面板分享已导出的文件（依赖 share_plus）。
  Future<void> share(File file) async {
    await Share.shareXFiles([XFile(file.path)], text: 'AI 群聊对话导出');
  }

  // ---- 以下为私有辅助方法 ----

  /// 按时间升序排序，保证导出内容顺序与对话一致。
  List<Message> _sortByTime(List<Message> messages) =>
      List<Message>.from(messages)
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  /// 发送者展示名：用户统一显示「用户」，已删除 AI 使用稳定占位名。
  String _senderName(Message m, Map<String, AICharacter> charById) {
    if (m.senderType == 'user') return '用户';
    return charById[m.senderId]?.name ?? '已删除角色';
  }

  /// 发送者角色：用户为「用户」，AI 取角色 role（未知则空）。
  String _senderRole(Message m, Map<String, AICharacter> charById) {
    if (m.senderType == 'user') return '用户';
    return charById[m.senderId]?.role ?? '';
  }

  /// 格式化为 `YYYY-MM-DD HH:mm`，避免平台差异。
  String _formatDateTime(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} ${_pad(dt.hour)}:${_pad(dt.minute)}';

  /// 格式化时间片段 `MM-DD HH:mm`，用于消息行首。
  String _formatTime(DateTime dt) =>
      '${_pad(dt.month)}-${_pad(dt.day)} ${_pad(dt.hour)}:${_pad(dt.minute)}';

  String _pad(int n) => n.toString().padLeft(2, '0');
}
