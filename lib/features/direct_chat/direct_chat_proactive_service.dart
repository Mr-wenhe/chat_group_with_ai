import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_policy.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/services/chat_api_service.dart';

class DirectChatProactiveResult {
  final AICharacter character;
  final Message message;
  final DirectChatSource source;

  const DirectChatProactiveResult({
    required this.character,
    required this.message,
    required this.source,
  });
}

class DirectChatProactiveService {
  final DatabaseService db;
  final AiRequestGateway gateway;
  final Random random;
  final ApiCredentialResolver credentialResolver;

  DirectChatProactiveService({
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

  Future<DirectChatProactiveResult?> tryCreateProactiveMessage({
    String? preferredConversationId,
  }) async {
    final now = DateTime.now();
    final characters = db.aiCharacterBox.values.toList();
    final charactersById = {
      for (final character in characters) character.id: character
    };
    await db.ensureMessageIndex();
    final summaries = DirectChatInbox.buildIndexedSummaries(
      characters: characters,
      records: db.conversationSummaries(),
      messageById: db.messageBox.get,
      sourceByConversation: db.directChatSourceByConversation(),
    );
    final candidateSummaries = summaries
        .where((summary) => _canGenerateProactiveMessage(summary.character))
        .toList();

    final allMessages = db.messageBox.values.toList();
    final recentGroupMessages = allMessages
        .where((message) =>
            !DirectChatSession.isDirectConversationId(message.groupId))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final latestUserMessageAtByGroup = <String, DateTime>{};
    for (final message in recentGroupMessages) {
      if (message.senderType != 'user') continue;
      latestUserMessageAtByGroup.putIfAbsent(message.groupId, () {
        return message.timestamp;
      });
    }
    final groupCandidates = <DirectChatGroupCandidate>[];
    for (final group in db.chatGroupBox.values) {
      final lastUserMessageAt = latestUserMessageAtByGroup[group.id];
      if (lastUserMessageAt == null) continue;
      for (final characterId in group.aiCharacterIds) {
        final character = charactersById[characterId];
        if (character == null || !_canGenerateProactiveMessage(character)) {
          continue;
        }
        groupCandidates.add(DirectChatGroupCandidate(
          character: character,
          groupId: group.id,
          lastUserMessageAt: lastUserMessageAt,
        ));
      }
    }
    groupCandidates.shuffle(random);

    final candidate = DirectChatProactivePolicy.selectCandidate(
      directSummaries: candidateSummaries,
      groupCandidates: groupCandidates,
      idleCharacters: characters
          .where(_canGenerateProactiveMessage)
          .toList(growable: false),
      lastProactiveAtByCharacter: db.directChatLastProactiveAtByCharacter(),
      now: now,
      preferredConversationId: preferredConversationId,
    );
    if (candidate == null) return null;

    // 统一每小时发言预算：主动 DM 与聊天内回复共用同一套额度判定与记用，
    // 避免角色在房内已触顶 hourlyLimit 仍被前台轮询疯狂私聊。达到上限则跳过
    // 本次主动 DM，绝不伪造发送。
    final eligibility =
        ReplyEligibilityPolicy(resolveApiConfig: _resolveApiConfig);
    if (eligibility.blockReasonFor(candidate.character) ==
        ReplyBlockReason.hourlyLimit) {
      return null;
    }

    final config = _resolveApiConfig(candidate.character);
    if (config == null) return null;
    final apiKey = await credentialResolver.resolve(config);
    if (apiKey == null) return null;

    final conversationId =
        DirectChatSession.conversationIdFor(candidate.character.id);
    final directMessages = allMessages
        .where((message) => message.groupId == conversationId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final context = directMessages.length > 12
        ? directMessages.sublist(directMessages.length - 12)
        : directMessages;
    final sourceGroupContext = candidate.sourceGroupId == null
        ? recentGroupMessages.take(8).toList()
        : recentGroupMessages
            .where((message) => message.groupId == candidate.sourceGroupId)
            .take(8)
            .toList();

    final result = await gateway.sendChatMessage(
      apiKey: apiKey,
      provider: ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => ApiProvider.deepseek,
      ),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: await _buildMessages(
        character: candidate.character,
        source: candidate.source,
        reason: candidate.reason,
        directContext: context,
        groupContext: sourceGroupContext,
      ),
      temperature: 0.8,
      purpose: AiRequestPurpose.proactive,
      conversationId: conversationId,
      characterId: candidate.character.id,
    );
    if (!(result['success'] ?? false)) return null;
    final content = result['message']?.toString().trim() ?? '';
    if (content.isEmpty) return null;

    final message = Message(
      groupId: conversationId,
      senderId: candidate.character.id,
      senderType: 'ai',
      content: content,
    );
    await db.persistMessage(message);
    await db.saveDirectChatSource(conversationId, candidate.source);
    await db.saveDirectChatLastProactiveAt(candidate.character.id, now);
    // 记用：统一由数据库按角色串行写回，避免并发入口丢失增量。
    await db.recordCharacterReplyUsage(candidate.character.id);

    return DirectChatProactiveResult(
      character: candidate.character,
      message: message,
      source: candidate.source,
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
    required DirectChatSource source,
    required String reason,
    required List<Message> directContext,
    required List<Message> groupContext,
  }) async {
    final contextLines = <String>[];
    for (final message in directContext) {
      final speaker = message.senderType == 'user' ? '我' : character.name;
      contextLines.add('$speaker：${message.content}');
    }
    final groupLines = <String>[];
    for (final message in groupContext) {
      if (message.senderType == 'user') {
        groupLines.add('我在群里说：${message.content}');
      }
    }
    final sourceText = source == DirectChatSource.group
        ? '你是从刚才群聊话题自然延伸过来私聊。'
        : directContext.isEmpty
            ? '你自然想到用户，决定第一次主动私聊问候。'
            : '你是延续之前的私聊来主动联系。';

    // 用全局记忆选择器替代旧 memorySummary 旁路。
    final selector = MemoryContextSelector(db);
    String permanentMemory = '';
    try {
      permanentMemory = await selector.select(
        observerCharacterId: character.id,
        participantCharacterIds: [character.id],
        currentTargetId: 'user',
      );
    } on Object {
      // Box not yet opened in test environments; skip memory injection.
    }

    String ownerName = '我';
    try {
      final profile = db.userProfileBox.get('me');
      if (profile?.displayName.trim().isNotEmpty ?? false) {
        ownerName = profile!.displayName.trim();
      }
    } on Object {
      // Box not yet opened in test environments; fall back to default.
    }

    return [
      {
        'role': 'system',
        'content': DirectChatSession.buildPromptContext(
          character: character,
          ownerName: ownerName,
        ),
      },
      {'role': 'system', 'content': character.systemPrompt},
      if (permanentMemory.isNotEmpty)
        {'role': 'system', 'content': permanentMemory},
      {
        'role': 'system',
        'content': '这次由你主动发起私聊。$sourceText'
            '原因：$reason。'
            '只发一条自然的开场消息，1-2 句，像真实联系人突然想起这件事来找我。'
            '不要解释规则，不要说”系统让我”。',
      },
      if (contextLines.isNotEmpty)
        {'role': 'user', 'content': '最近私聊：\n${contextLines.join('\n')}'},
      if (groupLines.isNotEmpty)
        {'role': 'user', 'content': '最近群聊里和我相关的话题：\n${groupLines.join('\n')}'},
      {'role': 'user', 'content': '现在你主动发来一条私聊消息。'},
    ];
  }
}
