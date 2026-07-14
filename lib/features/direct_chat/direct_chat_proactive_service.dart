import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
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
  final ChatApiService chatApi;
  final Random random;

  DirectChatProactiveService({
    required this.db,
    ChatApiService? chatApi,
    Random? random,
  })  : chatApi = chatApi ?? ChatApiService(),
        random = random ?? Random();

  Future<DirectChatProactiveResult?> tryCreateProactiveMessage({
    String? preferredConversationId,
  }) async {
    final now = DateTime.now();
    final characters = db.aiCharacterBox.values.toList();
    final charactersById = {
      for (final character in characters) character.id: character
    };
    final allMessages = db.messageBox.values.toList();
    final summaries = DirectChatInbox.buildSummaries(
      characters: characters,
      messages: allMessages,
      readAtByConversation: db.directChatReadAtByConversation(),
      sourceByConversation: db.directChatSourceByConversation(),
    );
    final candidateSummaries = summaries
        .where((summary) => _canGenerateProactiveMessage(summary.character))
        .toList();

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
      idleCharacters:
          characters.where(_canGenerateProactiveMessage).toList(growable: false),
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
    if (config == null || config.apiKey.isEmpty) return null;

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

    final result = await chatApi.sendChatMessage(
      apiKey: config.apiKey,
      provider: ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => ApiProvider.deepseek,
      ),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: _buildMessages(
        character: candidate.character,
        source: candidate.source,
        reason: candidate.reason,
        directContext: context,
        groupContext: sourceGroupContext,
      ),
      temperature: 0.8,
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
    await db.messageBox.put(message.id, message);
    await db.addMessageToGroupIndex(message);
    await db.saveDirectChatSource(conversationId, candidate.source);
    await db.saveDirectChatLastProactiveAt(candidate.character.id, now);
    await _recordUsage(candidate.character, conversationId, result);
    // 记用：与聊天走同一套每小时额度累计。先从盒里取最新对象再累加，
    // 避免用方法入口的旧快照覆盖聊天室内已持久化的并发增量（lost-update）。
    final latest = db.aiCharacterBox.get(candidate.character.id) ?? candidate.character;
    eligibility.recordReplyUsage(latest);
    await db.aiCharacterBox.put(latest.id, latest);

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
    if (character.apiKey.isNotEmpty && character.apiProvider.isNotEmpty) {
      return ApiConfig(
        id: 'legacy_${character.id}',
        name: '${character.name} 原有配置',
        provider: character.apiProvider,
        modelName: character.modelName,
        apiKey: character.apiKey,
        customBaseUrl: character.customBaseUrl,
      );
    }
    return null;
  }

  bool _canGenerateProactiveMessage(AICharacter character) {
    final config = _resolveApiConfig(character);
    return config != null && config.apiKey.isNotEmpty;
  }

  List<Map<String, dynamic>> _buildMessages({
    required AICharacter character,
    required DirectChatSource source,
    required String reason,
    required List<Message> directContext,
    required List<Message> groupContext,
  }) {
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

    final persistentMemory =
        DirectChatSession.persistentMemoryPrompt(character);

    return [
      {
        'role': 'system',
        'content': DirectChatSession.buildPromptContext(
          character: character,
          ownerName: '我',
        ),
      },
      {'role': 'system', 'content': character.systemPrompt},
      if (persistentMemory.isNotEmpty)
        {'role': 'system', 'content': persistentMemory},
      {
        'role': 'system',
        'content': '这次由你主动发起私聊。$sourceText'
            '原因：$reason。'
            '只发一条自然的开场消息，1-2 句，像真实联系人突然想起这件事来找我。'
            '不要解释规则，不要说“系统让我”。',
      },
      if (contextLines.isNotEmpty)
        {'role': 'user', 'content': '最近私聊：\n${contextLines.join('\n')}'},
      if (groupLines.isNotEmpty)
        {'role': 'user', 'content': '最近群聊里和我相关的话题：\n${groupLines.join('\n')}'},
      {'role': 'user', 'content': '现在你主动发来一条私聊消息。'},
    ];
  }

  Future<void> _recordUsage(
    AICharacter character,
    String conversationId,
    Map<String, dynamic> result,
  ) async {
    final promptTokens = result['promptTokens'];
    final completionTokens = result['completionTokens'];
    if (promptTokens is! int || completionTokens is! int) return;
    await db.recordTokenUsage(
      characterId: character.id,
      groupId: conversationId,
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cachedTokens: result['cachedTokens'] is int ? result['cachedTokens'] : 0,
    );
  }
}
