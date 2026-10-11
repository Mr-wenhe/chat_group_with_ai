import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';

/// Stable identity for the hidden roundtable search assistant.
const roundtableNewsRoleId = 'builtin-roundtable-news';

class RoundtableNewsRoleMembership {
  final ChatGroup group;
  final AICharacter character;

  const RoundtableNewsRoleMembership({
    required this.group,
    required this.character,
  });
}

/// Adds the built-in news role to a group the first time roundtable mode is
/// enabled. It is a search-only member: no chat API config is required and
/// the room explicitly excludes it from every speaker selection path.
class RoundtableNewsRoleService {
  static Future<RoundtableNewsRoleMembership?> ensureForGroup(
    DatabaseService db,
    String groupId,
  ) async {
    final group = db.chatGroupBox.get(groupId);
    if (group == null) return null;

    var character = db.aiCharacterBox.get(roundtableNewsRoleId);
    if (character == null) {
      character = AICharacter(
        id: roundtableNewsRoleId,
        name: '新闻角色',
        avatar: '📰',
        age: 30,
        role: '圆桌会议联网搜索助手',
        personalityTags: const ['新闻', '实时搜索', '多源核验'],
        systemPrompt:
            '你是圆桌会议的幕后新闻检索助手。你不在群聊中发言，只处理用户输入，调用智谱原生网页搜索并把结构化结果提供给其他角色。',
        apiKey: '',
        apiProvider: ApiProvider.zhipu.name,
        modelName: 'glm-4.7',
        apiConfigId: '',
        agenticEnabled: false,
        webSearchEnabled: true,
        proactiveChatEnabled: false,
        zhipuSearchAnswerOnly: true,
      );
      await db.aiCharacterBox.put(character.id, character);
    }

    if (group.aiCharacterIds.contains(character.id)) {
      return RoundtableNewsRoleMembership(group: group, character: character);
    }
    final updated = ChatGroup(
      id: group.id,
      name: group.name,
      theme: group.theme,
      description: group.description,
      aiCharacterIds: [...group.aiCharacterIds, character.id],
      createdAt: group.createdAt,
      ownerName: group.ownerName,
      announcement: group.announcement,
      replyIntervalSeconds: group.replyIntervalSeconds,
    );
    await db.chatGroupBox.put(updated.id, updated);
    return RoundtableNewsRoleMembership(group: updated, character: character);
  }
}
