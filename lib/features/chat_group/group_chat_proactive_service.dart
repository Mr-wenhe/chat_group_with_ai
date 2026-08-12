import 'dart:math';
import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:chat_group/features/chat_group/group_chat_proactive_policy.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/observation_entry.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
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
  final AiRequestGateway gateway;
  final Random random;
  final ApiCredentialResolver credentialResolver;

  GroupChatProactiveService({
    required this.db,
    ChatApiService? chatApi,
    AiRequestGateway? gateway,
    Random? random,
    ApiCredentialResolver? credentialResolver,
  })  : gateway = gateway ??
            AiRequestGateway(
              store: AiGovernanceStore.forDatabase(db),
              client: chatApi,
            ),
        random = random ?? Random(),
        credentialResolver =
            credentialResolver ?? SecureApiCredentialResolver();

  Future<GroupChatProactiveResult?> tryCreateProactiveMessage({
    String? activeGroupId,
    String? preferredGroupId,
  }) async {
    final now = DateTime.now();
    final allCharacters = db.aiCharacterBox.values.toList();
    final characters = allCharacters
        .where((character) =>
            character.isActive && _canGenerateProactiveMessage(character))
        .toList();
    final groups = db.chatGroupBox.values.toList()..shuffle(random);
    final allMessages = db.messageBox.values.toList();
    final charactersById = {
      for (final character in allCharacters) character.id: character
    };
    final eligibleCharactersById = {
      for (final character in characters) character.id: character,
    };

    final candidate = GroupChatProactivePolicy.selectCandidate(
      groups: groups,
      charactersById: eligibleCharactersById,
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

    // 统一每小时发言预算：群聊主动消息与聊天内回复共用同一套额度判定与记用，
    // 避免角色在房内已触顶 hourlyLimit 仍被后台轮询频繁灌水。达到上限则跳过
    // 本次主动消息，绝不伪造发送。
    final eligibility =
        ReplyEligibilityPolicy(resolveApiConfig: _resolveApiConfig);
    if (eligibility.blockReasonFor(candidate.character) ==
        ReplyBlockReason.hourlyLimit) {
      return null;
    }

    final groupMessages = allMessages
        .where((message) => message.groupId == candidate.group.id)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final context = groupMessages.length > 12
        ? groupMessages.sublist(groupMessages.length - 12)
        : groupMessages;

    final messages = await _buildMessages(
      character: candidate.character,
      group: candidate.group,
      reason: candidate.reason,
      context: context,
      charactersById: charactersById,
    );
    final result = await gateway.sendChatMessage(
      apiKey: apiKey,
      provider: ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => ApiProvider.deepseek,
      ),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: messages,
      temperature: 0.85,
      purpose: AiRequestPurpose.proactive,
      conversationId: candidate.group.id,
      characterId: candidate.character.id,
    );
    if (!(result['success'] ?? false)) return null;
    final content = result['message']?.toString().trim() ?? '';
    if (content.isEmpty) return null;

    final visibleCharacters = candidate.group.aiCharacterIds
        .map((id) => charactersById[id])
        .whereType<AICharacter>()
        .where((character) => character.isActive)
        .toList(growable: false);
    final message = Message(
      groupId: candidate.group.id,
      senderId: candidate.character.id,
      senderType: 'ai',
      content: content,
      mentionedAiIds: parseMentionedCharacterIds(content, visibleCharacters),
      visibleToCharacterIds:
          visibleCharacters.map((character) => character.id).toList(),
    );
    await db.persistMessage(message);
    await db.saveGroupChatLastProactiveAt(candidate.group.id, now);
    // 记用：统一由数据库按角色串行写回，避免并发入口丢失增量。
    await db.recordCharacterReplyUsage(candidate.character.id);

    final observation = ObservationEntry(db: db);
    await observation.observeDeterministic(
      message: message,
      visibleCharacterIds: message.visibleToCharacterIds,
      conversationId: candidate.group.id,
      conversationNameSnapshot: candidate.group.name,
      allCharacters: allCharacters,
    );
    unawaited(observation
        .distillMessage(
          message: message,
          conversationId: candidate.group.id,
          conversationNameSnapshot: candidate.group.name,
          allCharacters: allCharacters,
          isGroupChat: true,
          userProfile: db.userProfileBox.get('me'),
        )
        .catchError((_) {}));
    await RelationshipEventService(db).observeProactiveMessage(
      message: message,
      conversationId: candidate.group.id,
      conversationNameSnapshot: candidate.group.name,
      allCharacters: allCharacters,
    );

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

  Future<List<Map<String, dynamic>>> _buildMessages({
    required AICharacter character,
    required ChatGroup group,
    required String reason,
    required List<Message> context,
    required Map<String, AICharacter> charactersById,
  }) async {
    String ownerName = '我';
    try {
      final profile = db.userProfileBox.get('me');
      if (profile?.displayName.trim().isNotEmpty ?? false) {
        ownerName = profile!.displayName.trim();
      }
    } on Object {
      // Box not yet opened in test environments; fall back to default.
    }
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

    // 统一全局记忆上下文。
    String permanentMemory = '';
    try {
      permanentMemory = await MemoryContextSelector(db).select(
        observerCharacterId: character.id,
        participantCharacterIds: group.aiCharacterIds,
        userMessage: context.isNotEmpty ? context.last.content : null,
      );
    } on Object {
      // Box not yet opened in test environments; skip memory injection.
    }

    return [
      {
        'role': 'system',
        'content': '你正在群聊「${group.name}」里，主题是「${group.theme}」。'
            '群主/真人用户叫「$ownerName」。'
            '现在由你主动在群里发一条自然消息。原因：$reason。'
            '像真实群友一样，可以接上之前的话题、抛一个轻问题，或点名其他 AI 成员。'
            '不要解释规则，不要说自己是 AI，不要带自己的名字前缀。'
            '${otherMembers.isEmpty ? '' : '其他 AI 成员：$otherMembers。'}',
      },
      {'role': 'system', 'content': character.rolePlaySystemPrompt},
      if (permanentMemory.isNotEmpty)
        {'role': 'system', 'content': permanentMemory},
      if (transcript.isNotEmpty)
        {'role': 'user', 'content': '最近群聊记录：\n$transcript'},
      {'role': 'user', 'content': '现在你主动在群里说一句。'},
    ];
  }
}
