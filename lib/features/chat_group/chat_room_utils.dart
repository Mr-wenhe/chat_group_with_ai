/// Pure utility functions extracted from `chat_room_page.dart`.
///
/// These functions have no dependency on Flutter widgets, BuildContext,
/// or page state — they are safe to unit-test directly.
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';

// ---------------------------------------------------------------------------
// Mention parsing
// ---------------------------------------------------------------------------

/// Inserts a mention without discarding the draft; only an active query is
/// replaced. Returns the new caret position beside the updated text.
({String text, int cursor}) insertMentionInDraft(
  String text,
  int cursor,
  String mention, {
  required bool replaceQuery,
}) {
  cursor = cursor < 0 ? text.length : cursor.clamp(0, text.length);
  final before = text.substring(0, cursor);
  final query = replaceQuery ? RegExp(r'@[^@\s]*$').firstMatch(before) : null;
  final start = query?.start ?? cursor;
  // Keep a token boundary, otherwise English drafts parse as email addresses.
  final prefix =
      start > 0 && _isMentionTokenCharacter(text[start - 1]) ? ' ' : '';
  final inserted = '$prefix$mention';
  return (
    text: text.replaceRange(start, cursor, inserted),
    cursor: start + inserted.length,
  );
}

/// The shared mention parser's diagnostic result.
///
/// Work-mode routing needs to distinguish an unknown name from an ambiguous
/// duplicate name. Keeping that information beside the existing parser avoids
/// a second, subtly different mention regular expression.
class MentionParseResult {
  final List<String> characterIds;
  final List<String> unknownNames;
  final List<String> ambiguousNames;
  final bool mentionsAll;

  const MentionParseResult({
    required this.characterIds,
    this.unknownNames = const [],
    this.ambiguousNames = const [],
    this.mentionsAll = false,
  });

  bool get hasExplicitMention =>
      mentionsAll ||
      characterIds.isNotEmpty ||
      unknownNames.isNotEmpty ||
      ambiguousNames.isNotEmpty;
}

/// Parses `@name` mentions in [content] against the given [characters].
///
/// Supports Chinese and English names, `@all` / `@everyone` / `@所有人` /
/// `@全部` as wildcard that expands to every character, and de-duplicates
/// results while preserving encounter order.
List<String> parseMentionedCharacterIds(
  String content,
  List<AICharacter> characters,
) =>
    analyzeMentionedCharacterIds(content, characters).characterIds;

/// Parses mentions once and exposes routing diagnostics to callers that need
/// to explain unknown or duplicate names to the user.
MentionParseResult analyzeMentionedCharacterIds(
  String content,
  List<AICharacter> characters,
) {
  final mentionedIds = <String>[];
  final unknownNames = <String>[];
  final ambiguousNames = <String>[];
  var mentionsAll = false;
  if (content.isEmpty) {
    return const MentionParseResult(characterIds: []);
  }

  final byName = <String, List<String>>{};
  for (final character in characters) {
    byName.putIfAbsent(character.name, () => <String>[]).add(character.id);
  }
  final mentionPattern = RegExp(r'@([^@\s，。！？!?、；;：:,.]+)');
  for (final match in mentionPattern.allMatches(content)) {
    // An email/domain is not a role mention. Keep this boundary in the shared
    // parser so every caller has the same behavior instead of adding a
    // work-mode-only regex exception.
    if (match.start > 0 && _isMentionTokenCharacter(content[match.start - 1])) {
      continue;
    }
    final rawName = match.group(1);
    final name =
        rawName == null ? null : resolveKnownMentionName(rawName, byName);
    if (name != null && isMentionAllToken(name)) {
      mentionsAll = true;
      for (final character in characters) {
        if (!mentionedIds.contains(character.id)) {
          mentionedIds.add(character.id);
        }
      }
      continue;
    }
    if (name == null) continue;
    final ids = byName[name] ?? const <String>[];
    if (ids.length > 1) {
      if (!ambiguousNames.contains(name)) ambiguousNames.add(name);
    } else if (ids.length == 1) {
      final id = ids.single;
      if (!mentionedIds.contains(id)) mentionedIds.add(id);
    } else if (!unknownNames.contains(name)) {
      unknownNames.add(name);
    }
  }
  return MentionParseResult(
    characterIds: List.unmodifiable(mentionedIds),
    unknownNames: List.unmodifiable(unknownNames),
    ambiguousNames: List.unmodifiable(ambiguousNames),
    mentionsAll: mentionsAll,
  );
}

/// Resolves exact names first and only consumes a known adjacent action.
String? resolveKnownMentionName(
  String token,
  Map<String, List<String>> knownNames,
) {
  if (knownNames.containsKey(token)) return token;
  if (isMentionAllToken(token)) return token;
  for (final alias in const ['all', 'everyone', '所有人', '全部']) {
    if (token.startsWith(alias) &&
        token.length > alias.length &&
        isMentionActionSuffix(token.substring(alias.length))) {
      return alias;
    }
  }
  final prefixed = knownNames.keys.where((name) {
    if (!token.startsWith(name) || token.length == name.length) return false;
    final suffix = token.substring(name.length);
    return isMentionActionSuffix(suffix);
  }).toList()
    ..sort((left, right) => right.length.compareTo(left.length));
  return prefixed.isEmpty ? token : prefixed.first;
}

/// Conservative boundary for Chinese mentions without a separating space.
/// Arbitrary Chinese suffixes may be part of an unknown person's full name.
bool isMentionActionSuffix(String value) => RegExp(
      r'^(?:这个方案|请|讨论|补充|输出|出具|交付|生成|制作|完成|负责|执行|评估|判断|分析|看看|审查|审核|评审|能否|是否|建议|说说|实现|写|先|再|总结)',
    ).hasMatch(value);

bool _isMentionTokenCharacter(String value) =>
    RegExp(r'^[A-Za-z0-9_./%+\-]$').hasMatch(value);

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
