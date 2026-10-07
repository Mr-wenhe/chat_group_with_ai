import 'package:chat_group/core/models/message.dart';
import 'package:hive/hive.dart';

/// 删除工作任务后在该会话上划下的「工作上下文分界线」。
///
/// 工作任务的模型提示里有两条来自聊天记录的通道（执行提示的对话历史、群讨论
/// 里的「近期群聊」）。任务被真删除后，下一个任务应当从干净状态起步，而不是接着
/// 一段已经被放弃的上下文继续。分界线把这件事变成一条持久、单向的规则：线之前的
/// 消息永不再进入模型提示。聊天界面、磁盘产物与工作区绑定都不受影响。
///
/// 单向性是这个类存在的理由：回退、或读不懂的值，都不能让旧上下文复活。因此
/// [advance] 只接受更晚的时刻，[readAt] 对损坏值返回 null（视为没有分界线），
/// 而不是拿一个猜出来的时刻去切。
class WorkContextBoundary {
  const WorkContextBoundary._();

  /// 每条会话一个键，沿用 `work_mode_enabled:<id>` 的形态：删除会话、清数据、
  /// 备份导入都按精确键处理，不必再维护一张按会话展开的映射表。
  static const String storageKeyPrefix = 'work_mode_context_boundary:';

  static String storageKey(String conversationId) =>
      '$storageKeyPrefix$conversationId';

  /// 读取分界线；没有分界线或值已损坏时返回 null，调用方据此不过滤。
  static DateTime? readAt(Box<dynamic> settingsBox, String conversationId) {
    final raw = settingsBox.get(storageKey(conversationId));
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  /// 把分界线推到 [at]；只在更晚时写入，**永不回退**。
  static Future<void> advance(
    Box<dynamic> settingsBox,
    String conversationId,
    DateTime at,
  ) async {
    final current = readAt(settingsBox, conversationId);
    if (current != null && !at.isAfter(current)) return;
    await settingsBox.put(storageKey(conversationId), at.toIso8601String());
  }

  /// 只保留严格晚于分界线的消息；没有分界线时原样返回。
  ///
  /// 判据取「严格晚于」而不是「不早于」：分界线取自删除那一刻，与之同刻的消息
  /// 属于被删除的这次操作。宁可少喂一点上下文，也不要把刚被放弃的任务内容放回去。
  static List<Message> visible(
    Box<dynamic> settingsBox,
    String conversationId,
    Iterable<Message> messages,
  ) {
    final boundary = readAt(settingsBox, conversationId);
    if (boundary == null) return List<Message>.of(messages);
    return messages
        .where((message) => message.timestamp.isAfter(boundary))
        .toList(growable: false);
  }
}
