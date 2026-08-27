/// Pure utility functions extracted from `chat_room_page.dart`.
///
/// These functions have no dependency on Flutter widgets, BuildContext,
/// or page state — they are safe to unit-test directly.
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
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

/// 构建 AI 角色任务执行进度文案。
///
/// - [progress] 为 null：保持旧兼容行为，输出单句「规划中」。
/// - 工作模式：输出多行累积式步骤日志：
///   首行头部（执行中 / 已完成 / 失败）→ 已完成行（✅，由 [AgentRuntimeProgress.executedRequests] 派生）
///   → 当前行（⏳，由 stage + [AgentRuntimeProgress.currentStepLabel] 生成）。
/// - [finalResult] 为 true：末行转为 ✅（去光标），作为终态摘要。
String agentProgressMessageContent({
  required String characterName,
  AgentRuntimeProgress? progress,
  bool finalResult = false,
  int? elapsedSeconds,
}) {
  // 非工作模式 / 旧路径：单句「规划中」，行为保持不变。
  if (progress == null) {
    return '🧭 $characterName 正在规划任务，接下来会持续汇报执行进度…';
  }

  final stage = progress.stage;
  final isToolCompleted = stage == AgentRuntimeProgressStage.toolCompleted;

  // 终态且携带冻结耗时：在首行头部之后追加「⏱ {formatElapsed}」，
  // 使已完成任务气泡保持展示冻结耗时（即便 _progressStartTimes 已清理、
  // 进度气泡不再 live 计算耗时）。非终态路径不受影响（elapsedSeconds 默认 null）。
  final elapsedSuffix = (finalResult && elapsedSeconds != null)
      ? ' ⏱ ${formatElapsed(elapsedSeconds)}'
      : '';

  final lines = <String>[
    statusHeader(
          characterName,
          isFinal: finalResult,
          failed: stage == AgentRuntimeProgressStage.stepFailed,
        ) +
        elapsedSuffix,
  ];

  // ✅ 已完成步骤行：由 executedRequests 派生（进度消息不重复计数）。
  for (final request in progress.executedRequests) {
    // P2：依据工具类型追加批准态文案（需批准 / 自动）。
    final needsApproval = AgentRuntime.requiresApproval(request.tool);
    final tag = needsApproval ? approvalTag : autoTag;
    lines.add('$stepPrefixDone ${completedStepLabel(request)}$tag');
  }

  // 当前行（⏳）：非聚合刷新（toolCompleted）时展示；finalResult 时转为 ✅ 去光标。
  final label = progress.currentStepLabel ?? stageLabelFallback[stage] ?? '';
  if (label.isNotEmpty && !isToolCompleted) {
    final prefix = finalResult ? stepPrefixDone : stepPrefixActive;
    lines.add('$prefix $label');
  }

  return lines.join('\n');
}
