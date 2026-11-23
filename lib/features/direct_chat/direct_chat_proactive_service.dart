import '../../core/models/media_attachment.dart';
import '../../core/streaming/chat_stream_event.dart';
import '../web_search/desktop/desktop_web_service.dart';
import '../web_search/desktop/web_worker_client.dart';
import '../web_search/desktop/network_reply_stream.dart';
import '../web_search/application/autonomous_web_policy.dart';
import '../agentic/context_window_manager.dart';
import 'dart:math';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/observation_entry.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
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
    bool Function()? mayContinue,
  }) async {
    bool active() => mayContinue?.call() ?? true;
    if (!active()) return null;
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
    final latestVisibleUserMessageAt = <String, Map<String, DateTime>>{};
    for (final message in recentGroupMessages) {
      if (message.senderType != 'user') continue;
      final visibleIds = message.visibleToCharacterIds;
      // Legacy group messages have no recipient proof, so they must not
      // trigger a private conversation with any character.
      if (visibleIds.isEmpty) continue;
      final recipientIds = visibleIds;
      final groupTimestamps = latestVisibleUserMessageAt.putIfAbsent(
        message.groupId,
        () => <String, DateTime>{},
      );
      for (final characterId in recipientIds) {
        groupTimestamps.putIfAbsent(characterId, () => message.timestamp);
      }
    }
    final groupCandidates = <DirectChatGroupCandidate>[];
    for (final group in db.chatGroupBox.values) {
      for (final characterId in group.aiCharacterIds) {
        final character = charactersById[characterId];
        if (character == null || !_canGenerateProactiveMessage(character)) {
          continue;
        }
        final lastUserMessageAt =
            latestVisibleUserMessageAt[group.id]?[characterId];
        if (lastUserMessageAt == null) continue;
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
        ? const <Message>[]
        : recentGroupMessages
            .where((message) => message.groupId == candidate.sourceGroupId)
            .where((message) =>
                message.visibleToCharacterIds.isNotEmpty &&
                message.visibleToCharacterIds.contains(candidate.character.id))
            .take(8)
            .toList();

    final initialMessages = await _buildMessages(
      character: candidate.character,
      source: candidate.source,
      reason: candidate.reason,
      directContext: context,
      groupContext: sourceGroupContext,
    );
    final provider = ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => ApiProvider.deepseek);
    final capability = gateway.capability(provider, config.modelName);
    final outputTokens = capability.maxOutput
        .clamp(1, min(1024, max(1, capability.contextWindow)))
        .toInt();
    final downloads = <MediaAttachment>[];
    WebWorkerClient? worker;
    DesktopWebService? web;
    final cancelToken = CancelToken();
    final lifecycleGuard = mayContinue == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 100), (_) {
            if (!active() && !cancelToken.isCancelled) {
              cancelToken.cancel('App left foreground');
            }
          });
    Map<String, dynamic> result = {'success': false};
    Stream<ChatStreamEvent> generate(
        List<Map<String, dynamic>> messages) async* {
      if (!active()) return;
      final response = await gateway.sendChatMessage(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: config.protocol,
        customBaseUrl: config.customBaseUrl,
        userAgent: config.userAgent,
        model: config.modelName,
        messages: messages,
        temperature: 0.8,
        maxTokens: outputTokens,
        cancelToken: cancelToken,
        purpose: AiRequestPurpose.proactive,
        conversationId: conversationId,
        characterId: candidate.character.id,
      );

      if (response['success'] != true) {
        yield const ChatStreamEvent(
            type: ChatStreamEventType.error,
            message: '主动私聊生成失败。',
            sanitized: true);
        return;
      }
      yield ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: response['message']?.toString() ?? '');
    }

    try {
      Stream<ChatStreamEvent> stream = generate(initialMessages);
      if (WebWorkerClient.isSupported &&
          AutonomousWebPolicy.allows(
              candidate.character, AutonomousWebScene.directChat)) {
        worker = WebWorkerClient.bundled();
        web = DesktopWebService(worker);
        stream = networkReplyStream(
            messages: initialMessages,
            generate: generate,
            inputTokenBudget: ContextWindowManager.inputBudget(
                contextWindow: capability.contextWindow,
                maxOutput: outputTokens),
            maxToolCalls: networkReplyToolCallLimit,
            isRequired: (message) =>
                message['content'] == initialMessages.first['content'] ||
                message['content'] ==
                    candidate.character.rolePlaySystemPrompt ||
                message['content'] == initialMessages.last['content'] ||
                message['role'] == 'system' &&
                    (message['content'] as String).startsWith('这次由你主动发起私聊。'),
            service: web,
            downloadDirectory: () => db.mediaDir,
            isActive: active,
            onDownload: (receipt) => downloads.add(MediaAttachment(
                type: 'file',
                localPath: receipt['path'] as String,
                fileName: receipt['fileName'] as String,
                fileSize: receipt['byteLength'] as int)));
      }
      await for (final event in stream) {
        if (!active()) return null;
        if (event.type == ChatStreamEventType.done) {
          result = {'success': true, 'message': event.content};
        }
        if (event.type == ChatStreamEventType.error) return null;
      }
    } finally {
      lifecycleGuard?.cancel();
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('Proactive generation finished');
      }
      worker?.close();
    }
    if (!active()) return null;
    if (!(result['success'] ?? false)) return null;
    final content = result['message']?.toString().trim() ?? '';
    if (content.isEmpty) return null;

    final message = Message(
      groupId: conversationId,
      senderId: candidate.character.id,
      senderType: 'ai',
      content: content,
      media: downloads.isEmpty ? null : downloads,
      webSearchSnapshot:
          web?.hasEvidence == true ? web!.evidenceSnapshot() : null,
      visibleToCharacterIds: [candidate.character.id],
    );
    await db.persistMessage(message);
    await db.saveDirectChatSource(conversationId, candidate.source);
    await db.saveDirectChatLastProactiveAt(candidate.character.id, now);
    // 记用：统一由数据库按角色串行写回，避免并发入口丢失增量。
    await db.recordCharacterReplyUsage(candidate.character.id);

    final observation = ObservationEntry(db: db);
    await observation.observeDeterministic(
      message: message,
      visibleCharacterIds: message.visibleToCharacterIds,
      conversationId: conversationId,
      conversationNameSnapshot: '私聊',
      allCharacters: characters,
    );
    unawaited(observation
        .distillMessage(
          message: message,
          conversationId: conversationId,
          conversationNameSnapshot: '私聊',
          allCharacters: characters,
          isGroupChat: false,
          userProfile: db.userProfileBox.get('me'),
        )
        .catchError((_) {}));
    await RelationshipEventService(db).observeProactiveMessage(
      message: message,
      conversationId: conversationId,
      conversationNameSnapshot: '私聊',
      allCharacters: characters,
    );

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
    if (!character.proactiveChatEnabled) return false;
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
          ownerName: ownerName,
        ),
      },
      {'role': 'system', 'content': character.rolePlaySystemPrompt},
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
