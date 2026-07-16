import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/chat_group/group_chat_proactive_policy.dart';
import 'package:chat_group/services/chat_api_service.dart';

class GroupChatProactiveResult {
  final ChatGroup group;
  final AICharacter character;
  final Message message;

  const GroupChatProactiveResult({
    required this.group,
    required this.character,
    required this.message,
  });
}

class GroupChatProactiveService {
  final DatabaseService db;
  final ChatApiService chatApi;
  final Random random;
  final ApiCredentialResolver credentialResolver;

  GroupChatProactiveService({
    required this.db,
    ChatApiService? chatApi,
    Random? random,
    ApiCredentialResolver? credentialResolver,
  })  : chatApi = chatApi ?? ChatApiService(),
        random = random ?? Random(),
        credentialResolver =
            credentialResolver ?? SecureApiCredentialResolver();

  Future<GroupChatProactiveResult?> tryCreateProactiveMessage({
    String? activeGroupId,
    String? preferredGroupId,
  }) async {
    final now = DateTime.now();
    final characters =
        db.aiCharacterBox.values.where(_canGenerateProactiveMessage).toList();
    final groups = db.chatGroupBox.values.toList()..shuffle(random);
    final allMessages = db.messageBox.values.toList();
    final charactersById = {
      for (final character in characters) character.id: character
    };

    final candidate = GroupChatProactivePolicy.selectCandidate(
      groups: groups,
      charactersById: charactersById,
      messages: allMessages,
      readAtByGroup: db.groupChatReadAtByGroup(),
      lastProactiveAtByGroup: db.groupChatLastProactiveAtByGroup(),
      now: now,
      activeGroupId: activeGroupId,
      preferredGroupId: preferredGroupId,
    );
    if (candidate == null) return null;

    final config = _resolveApiConfig(candidate.character);
    if (config == null) return null;
    final apiKey = await credentialResolver.resolve(config);
    if (apiKey == null) return null;

    final groupMessages = allMessages
        .where((message) => message.groupId == candidate.group.id)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final context = groupMessages.length > 12
        ? groupMessages.sublist(groupMessages.length - 12)
        : groupMessages;

    final result = await chatApi.sendChatMessage(
      apiKey: apiKey,
      provider: ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => ApiProvider.deepseek,
      ),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: _buildMessages(
        character: candidate.character,
        group: candidate.group,
        reason: candidate.reason,
        context: context,
        charactersById: charactersById,
      ),
      temperature: 0.85,
    );
    if (!(result['success'] ?? false)) return null;
    final content = result['message']?.toString().trim() ?? '';
    if (content.isEmpty) return null;

    final message = Message(
      groupId: candidate.group.id,
      senderId: candidate.character.id,
      senderType: 'ai',
      content: content,
    );
    await db.persistMessage(message);
    await db.saveGroupChatLastProactiveAt(candidate.group.id, now);
    await _recordUsage(candidate.character, candidate.group.id, result);

    return GroupChatProactiveResult(
      group: candidate.group,
      character: candidate.character,
      message: message,
    );
  }

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      final config = db.apiConfigBox.get(character.apiConfigId);
      if (config != null) return config;
    }
    return null;
  }

  bool _canGenerateProactiveMessage(AICharacter character) {
    final config = _resolveApiConfig(character);
    return config?.hasCredential == true;
  }

  List<Map<String, dynamic>> _buildMessages({
    required AICharacter character,
    required ChatGroup group,
    required String reason,
    required List<Message> context,
    required Map<String, AICharacter> charactersById,
  }) {
    final ownerName =
        group.ownerName.trim().isEmpty ? '我' : group.ownerName.trim();
    final transcript = context.map((message) {
      final speaker = message.senderType == 'user'
          ? ownerName
          : charactersById[message.senderId]?.name ?? '某个群友';
      return '$speaker：${message.content}';
    }).join('\n');
    final otherMembers = group.aiCharacterIds
        .where((id) => id != character.id)
        .map((id) => charactersById[id]?.name)
        .whereType<String>()
        .join('、');

    return [
      {
        'role': 'system',
        'content': '你是${character.name}，${character.age}岁，身份是${character.role}。'
            '你正在群聊「${group.name}」里，主题是「${group.theme}」。'
            '群主/真人用户叫「$ownerName」。'
            '现在由你主动在群里发一条自然消息。原因：$reason。'
            '像真实群友一样，可以接上之前的话题、抛一个轻问题，或点名其他 AI 成员。'
            '不要解释规则，不要说自己是 AI，不要带自己的名字前缀。'
            '${otherMembers.isEmpty ? '' : '其他 AI 成员：$otherMembers。'}',
      },
      {'role': 'system', 'content': character.systemPrompt},
      if (transcript.isNotEmpty)
        {'role': 'user', 'content': '最近群聊记录：\n$transcript'},
      {'role': 'user', 'content': '现在你主动在群里说一句。'},
    ];
  }

  Future<void> _recordUsage(
    AICharacter character,
    String groupId,
    Map<String, dynamic> result,
  ) async {
    final promptTokens = result['promptTokens'];
    final completionTokens = result['completionTokens'];
    if (promptTokens is! int || completionTokens is! int) return;
    await db.recordTokenUsage(
      characterId: character.id,
      groupId: groupId,
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cachedTokens: result['cachedTokens'] is int ? result['cachedTokens'] : 0,
    );
  }
}
