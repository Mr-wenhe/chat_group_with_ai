/// Pure utility functions extracted from `chat_room_page.dart`.
///
/// These functions have no dependency on Flutter widgets, BuildContext,
/// or page state — they are safe to unit-test directly.
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';

// ---------------------------------------------------------------------------
// Mention parsing
// ---------------------------------------------------------------------------

/// Parses `@name` mentions in [content] against the given [characters].
///
/// Supports Chinese and English names, `@all` / `@everyone` / `@所有人` /
/// `@全部` as wildcard that expands to every character, and de-duplicates
/// results while preserving encounter order.
List<String> parseMentionedCharacterIds(
  String content,
  List<AICharacter> characters,
) {
  final mentionedIds = <String>[];
  if (characters.isEmpty || content.isEmpty) return mentionedIds;

  final byName = {for (final c in characters) c.name: c.id};
  final mentionPattern = RegExp(r'@([^@\s，。！？!?、；;：:,.]+)');
  for (final match in mentionPattern.allMatches(content)) {
    final name = match.group(1);
    if (name != null && isMentionAllToken(name)) {
      for (final character in characters) {
        if (!mentionedIds.contains(character.id)) {
          mentionedIds.add(character.id);
        }
      }
      continue;
    }
    final id = name == null ? null : byName[name];
    if (id != null && !mentionedIds.contains(id)) {
      mentionedIds.add(id);
    }
  }
  return mentionedIds;
}

/// Returns `true` when [token] is one of the recognised "mention everyone"
/// keywords: `all`, `everyone`, `所有人`, `全部`.
bool isMentionAllToken(String token) {
  final normalized = token.trim().toLowerCase();
  return normalized == 'all' ||
      normalized == 'everyone' ||
      normalized == '所有人' ||
      normalized == '全部';
}

// ---------------------------------------------------------------------------
// Duplicate reply detection
// ---------------------------------------------------------------------------

/// Detects exact/whitespace-only duplicate AI answers within the current user
/// exchange. The scan stops at the previous user message, so a natural short
/// phrase used again much later is not incorrectly suppressed.
bool isDuplicateAiReply(
  String content,
  List<Message> recentMessages, {
  String? excludeMessageId,
}) {
  String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').trim().toLowerCase();

  final candidate = normalize(content);
  if (candidate.isEmpty) return false;
  for (final message in recentMessages.reversed) {
    if (message.id == excludeMessageId) continue;
    if (message.senderType == 'user') break;
    if (message.senderType != 'ai') continue;
    if (normalize(message.content) == candidate) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Agent progress message
// ---------------------------------------------------------------------------

/// Builds a human-readable progress message for an agentic task in progress.
String agentProgressMessageContent({
  required String characterName,
  AgentRuntimeProgress? progress,
}) {
  if (progress == null) {
    return '🧭 $characterName 正在规划任务，接下来会持续汇报执行进度…';
  }
  if (progress.stage == AgentRuntimeProgressStage.waitingForApproval) {
    final tool = progress.pendingRequest?.tool.wireName ?? '工具操作';
    final path = progress.pendingRequest?.args['path']?.toString();
    return '⏳ $characterName 已完成规划，正在等待批准：$tool'
        '${path == null || path.isEmpty ? '' : '（$path）'}';
  }
  final count = progress.executedRequests.length;
  final latest =
      progress.executedRequests.isEmpty ? null : progress.executedRequests.last;
  final path = latest?.args['path']?.toString();
  final operation = latest?.tool.wireName ?? '工具操作';
  return '⚙️ $characterName 已完成第 $count 步：$operation'
      '${path == null || path.isEmpty ? '' : '（$path）'}，正在校验结果…';
}
