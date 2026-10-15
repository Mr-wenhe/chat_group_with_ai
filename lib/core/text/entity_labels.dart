import 'package:hive/hive.dart';

import '../database/database_service.dart';
import '../models/ai_character.dart';
import '../models/api_config.dart';
import '../models/chat_group.dart';

/// 把一个实体 id 解析成人话标签；返回 null 表示「这个 id 不归我管」。
///
/// 刻意不返回兜底文案：解析器无法区分「不是我的 id」与「是我的 id 但实体已删除」，
/// 兜底一律由 [EntityLabels] 统一给出，否则每个解析器都会各自造一套未知文案。
typedef EntityIdResolver = String? Function(String id);

/// 反显期把实体 id 换成人话标签。
///
/// 只用于显示：状态、事件、检查点、导出与模型提示词必须继续存 id —— 决策身份
/// （如 `decision.reason`）参与去重比较，把名字写进状态会让同一问题在角色改名后
/// 生成第二条决策。
class EntityLabels {
  EntityLabels({required List<EntityIdResolver> resolvers})
      : _resolvers = List<EntityIdResolver>.unmodifiable(resolvers);

  factory EntityLabels.from(
    DatabaseService database, {
    List<EntityIdResolver> domainResolvers = const <EntityIdResolver>[],
  }) {
    return EntityLabels(
      resolvers: <EntityIdResolver>[
        memberResolver(database.aiCharacterBox),
        conversationResolver(database.chatGroupBox, database.aiCharacterBox),
        apiConfigResolver(database.apiConfigBox),
        ...domainResolvers,
      ],
    );
  }

  /// 测试与无库场景：不做任何实体解析，未认领的 id 一律压短码。
  factory EntityLabels.none() =>
      EntityLabels(resolvers: const <EntityIdResolver>[]);

  factory EntityLabels.fixed(Map<String, String> labels) => EntityLabels(
        resolvers: <EntityIdResolver>[
          (id) => labels[id],
        ],
      );

  final List<EntityIdResolver> _resolvers;

  static const String unknownEntity = '未知对象';

  /// 文本中出现的 36 位 UUID。带边界，避免把更长串里的片段当成 id。
  static final RegExp uuidToken = RegExp(
    r'(?<![0-9a-zA-Z])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-zA-Z])',
  );

  /// 整串就是一个 UUID（沿用 `memory_audit_presenter` 的既有判据）。
  static final RegExp _uuidWhole = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  String labelFor(String id) =>
      resolveOrNull(id) ?? '$unknownEntity（${shortCode(id)}）';

  /// 只解析、不兜底：调用方需要区分「没有标签」与「标签是空的」时用它。
  String? resolveOrNull(String id) {
    for (final resolver in _resolvers) {
      final label = resolver(id)?.trim() ?? '';
      if (label.isNotEmpty) return label;
    }
    return null;
  }

  /// 扫描文本里的 UUID 并逐个换成人话；无 token 时原样返回。
  ///
  /// `dm:<characterId>` 整体认作会话 id —— 只替换后半段会把前缀留成孤儿 `dm:`。
  String humanize(String text) {
    if (text.isEmpty || !uuidToken.hasMatch(text)) return text;
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in uuidToken.allMatches(text)) {
      var start = match.start;
      final raw = match.group(0)!;
      final isDirect = start >= 3 && text.startsWith('dm:', start - 3);
      if (isDirect) start -= 3;
      buffer.write(text.substring(cursor, start));
      buffer.write(labelFor(isDirect ? 'dm:$raw' : raw));
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    return buffer.toString();
  }

  static String shortCode(String id) {
    final raw = id.startsWith('dm:') ? id.substring(3) : id;
    return raw.length <= 8 ? raw : raw.substring(0, 8);
  }
}

bool looksLikeUuid(String value) =>
    EntityLabels._uuidWhole.hasMatch(value.trim());

EntityIdResolver memberResolver(Box<AICharacter> box) =>
    (id) => box.get(id)?.name;

/// 群会话取群名；`dm:<characterId>` 是私聊，名字来自**角色**箱而不是群箱
/// （先例：`global_search_page.dart:363` 与 `message_search_index.dart:218`）。
EntityIdResolver conversationResolver(
  Box<ChatGroup> groups,
  Box<AICharacter> characters,
) {
  return (id) {
    if (id.startsWith('dm:')) {
      final name = characters.get(id.substring(3))?.name;
      return name == null || name.trim().isEmpty ? null : '与「$name」的私聊';
    }
    final group = groups.get(id);
    return group == null ? null : '「${group.name}」';
  };
}

EntityIdResolver apiConfigResolver(Box<ApiConfig> box) => (id) => box.get(id)?.name;
