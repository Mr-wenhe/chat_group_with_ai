import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/text/pinyin_search.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class MessageSearchFilters {
  final String? conversationId;
  final String? senderId;
  final DateTime? from;
  final DateTime? to;
  final bool mentionsOnly;
  final String? attachmentType;

  const MessageSearchFilters({
    this.conversationId,
    this.senderId,
    this.from,
    this.to,
    this.mentionsOnly = false,
    this.attachmentType,
  });
}

class MessageSearchResult {
  final String messageId;
  final String conversationId;
  final String conversationName;
  final String senderName;
  final DateTime timestamp;
  final String snippet;

  const MessageSearchResult({
    required this.messageId,
    required this.conversationId,
    required this.conversationName,
    required this.senderName,
    required this.timestamp,
    required this.snippet,
  });
}

class MessageSearchStatus {
  final int indexedMessages;
  final DateTime? lastBuiltAt;
  final bool isBuilding;

  const MessageSearchStatus({
    required this.indexedMessages,
    required this.lastBuiltAt,
    required this.isBuilding,
  });
}

class MessageSearchCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Rebuildable local keyword cache. Message IDs are stored, never message
/// copies, so deleted records cannot appear as ghost results.
class MessageSearchIndex {
  static const int rebuildYieldBatch = 1000;

  final DatabaseService db;
  final Map<String, List<PinyinFieldDigest>> _fieldsByMessageId = {};
  DateTime? _lastBuiltAt;
  bool _isBuilding = false;

  MessageSearchIndex(this.db);

  MessageSearchStatus get status => MessageSearchStatus(
        indexedMessages: _fieldsByMessageId.length,
        lastBuiltAt: _lastBuiltAt,
        isBuilding: _isBuilding,
      );

  Future<void> rebuild({
    MessageSearchCancelToken? cancelToken,
    void Function(double progress)? onProgress,
  }) async {
    _isBuilding = true;
    _fieldsByMessageId.clear();
    final messages = db.messageBox.values.toList(growable: false);
    try {
      for (var index = 0; index < messages.length; index++) {
        if (cancelToken?.isCancelled == true) return;
        final message = messages[index];
        _fieldsByMessageId[message.id] =
            PinyinSearch.digestFields(_searchFields(message));
        if ((index + 1) % rebuildYieldBatch == 0) {
          onProgress?.call((index + 1) / messages.length);
          await Future<void>.delayed(Duration.zero);
        }
      }
      _lastBuiltAt = DateTime.now();
      onProgress?.call(1);
    } finally {
      _isBuilding = false;
    }
  }

  Future<void> ensureReady() async {
    // 从未构建过：直接重建。
    if (_lastBuiltAt == null) {
      await rebuild();
      return;
    }
    final boxLength = db.messageBox.length;
    // 消息总数变化（纯增 / 纯删 / 增删不等）：一定需要重建。
    if (_fieldsByMessageId.length != boxLength) {
      await rebuild();
      return;
    }
    // 总数相同但可能「删一条旧消息 + 加一条新消息」：检测索引是否覆盖
    // 当前所有消息 id。搜索属低频操作，此处 O(n) 检查可接受；
    // 命中任意未索引 id 即说明索引 stale，需要重建。
    final indexed = _fieldsByMessageId;
    for (final key in db.messageBox.keys) {
      if (!indexed.containsKey(key)) {
        await rebuild();
        return;
      }
    }
  }

  Future<List<MessageSearchResult>> query(
    String text, {
    MessageSearchFilters filters = const MessageSearchFilters(),
    int limit = 100,
    int cursor = 0,
  }) async {
    await ensureReady();
    if (PinyinSearch.splitTerms(text).isEmpty) return const [];
    final matches = <Message>[];
    for (final entry in _fieldsByMessageId.entries) {
      final message = db.messageBox.get(entry.key);
      if (message == null || !_matchesFilters(message, filters)) continue;
      if (PinyinSearch.matchesFieldDigests(entry.value, text)) {
        matches.add(message);
      }
    }
    matches.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final start = cursor.clamp(0, matches.length);
    final end = (start + limit).clamp(start, matches.length);
    return matches.sublist(start, end).map(_resultFor).toList(growable: false);
  }

  Future<void> clear() async {
    _fieldsByMessageId.clear();
    _lastBuiltAt = null;
  }

  bool _matchesFilters(Message message, MessageSearchFilters filters) {
    if (filters.conversationId != null &&
        message.groupId != filters.conversationId) {
      return false;
    }
    if (filters.senderId != null && message.senderId != filters.senderId) {
      return false;
    }
    if (filters.from != null && message.timestamp.isBefore(filters.from!)) {
      return false;
    }
    if (filters.to != null && message.timestamp.isAfter(filters.to!)) {
      return false;
    }
    if (filters.mentionsOnly &&
        !message.isMention &&
        message.mentionedAiIds.isEmpty &&
        !message.content.contains('@')) {
      return false;
    }
    final attachmentType = filters.attachmentType;
    if (attachmentType != null &&
        !(message.media ?? const [])
            .any((attachment) => attachment.type == attachmentType)) {
      return false;
    }
    return true;
  }

  /// 一条消息参与匹配的全部字段。
  ///
  /// 正文走保守的 [PinyinMatchMode.content]，发送者 / 会话 / 附件名走宽松的
  /// [PinyinMatchMode.name]，因此模式按字段而不是按整条消息决定。
  List<PinyinField> _searchFields(Message message) => [
        (text: message.content, mode: PinyinMatchMode.content),
        for (final attachment in message.media ?? const <MediaAttachment>[])
          (
            text: attachment.fileName ??
                attachment.localPath.split(RegExp(r'[/\\]')).last,
            mode: PinyinMatchMode.name,
          ),
        (text: _senderName(message), mode: PinyinMatchMode.name),
        (
          text: _conversationName(message.groupId),
          mode: PinyinMatchMode.name,
        ),
      ];

  MessageSearchResult _resultFor(Message message) => MessageSearchResult(
        messageId: message.id,
        conversationId: message.groupId,
        conversationName: _conversationName(message.groupId),
        senderName: _senderName(message),
        timestamp: message.timestamp,
        snippet: _snippet(message),
      );

  String _conversationName(String conversationId) {
    final characterId = DirectChatSession.characterIdFrom(conversationId);
    if (characterId != null) {
      return '与 ${db.aiCharacterBox.get(characterId)?.name ?? '已删除角色'} 私聊';
    }
    return db.chatGroupBox.get(conversationId)?.name ?? conversationId;
  }

  String _senderName(Message message) {
    if (message.senderType == 'user') return '我';
    return db.aiCharacterBox.get(message.senderId)?.name ?? '已删除角色';
  }

  String _snippet(Message message) {
    final content = message.content.trim();
    if (content.isNotEmpty) {
      return content.length <= 140 ? content : '${content.substring(0, 140)}…';
    }
    final names = (message.media ?? const [])
        .map((item) => item.fileName ?? '附件')
        .join('、');
    return names.isEmpty ? '空消息' : '附件：$names';
  }
}
