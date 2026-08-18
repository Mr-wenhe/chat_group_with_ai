import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/observation_entry.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/relationship_controls.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';
import 'helpers/capturing_chat_api_service.dart';

class TestMemoryCredentialResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'sk-test';
}

class BlockingRelationshipEventService extends RelationshipEventService {
  BlockingRelationshipEventService(super.db);

  final Completer<void> gate = Completer<void>();
  int calls = 0;
  final bystanderFlags = <bool>[];

  @override
  Future<bool> observeAndApply({
    required String sourceCharacterId,
    required String targetId,
    required RelationshipTargetType targetType,
    required Message message,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
    UserMessageSentiment? userSentiment,
    bool isBystander = false,
  }) async {
    calls++;
    bystanderFlags.add(isBystander);
    await gate.future;
    return true;
  }
}

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory));

  AICharacter makeChar(String id) => testCharacter(id, apiConfigId: 'cfg_$id');

  Message makeMsg({
    required String senderType,
    String senderId = 'user',
    String groupId = 'g1',
    String content = 'test',
  }) =>
      Message(
        groupId: groupId,
        senderId: senderId,
        senderType: senderType,
        content: content,
      );

  List<AICharacter> charList(List<String> ids) =>
      ids.map((id) => makeChar(id)).toList();

  group('Stage 07: observer scope and message visibility', () {
    test('deterministic boundary persists local state before distillation',
        () async {
      final chars = charList(['a1']);
      final message = makeMsg(
        senderType: 'user',
        content: '永久记住我喜欢红茶',
      );
      final entry = ObservationEntry(db: db);

      await entry.observeDeterministic(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
      );

      expect(db.permanentMemoryBox.values.single.pinned, isTrue);
      expect(db.relationshipEventBox.values.single.sourceCharacterId, 'a1');
      expect(entry.loadRetryQueue(), isEmpty);

      await entry.distillMessage(
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );
      expect(entry.loadRetryQueue(), hasLength(1));
    });

    test('group chat message visible to all active members', () async {
      final chars = charList(['a1', 'a2', 'a3']);
      for (final c in chars) {
        await db.aiCharacterBox.put(c.id, c);
      }
      await db.chatGroupBox.put(
          'g1',
          ChatGroup(
            id: 'g1',
            name: 'TestGroup',
            theme: 'daily',
            aiCharacterIds: chars.map((c) => c.id).toList(),
          ));

      final message = makeMsg(senderType: 'user', content: 'hello everyone');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1', 'a2', 'a3'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      expect(message.visibleToCharacterIds, ['a1', 'a2', 'a3']);
    });

    test('DM message only visible to target AI', () async {
      final chars = charList(['a1']);
      for (final c in chars) {
        await db.aiCharacterBox.put(c.id, c);
      }

      final message = makeMsg(
          senderType: 'user',
          senderId: 'user',
          groupId: 'dm:a1',
          content: 'secret');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'dm:a1',
        conversationNameSnapshot: 'DM',
        allCharacters: chars,
        isGroupChat: false,
      );

      expect(message.visibleToCharacterIds, ['a1']);
    });

    test('A cannot know user-B DM', () async {
      final charA = makeChar('a1');
      final charB = makeChar('a2');
      await db.aiCharacterBox.put('a1', charA);
      await db.aiCharacterBox.put('a2', charB);

      final dmMsg = makeMsg(
        senderType: 'user',
        groupId: 'dm:a2',
        content: 'our secret conversation',
      );
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: dmMsg,
        visibleCharacterIds: ['a2'],
        conversationId: 'dm:a2',
        conversationNameSnapshot: 'DM',
        allCharacters: [charA, charB],
        isGroupChat: false,
      );

      final a1Memories = db.permanentMemoryBox.values
          .where((m) => m.observerCharacterId == 'a1')
          .toList();
      expect(a1Memories, isEmpty);
    });

    test('empty message does not enter observation', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: '');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      expect(db.permanentMemoryBox.length, 0);
    });

    test('user message creates AI to user relationship event', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: '你这个垃圾AI');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final event = db.relationshipEventBox.values.single;
      expect(event.sourceCharacterId, 'a1');
      expect(event.targetId, 'user');
      expect(event.frictionAfter, greaterThan(event.frictionBefore));
    });
  });

  group('deterministic triggers', () {
    test('"remember" keyword triggers forced memory', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: '记住我喜欢吃辣');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final memories = db.permanentMemoryBox.values
          .where((m) => m.observerCharacterId == 'a1')
          .toList();
      expect(memories.length, 1);
      expect(memories.first.kind, MemoryKind.explicitInstruction);
      expect(memories.first.explicitlyRequested, isTrue);
      expect(memories.first.pinned, isTrue);
      expect(memories.first.content, contains('喜欢吃辣'));
      expect(memories.first.subjectIds, ['user']);
    });

    test('"forget" keyword invalidates related memories', () async {
      final chars = charList(['a1']);

      await db.permanentMemoryBox.put(
          'old_1',
          PermanentMemory(
            id: 'old_1',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢吃辣',
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old_msg'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      final message = makeMsg(senderType: 'user', content: '忘记用户喜欢吃辣这件事');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final activeMemories = db.permanentMemoryBox.values
          .where((m) =>
              m.observerCharacterId == 'a1' && m.status == MemoryStatus.active)
          .toList();
      expect(activeMemories, isEmpty);
    });

    test('empty forget content does not invalidate all memories', () async {
      for (final item in [
        ('memory_a', '用户喜欢吃辣'),
        ('memory_b', '用户喜欢徒步'),
      ]) {
        await db.permanentMemoryBox.put(
          item.$1,
          PermanentMemory(
            id: item.$1,
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: item.$2,
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: [item.$1],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ),
        );
      }

      await ObservationEntry(db: db).observeMessage(
        message: makeMsg(senderType: 'user', content: '忘记'),
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a1']),
        isGroupChat: true,
      );

      expect(
        db.permanentMemoryBox.values,
        everyElement(predicate<PermanentMemory>(
          (memory) => memory.status == MemoryStatus.active,
        )),
      );
    });

    test('forget matches normalized user references', () async {
      await db.permanentMemoryBox.put(
        'normalized',
        PermanentMemory(
          id: 'normalized',
          observerCharacterId: 'a1',
          kind: MemoryKind.preference,
          content: '用户喜欢吃辣',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: 'TestGroup',
          sourceMessageIds: ['old'],
          participantIds: ['a1'],
          occurredAt: DateTime.now(),
        ),
      );

      await ObservationEntry(db: db).observeMessage(
        message: makeMsg(senderType: 'user', content: '忘记我喜欢吃辣'),
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a1']),
        isGroupChat: true,
      );

      expect(
        db.permanentMemoryBox.get('normalized')!.status,
        MemoryStatus.invalidated,
      );
    });

    test('casual chat does not trigger memory', () async {
      final chars = charList(['a1']);
      final message =
          makeMsg(senderType: 'user', content: 'nice weather today');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      expect(db.permanentMemoryBox.length, 0);
    });

    test('"permanent" keyword triggers forced memory', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: '永久记住我的生日是5月20日');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final memories = db.permanentMemoryBox.values
          .where((m) => m.observerCharacterId == 'a1')
          .toList();
      expect(memories.length, 1);
      expect(memories.first.kind, MemoryKind.explicitInstruction);
    });

    test('emotional turn enters retry queue when no API', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: '你太让我愤怒了，你这个垃圾AI');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final raw = db.appSettingsBox.get('memory_retry_queue_v1');
      expect(raw, isNotNull);
      expect((raw as List).isNotEmpty, isTrue);
    });
  });

  group('real LLM distillation path', () {
    Future<void> seedConfig(String id) async {
      await db.apiConfigBox.put(
        id,
        ApiConfig(
          id: id,
          name: id,
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
        ),
      );
    }

    test('AI message prompt keeps the real speaker and subject ID', () async {
      final chars = charList(['a', 'b']);
      for (final character in chars) {
        await db.aiCharacterBox.put(character.id, character);
        await seedConfig(character.apiConfigId);
      }
      final chatApi = CapturingChatApiService(
        responseText:
            '[{"kind":"fact","content":"B喜欢爬山","subjectIds":["b"],"importance":80,"confidence":0.9}]',
      );
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '我叫A，我喜欢爬山',
      )..visibleToCharacterIds = ['a', 'b'];

      await ObservationEntry(
        db: db,
        chatApi: chatApi,
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: message,
        visibleCharacterIds: message.visibleToCharacterIds,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final promptContents = chatApi.messageCalls
          .map((call) => call[1]['content'] as String)
          .toList();
      expect(
        promptContents,
        everyElement(contains('实际发言者是角色a（ID:a）')),
      );
      expect(
        promptContents,
        everyElement(contains('角色a → a')),
      );
      expect(promptContents, everyElement(contains('AI 发言情感分析')));
      expect(promptContents, everyElement(isNot(contains('用户情感分析'))));
      final bMemory = db.permanentMemoryBox.values.firstWhere(
        (memory) => memory.observerCharacterId == 'b',
      );
      expect(bMemory.subjectIds, ['b']);
      expect(bMemory.subjectIds, isNot(contains('a')));
    });

    test('group AI messages are distilled for other visible AI observers',
        () async {
      final chars = charList(['a', 'b']);
      for (final character in chars) {
        await db.aiCharacterBox.put(character.id, character);
        await seedConfig(character.apiConfigId);
      }
      final chatApi = CapturingChatApiService(
        responseText:
            '[{"kind":"sharedExperience","content":"角色a邀请大家下班后一起跑步","subjectIds":["a"],"importance":70,"confidence":0.9}]',
      );
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '下班后一起去跑步吧？',
      )..visibleToCharacterIds = ['a', 'b'];

      await ObservationEntry(
        db: db,
        chatApi: chatApi,
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: message,
        visibleCharacterIds: message.visibleToCharacterIds,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      expect(chatApi.sendCount, 2);
      expect(
        db.permanentMemoryBox.values.any(
          (memory) =>
              memory.observerCharacterId == 'b' &&
              memory.subjectIds.contains('a'),
        ),
        isTrue,
      );
    });

    test('ordinary preference messages enter LLM distillation', () async {
      final character = makeChar('a');
      await db.aiCharacterBox.put(character.id, character);
      await seedConfig(character.apiConfigId);
      final chatApi = CapturingChatApiService(
        responseText:
            '[{"kind":"preference","content":"用户喜欢喝乌龙茶","subjectIds":["user"],"importance":80,"confidence":1}]',
      );

      await ObservationEntry(
        db: db,
        chatApi: chatApi,
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: makeMsg(senderType: 'user', content: '我喜欢喝乌龙茶'),
        visibleCharacterIds: ['a'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: [character],
        isGroupChat: true,
      );

      expect(chatApi.sendCount, 1);
      expect(
        db.permanentMemoryBox.values.map((memory) => memory.content),
        contains('用户喜欢喝乌龙茶'),
      );
      final memory = db.permanentMemoryBox.values.single;
      expect(memory.importance, 80);
      expect(memory.confidence, 1.0);
    });

    test('explicit memory normalization supersedes the stable pinned record',
        () async {
      final character = makeChar('a');
      await db.aiCharacterBox.put(character.id, character);
      await seedConfig(character.apiConfigId);
      final chatApi = CapturingChatApiService(
        responseText:
            '[{"kind":"preference","content":"用户喜欢吃辣","subjectIds":["user"],"importance":90,"confidence":0.95}]',
      );
      final message = makeMsg(
        senderType: 'user',
        content: '记住我喜欢吃辣',
      );

      await ObservationEntry(
        db: db,
        chatApi: chatApi,
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: message,
        visibleCharacterIds: ['a'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: [character],
        isGroupChat: true,
      );

      final memories = db.permanentMemoryBox.values
          .where((memory) => memory.observerCharacterId == 'a')
          .toList();
      final explicit = memories.firstWhere(
        (memory) => memory.kind == MemoryKind.explicitInstruction,
      );
      final normalized = memories.firstWhere(
        (memory) => memory.kind == MemoryKind.preference,
      );
      expect(explicit.pinned, isTrue);
      expect(explicit.status, MemoryStatus.active);
      expect(normalized.status, MemoryStatus.active);
      expect(normalized.pinned, isTrue);
      expect(normalized.explicitlyRequested, isTrue);
      expect(normalized.supersedesIds, contains(explicit.id));

      final context = await MemoryContextSelector(db).select(
        observerCharacterId: 'a',
        participantCharacterIds: ['a'],
        userMessage: '吃辣',
      );
      expect(context, contains('用户喜欢吃辣'));
      expect(context, isNot(contains('记住我喜欢吃辣')));
    });

    test('all invalid LLM items remain retryable', () async {
      final character = makeChar('a');
      await db.aiCharacterBox.put(character.id, character);
      await seedConfig(character.apiConfigId);
      final message = makeMsg(
        senderType: 'user',
        content: '我保证明天完成',
      );

      await ObservationEntry(
        db: db,
        chatApi: CapturingChatApiService(
          responseText:
              '[{"kind":"unknown","content":"重要内容"},{"kind":"fact","content":""},{"wrong":"shape"}]',
        ),
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: message,
        visibleCharacterIds: ['a'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: [character],
        isGroupChat: true,
      );

      final queue = db.appSettingsBox.get('memory_retry_queue_v1') as List?;
      expect(queue, isNotNull);
      expect(queue, isNotEmpty);
    });

    test('a partially valid LLM array completes successfully', () async {
      final character = makeChar('a');
      await db.aiCharacterBox.put(character.id, character);
      await seedConfig(character.apiConfigId);
      final message = makeMsg(
        senderType: 'user',
        content: '我承诺明天完成',
      );

      await ObservationEntry(
        db: db,
        chatApi: CapturingChatApiService(
          responseText:
              '[{"kind":"commitment","content":"用户承诺明天完成","subjectIds":["user"],"importance":80,"confidence":0.9},{"kind":"unknown","content":"忽略"}]',
        ),
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: message,
        visibleCharacterIds: ['a'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: [character],
        isGroupChat: true,
      );

      expect(
        db.permanentMemoryBox.values
            .where((memory) => memory.status == MemoryStatus.active)
            .map((memory) => memory.content),
        contains('用户承诺明天完成'),
      );
      expect(db.appSettingsBox.get('memory_retry_queue_v1'), isNull);
    });

    test('structured memories reject invalid content and subjects', () async {
      final character = makeChar('a');
      await db.aiCharacterBox.put(character.id, character);
      await seedConfig(character.apiConfigId);

      await ObservationEntry(
        db: db,
        chatApi: CapturingChatApiService(
          responseText: '[${[
            '{"kind":"fact","content":123,"subjectIds":["user"],"importance":50,"confidence":0.8}',
            '{"kind":"fact","content":"未知主体","subjectIds":["missing"],"importance":50,"confidence":0.8}',
            '{"kind":"fact","content":"缺少主体","subjectIds":[],"importance":50,"confidence":0.8}',
            '{"kind":"personaGrowth","content":"角色逐渐更直接","subjectIds":[],"importance":50,"confidence":0.8}',
          ].join(',')}]',
        ),
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: makeMsg(senderType: 'user', content: '我喜欢直来直往'),
        visibleCharacterIds: ['a'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: [character],
        isGroupChat: true,
      );

      expect(db.permanentMemoryBox.values.map((memory) => memory.content),
          ['角色逐渐更直接']);
      expect(db.appSettingsBox.get('memory_retry_queue_v1'), isNull);
    });

    test('profile conflict only invalidates old memories that also conflict',
        () async {
      final character = makeChar('a');
      await db.aiCharacterBox.put(character.id, character);
      await seedConfig(character.apiConfigId);
      for (final memory in [
        PermanentMemory(
          id: 'wrong_name',
          observerCharacterId: 'a',
          kind: MemoryKind.fact,
          content: '用户叫小明',
          status: MemoryStatus.active,
          subjectIds: ['user'],
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: 'TestGroup',
          sourceMessageIds: ['old_wrong'],
          participantIds: ['a'],
          occurredAt: DateTime.now(),
        ),
        PermanentMemory(
          id: 'correct_name',
          observerCharacterId: 'a',
          kind: MemoryKind.fact,
          content: '用户名字叫小红',
          status: MemoryStatus.active,
          subjectIds: ['user'],
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: 'TestGroup',
          sourceMessageIds: ['old_correct'],
          participantIds: ['a'],
          occurredAt: DateTime.now(),
        ),
      ]) {
        await db.permanentMemoryBox.put(memory.id, memory);
      }

      final message = makeMsg(senderType: 'user', content: '我叫小明');
      await ObservationEntry(
        db: db,
        chatApi: CapturingChatApiService(
          responseText:
              '[{"kind":"fact","content":"用户名字叫小明","subjectIds":["user"],"importance":80,"confidence":0.9}]',
        ),
        credentialResolver: TestMemoryCredentialResolver(),
      ).observeMessage(
        message: message,
        visibleCharacterIds: ['a'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: [character],
        isGroupChat: true,
        userProfile: UserProfile(
          displayName: '小红',
          preferredAddress: '你',
          avatar: '',
          bio: '',
        ),
      );

      expect(db.permanentMemoryBox.get('wrong_name')!.status,
          MemoryStatus.invalidated);
      expect(db.permanentMemoryBox.get('correct_name')!.status,
          MemoryStatus.active);
      expect(
        db.permanentMemoryBox.values
            .singleWhere((memory) =>
                memory.sourceMessageIds.contains(message.id) &&
                memory.kind == MemoryKind.fact)
            .status,
        MemoryStatus.invalidated,
      );
    });
  });

  group('conflict handling', () {
    test('empty subject lists share the observer scope for deduplication',
        () async {
      await db.permanentMemoryBox.put(
        'persona_1',
        PermanentMemory(
          id: 'persona_1',
          observerCharacterId: 'a1',
          kind: MemoryKind.personaGrowth,
          content: '角色更直接',
          status: MemoryStatus.active,
          subjectIds: const [],
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: 'TestGroup',
          sourceMessageIds: ['old'],
          participantIds: ['a1'],
          occurredAt: DateTime.now(),
        ),
      );

      final result = await ObservationEntry(db: db).handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.personaGrowth,
        content: '角色更直接',
        subjectIds: const [],
        conversationId: 'g2',
        participants: ['a1'],
      );

      expect(result.action, ConflictAction.duplicate);
    });

    test('exact duplicate memory is detected', () async {
      await db.permanentMemoryBox.put(
          'dup_1',
          PermanentMemory(
            id: 'dup_1',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: 'user likes hiking',
            status: MemoryStatus.active,
            importance: 50,
            confidence: 0.8,
            subjectIds: ['user'],
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['msg_1'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      final entry = ObservationEntry(db: db);
      final result = await entry.handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.fact,
        content: 'user likes hiking',
        subjectIds: ['user'],
        conversationId: 'g1',
        participants: ['a1'],
      );

      expect(result.action, ConflictAction.duplicate);
    });

    test('superseding content marks old as superseded', () async {
      await db.permanentMemoryBox.put(
          'old_1',
          PermanentMemory(
            id: 'old_1',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢打网球',
            status: MemoryStatus.active,
            subjectIds: ['user'],
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      final entry = ObservationEntry(db: db);
      final result = await entry.handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.fact,
        content: '用户喜欢打篮球不是打网球',
        subjectIds: ['user'],
        conversationId: 'g1',
        participants: ['a1'],
      );

      expect(result.action, ConflictAction.supersede);
      expect(result.supersededIds, contains('old_1'));
    });

    test('profile conflict detection via pattern matching', () async {
      final profilePattern = RegExp(r'(名字叫|住在|年龄|岁|职业|来自|生日|性别|身高|体重)');
      expect(profilePattern.hasMatch('用户名字叫小红'), isTrue);
      expect(profilePattern.hasMatch('今天天气不错'), isFalse);
    });

    test('old memory remains auditable after supersede', () async {
      await db.permanentMemoryBox.put(
          'old_audit',
          PermanentMemory(
            id: 'old_audit',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢打网球',
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      await db.permanentMemoryBox.put(
          'new_audit',
          PermanentMemory(
            id: 'new_audit',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢打篮球不是打网球',
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['new'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
            supersedesIds: ['old_audit'],
          ));

      final oldRecord = db.permanentMemoryBox.get('old_audit');
      expect(oldRecord, isNotNull);

      final supersededIds = <String>{};
      for (final m in db.permanentMemoryBox.values) {
        if (m.status == MemoryStatus.active && m.supersedesIds.isNotEmpty) {
          supersededIds.addAll(m.supersedesIds);
        }
      }
      expect(supersededIds, contains('old_audit'));
    });
  });

  group('retry queue idempotency', () {
    test('same message+observer does not duplicate enqueue', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: 'regular chat');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final retryQueue = db.appSettingsBox.get('memory_retry_queue_v1');
      expect(retryQueue, isNull);
    });

    test('retry queue abandons after max attempts', () async {
      final chars = charList(['a1']);
      for (final c in chars) {
        await db.aiCharacterBox.put(c.id, c);
      }

      await db.appSettingsBox.put('memory_retry_queue_v1', [
        {
          'messageId': 'msg_1',
          'conversationId': 'g1',
          'conversationNameSnapshot': 'TestGroup',
          'observerId': 'a1',
          'queuedAt': DateTime.now().toIso8601String(),
          'attemptCount': 3,
        }
      ]);

      final entry = ObservationEntry(db: db);
      final processed = await entry.processRetryQueue(allCharacters: chars);
      expect(processed, 0);
    });

    test('concurrent retry enqueues preserve every distinct task', () async {
      final chars = charList(['a1']);
      final entry = ObservationEntry(db: db);
      final messages = List.generate(
        12,
        (index) => makeMsg(
          senderType: 'user',
          content: '你这个垃圾AI $index',
        ),
      );

      await Future.wait([
        for (final message in messages)
          entry.observeMessage(
            message: message,
            visibleCharacterIds: ['a1'],
            conversationId: 'g1',
            conversationNameSnapshot: 'TestGroup',
            allCharacters: chars,
            isGroupChat: true,
          ),
      ]);

      final queue = entry.loadRetryQueue();
      expect(queue.length, messages.length);
      expect(
        queue.map((item) => item['messageId']).toSet().length,
        messages.length,
      );
    });

    test('maxBatch counts attempted tasks, not only successful tasks',
        () async {
      final character = makeChar('a1');
      await db.aiCharacterBox.put(character.id, character);
      await db.apiConfigBox.put(
        character.apiConfigId,
        ApiConfig(
          id: character.apiConfigId,
          name: 'retry-config',
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
        ),
      );
      final first = makeMsg(senderType: 'user', content: '第一条');
      final second = makeMsg(senderType: 'user', content: '第二条');
      first.visibleToCharacterIds = ['a1'];
      second.visibleToCharacterIds = ['a1'];
      await db.messageBox.put(first.id, first);
      await db.messageBox.put(second.id, second);
      await db.appSettingsBox.put('memory_retry_queue_v1', [
        {
          'messageId': first.id,
          'conversationId': 'g1',
          'conversationNameSnapshot': 'TestGroup',
          'observerId': 'a1',
          'forceMemory': false,
          'attemptCount': 0,
        },
        {
          'messageId': second.id,
          'conversationId': 'g1',
          'conversationNameSnapshot': 'TestGroup',
          'observerId': 'a1',
          'forceMemory': false,
          'attemptCount': 0,
        },
      ]);
      await db.appSettingsBox.put('retry:${first.id}:a1', true);
      await db.appSettingsBox.put('retry:${second.id}:a1', true);

      final chatApi = CapturingChatApiService(responseText: '');
      final processed = await ObservationEntry(
        db: db,
        chatApi: chatApi,
        credentialResolver: TestMemoryCredentialResolver(),
      ).processRetryQueue(
        maxBatch: 1,
        allCharacters: [character],
      );

      final queue = ObservationEntry(db: db).loadRetryQueue();
      final firstTask =
          queue.firstWhere((item) => item['messageId'] == first.id);
      final secondTask =
          queue.firstWhere((item) => item['messageId'] == second.id);
      expect(processed, 0);
      expect(chatApi.sendCount, 1);
      expect(firstTask['attemptCount'], 1);
      expect(secondTask['attemptCount'], 0);
    });

    test('disabled automatic memory pauses retries without consuming attempts',
        () async {
      final character = makeChar('a1');
      await db.aiCharacterBox.put(character.id, character);
      await db.apiConfigBox.put(
        character.apiConfigId,
        ApiConfig(
          id: character.apiConfigId,
          name: 'retry-config',
          provider: 'deepseek',
          modelName: 'deepseek-chat',
          hasCredential: true,
        ),
      );
      final message = makeMsg(senderType: 'user', content: '我喜欢徒步');
      message.visibleToCharacterIds = ['a1'];
      await db.messageBox.put(message.id, message);
      await db.appSettingsBox.put('memory_retry_queue_v1', [
        {
          'messageId': message.id,
          'conversationId': 'g1',
          'conversationNameSnapshot': 'TestGroup',
          'observerId': 'a1',
          'forceMemory': false,
          'attemptCount': 1,
        },
      ]);
      await db.appSettingsBox.put('retry:${message.id}:a1', true);
      await MemoryControls(db).setAutomaticMemoryEnabled(false);

      final chatApi = CapturingChatApiService(responseText: '[]');
      final processed = await ObservationEntry(
        db: db,
        chatApi: chatApi,
        credentialResolver: TestMemoryCredentialResolver(),
      ).processRetryQueue(allCharacters: [character]);

      expect(processed, 0);
      expect(chatApi.sendCount, 0);
      expect(
        (ObservationEntry(db: db).loadRetryQueue().single
            as Map)['attemptCount'],
        1,
      );

      await MemoryControls(db).setAutomaticMemoryEnabled(true);
      expect(
        await ObservationEntry(
          db: db,
          chatApi: chatApi,
          credentialResolver: TestMemoryCredentialResolver(),
        ).processRetryQueue(allCharacters: [character]),
        1,
      );
      expect(ObservationEntry(db: db).loadRetryQueue(), isEmpty);
    });
  });

  group('Stage 09: directional RelationshipEvent', () {
    test('A->B and B->A are independent events', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: '攻击B', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];
      final service = RelationshipEventService(db);

      final r1 = await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );
      expect(r1, isTrue);

      final r2 = await service.observeAndApply(
        sourceCharacterId: 'b',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );
      expect(r2, isTrue);

      final events = db.relationshipEventBox.values.toList();
      expect(events.length, 2);
      final aToB = events.firstWhere((e) => e.sourceCharacterId == 'a');
      final bToA = events.firstWhere((e) => e.sourceCharacterId == 'b');
      expect(aToB.targetId, 'b');
      expect(bToA.targetId, 'a');
      expect(aToB.frictionAfter, greaterThan(aToB.frictionBefore));
      expect(bToA.frictionAfter, greaterThan(bToA.frictionBefore));
    });

    test('bystander C forms independent C->A event', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));
      await db.aiCharacterBox.put('c', makeChar('c'));

      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: '冒犯B', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b', 'c'];
      final service = RelationshipEventService(db);

      final r = await service.observeAndApply(
        sourceCharacterId: 'c',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b', 'c']),
      );
      expect(r, isTrue);

      final events = db.relationshipEventBox.values.toList();
      expect(events.length, 1);
      expect(events.first.sourceCharacterId, 'c');
      expect(events.first.targetId, 'a');
      expect(
          events.first.frictionAfter, greaterThan(events.first.frictionBefore));
    });

    test('direct participant and bystander receive different deltas', () async {
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '攻击B',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b', 'c'];
      final service = RelationshipEventService(db);

      await service.observeAndApply(
        sourceCharacterId: 'b',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b', 'c']),
      );
      await service.observeAndApply(
        sourceCharacterId: 'c',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b', 'c']),
        isBystander: true,
      );

      final direct = db.relationshipEventBox.values.firstWhere(
        (event) => event.sourceCharacterId == 'b',
      );
      final bystander = db.relationshipEventBox.values.firstWhere(
        (event) => event.sourceCharacterId == 'c',
      );
      expect(direct.frictionAfter, greaterThan(bystander.frictionAfter));
      expect(direct.affinityAfter, lessThan(bystander.affinityAfter));
    });

    test('relationship persistence waits for every production write', () async {
      final service = BlockingRelationshipEventService(db);
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '攻击B',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b', 'c'];

      final pending = persistRelationshipEvents(
        service: service,
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b', 'c']),
        visibleCharacterIds: message.visibleToCharacterIds,
      );
      expect(service.calls, 3);
      expect(service.bystanderFlags, [false, false, true]);
      var completed = false;
      pending.then((_) => completed = true);
      expect(completed, isFalse);

      service.gate.complete();
      await pending;
      expect(completed, isTrue);
    });

    test('group proactive messages do not default to AI-to-user', () async {
      final chars = charList(['a', 'b']);
      for (final character in chars) {
        await db.aiCharacterBox.put(character.id, character);
      }
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '大家继续讨论',
        groupId: 'g1',
      )..visibleToCharacterIds = ['a', 'b'];

      await RelationshipEventService(db).observeProactiveMessage(
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
      );

      expect(
        db.relationshipEventBox.values
            .where((event) => event.targetType == RelationshipTargetType.user),
        isEmpty,
      );
      expect(db.relationshipEventBox.values.single.targetId, 'a');
    });

    test('event replay does not double-add scores', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: '支持B', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];
      final service = RelationshipEventService(db);

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      // Replay same event.
      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      expect(db.relationshipEventBox.length, 1);
    });

    test('snapshot revision monotonically increases', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final service = RelationshipEventService(db);
      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: '互动', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final relation = db.relationshipStateBox.get(
        RelationshipState.stableGlobalId('a', RelationshipTargetType.ai, 'b'),
      );
      expect(relation, isNotNull);
      expect(relation!.revision, 1);
    });

    test('new relationship event recreates a deleted direction', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final initial = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        notes: '旧关系备注',
      );
      final legacy = RelationshipState(
        id: 'legacy-a-b',
        groupId: 'old-group',
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        notes: '旧关系备注',
      );
      await db.relationshipStateBox.put(initial.id, initial);
      await db.relationshipStateBox.put(legacy.id, legacy);
      await RelationshipControls(db).deleteRelationshipHistory(initial);

      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '新的互动',
        groupId: 'g2',
      );
      message.visibleToCharacterIds = ['a', 'b'];
      final result = await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g2',
        conversationNameSnapshot: '新群聊',
        allCharacters: charList(['a', 'b']),
      );

      expect(result, isTrue);
      final restored = db.relationshipStateBox.get(initial.id);
      expect(restored, isNotNull);
      expect(restored!.groupId, 'global');
      expect(restored.notes, isEmpty);
      final prompt = await MemoryContextSelector(db).select(
        observerCharacterId: 'a',
        participantCharacterIds: const ['a', 'b'],
        currentTargetId: 'b',
      );
      expect(prompt, contains('AI:b'));
    });

    test('stage anti-skip: normal event does not jump multiple levels',
        () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final service = RelationshipEventService(db);
      final relation = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        stage: RelationshipStage.stranger,
      );
      await db.relationshipStateBox.put(relation.id, relation);

      final message =
          makeMsg(senderType: 'user', content: '很高兴认识大家', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final updated = db.relationshipStateBox.get(relation.id)!;
      // User positive message: familiarityDelta=3, confidence=0.5 → triggers acquaintance.
      expect(updated.stage, RelationshipStage.acquaintance);
    });

    test('romantic stage requires explicit evidence', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final service = RelationshipEventService(db);
      final relation = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        stage: RelationshipStage.closeFriend,
        affinity: 95,
        trust: 90,
      );
      await db.relationshipStateBox.put(relation.id, relation);

      final message = makeMsg(
          senderType: 'ai',
          senderId: 'a',
          content: '我信任你，我们是好朋友',
          groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final updated = db.relationshipStateBox.get(relation.id)!;
      expect(updated.stage, isNot(RelationshipStage.romantic));
    });

    test('romantic stage is reachable from explicit romantic language',
        () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final service = RelationshipEventService(db);
      final relation = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        stage: RelationshipStage.closeFriend,
        affinity: 95,
        trust: 90,
      );
      await db.relationshipStateBox.put(relation.id, relation);

      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '我喜欢你，想和你约会',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final updated = db.relationshipStateBox.get(relation.id)!;
      expect(updated.stage, RelationshipStage.romantic);
      expect(db.relationshipEventBox.values.single.reason, contains('浪漫'));
    });

    test('romantic cues ignore negation and object-directed phrases', () async {
      const contents = [
        '我不喜欢你',
        '我不爱你',
        '喜欢你推荐的电影',
      ];

      for (var index = 0; index < contents.length; index++) {
        final sourceId = 'negative-source-$index';
        final targetId = 'negative-target-$index';
        final relation = RelationshipState.global(
          sourceCharacterId: sourceId,
          targetType: RelationshipTargetType.ai,
          targetId: targetId,
          stage: RelationshipStage.closeFriend,
          affinity: 95,
          trust: 90,
        );
        await db.relationshipStateBox.put(relation.id, relation);

        final message = makeMsg(
          senderType: 'ai',
          senderId: sourceId,
          content: contents[index],
          groupId: 'g1',
        );
        message.visibleToCharacterIds = [sourceId, targetId];

        await RelationshipEventService(db).observeAndApply(
          sourceCharacterId: sourceId,
          targetId: targetId,
          targetType: RelationshipTargetType.ai,
          message: message,
          conversationId: 'g1',
          conversationNameSnapshot: 'TestGroup',
          allCharacters: charList([sourceId, targetId]),
        );

        final updated = db.relationshipStateBox.get(relation.id)!;
        expect(updated.stage, RelationshipStage.closeFriend,
            reason: contents[index]);
        expect(updated.affinity, 96, reason: contents[index]);
        final event = db.relationshipEventBox.values.singleWhere(
          (candidate) => candidate.sourceCharacterId == sourceId,
        );
        expect(event.reason, isNot('浪漫表达'), reason: contents[index]);
      }
    });

    test('event written before snapshot update', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      final service = RelationshipEventService(db);
      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: '支持B', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      expect(db.relationshipEventBox.length, 1);
      expect(db.relationshipStateBox.length, 1);
      final relation = db.relationshipStateBox.values.first;
      expect(relation.lastEventId, isNotNull);
      expect(relation.revision, 1);
    });

    test('retries repair a snapshot that lagged behind its event', () async {
      final service = RelationshipEventService(db);
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '支持B',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final event = db.relationshipEventBox.values.single;
      final relation = db.relationshipStateBox.values.single;
      await db.relationshipStateBox.put(
        relation.id,
        RelationshipState.global(
          id: relation.id,
          sourceCharacterId: relation.sourceCharacterId,
          targetType: relation.targetType,
          targetId: relation.targetId,
        ),
      );

      final repaired = await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final restored = db.relationshipStateBox.get(relation.id)!;
      expect(repaired, isTrue);
      expect(restored.revision, event.revision);
      expect(restored.lastEventId, event.id);
      expect(restored.affinity, event.affinityAfter);
      expect(restored.stage, event.stageAfter);
    });

    test('automatic replay preserves notes from a failed manual snapshot write',
        () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));
      final initial = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        notes: '旧备注',
      );
      await db.relationshipStateBox.put(initial.id, initial);

      final controls = RelationshipControls(db)..testFailStateWriteOnce = true;
      await expectLater(
        controls.applyManualUpdate(
          relationship: initial,
          affinity: 42,
          trust: 12,
          friction: 4,
          familiarity: 30,
          mood: RelationshipMood.warm,
          stage: RelationshipStage.friend,
          notes: '人工备注',
        ),
        throwsA(isA<Object>()),
      );
      expect(db.relationshipEventBox.values.single.notesAfter, '人工备注');
      expect(db.relationshipStateBox.get(initial.id)!.notes, '旧备注');

      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '支持B',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b'];
      await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final restored = db.relationshipStateBox.get(initial.id)!;
      expect(restored.notes, '人工备注');
      expect(restored.revision, 2);
    });

    test('old automatic replay preserves current notes', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '支持B',
        groupId: 'g1',
      )..visibleToCharacterIds = ['a', 'b'];
      final initial = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        affinity: 12,
        trust: 15,
        notes: '保留的人工备注',
        lastInteractionAt: DateTime(2026, 8, 1, 12),
      );
      await db.relationshipStateBox.put(initial.id, initial);
      final event = RelationshipEvent(
        id: 're:a:ai:b:${message.id}',
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        reason: '旧自动事件',
        affinityBefore: initial.affinity,
        affinityAfter: 20,
        trustBefore: initial.trust,
        trustAfter: 25,
        frictionBefore: initial.friction,
        frictionAfter: initial.friction,
        familiarityBefore: initial.familiarity,
        familiarityAfter: initial.familiarity + 2,
        moodBefore: initial.recentMood,
        moodAfter: RelationshipMood.warm,
        stageBefore: initial.stage,
        stageAfter: initial.stage,
        originConversationId: 'g1',
        originNameSnapshot: 'TestGroup',
        sourceMessageIds: [message.id],
        revision: 1,
        occurredAt: DateTime(2026, 8, 2, 12),
        confidence: 0.8,
        createdBy: RelationshipEventCreator.automatic,
      );
      await db.relationshipEventBox.put(event.id, event);

      final repaired = await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final restored = db.relationshipStateBox.get(initial.id)!;
      expect(repaired, isTrue);
      expect(event.notesAfter, isEmpty);
      expect(restored.notes, '保留的人工备注');
      expect(restored.revision, event.revision);
    });

    test('manual replay preserves the existing interaction time', () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '支持B',
        groupId: 'g1',
      )..visibleToCharacterIds = ['a', 'b'];
      final interactionAt = DateTime(2026, 8, 1, 12);
      final initial = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        notes: '旧备注',
        lastInteractionAt: interactionAt,
      );
      await db.relationshipStateBox.put(initial.id, initial);
      final event = RelationshipEvent(
        id: 're:a:ai:b:${message.id}',
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        reason: '用户手动编辑关系',
        affinityBefore: initial.affinity,
        affinityAfter: 40,
        trustBefore: initial.trust,
        trustAfter: 40,
        frictionBefore: initial.friction,
        frictionAfter: initial.friction,
        familiarityBefore: initial.familiarity,
        familiarityAfter: 40,
        moodBefore: initial.recentMood,
        moodAfter: RelationshipMood.warm,
        stageBefore: initial.stage,
        stageAfter: RelationshipStage.friend,
        originNameSnapshot: '人工编辑',
        sourceMessageIds: const [],
        notesBefore: initial.notes,
        notesAfter: '新的人工备注',
        revision: 1,
        occurredAt: DateTime(2026, 8, 10, 12),
        confidence: 1.0,
        createdBy: RelationshipEventCreator.manual,
      );
      await db.relationshipEventBox.put(event.id, event);

      final repaired = await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final restored = db.relationshipStateBox.get(initial.id)!;
      expect(repaired, isTrue);
      expect(restored.notes, event.notesAfter);
      expect(restored.lastInteractionAt, interactionAt);
    });

    test('next event projects pending earlier events before applying itself',
        () async {
      final service = RelationshipEventService(db);
      final first = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '支持B',
        groupId: 'g1',
      );
      final second = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '攻击B',
        groupId: 'g1',
      );
      first.visibleToCharacterIds = ['a', 'b'];
      second.visibleToCharacterIds = ['a', 'b'];

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: first,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );
      final firstEvent = db.relationshipEventBox.values.single;
      final relation = db.relationshipStateBox.values.single;
      await db.relationshipStateBox.put(
        relation.id,
        RelationshipState.global(
          id: relation.id,
          sourceCharacterId: relation.sourceCharacterId,
          targetType: relation.targetType,
          targetId: relation.targetId,
        ),
      );

      await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: second,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      final secondEvent = db.relationshipEventBox.values.firstWhere(
        (event) => event.sourceMessageIds.contains(second.id),
      );
      final restored = db.relationshipStateBox.get(relation.id)!;
      expect(firstEvent.revision, 1);
      expect(secondEvent.revision, 2);
      expect(restored.revision, 2);
      expect(restored.lastEventId, secondEvent.id);
    });

    test('negative events cannot upgrade a stranger relationship', () async {
      final relation = RelationshipState.global(
        sourceCharacterId: 'b',
        targetType: RelationshipTargetType.ai,
        targetId: 'a',
        stage: RelationshipStage.stranger,
      );
      await db.relationshipStateBox.put(relation.id, relation);
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '攻击B',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b'];

      await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'b',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      expect(
        db.relationshipStateBox.get(relation.id)!.stage,
        RelationshipStage.stranger,
      );
    });

    test('strong negative event downgrades a close friendship', () async {
      final relation = RelationshipState.global(
        sourceCharacterId: 'b',
        targetType: RelationshipTargetType.ai,
        targetId: 'a',
        stage: RelationshipStage.closeFriend,
      );
      await db.relationshipStateBox.put(relation.id, relation);
      final message = makeMsg(
        senderType: 'ai',
        senderId: 'a',
        content: '攻击B',
        groupId: 'g1',
      );
      message.visibleToCharacterIds = ['a', 'b'];

      await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'b',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      expect(
        db.relationshipStateBox.get(relation.id)!.stage,
        RelationshipStage.strained,
      );
    });

    test('concurrent events for one relation preserve both updates', () async {
      final service = RelationshipEventService(db);
      final messages = [
        makeMsg(senderType: 'ai', senderId: 'a', content: '支持B'),
        makeMsg(senderType: 'ai', senderId: 'a', content: '支持B'),
      ];
      for (final message in messages) {
        message.visibleToCharacterIds = ['a', 'b'];
      }

      await Future.wait([
        for (final message in messages)
          service.observeAndApply(
            sourceCharacterId: 'a',
            targetId: 'b',
            targetType: RelationshipTargetType.ai,
            message: message,
            conversationId: 'g1',
            conversationNameSnapshot: 'TestGroup',
            allCharacters: charList(['a', 'b']),
          ),
      ]);

      final relation = db.relationshipStateBox.values.single;
      expect(db.relationshipEventBox.length, 2);
      expect(relation.revision, 2);
      expect(relation.affinity, 10);
    });

    test('pinned relationship rejects automatic event updates', () async {
      final relation = RelationshipState.global(
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
      );
      await db.relationshipStateBox.put(relation.id, relation);
      await MemoryControls(db).setPinned('relationship:${relation.id}', true);

      final message = makeMsg(senderType: 'ai', senderId: 'a', content: '支持B');
      message.visibleToCharacterIds = ['a', 'b'];
      final result = await RelationshipEventService(db).observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );

      expect(result, isFalse);
      expect(db.relationshipEventBox, isEmpty);
      expect(db.relationshipStateBox.get(relation.id)!.revision, 0);
    });
  });

  group('privacy and bystander isolation', () {
    test('A attack B produces different results for B and bystander C',
        () async {
      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));
      await db.aiCharacterBox.put('c', makeChar('c'));

      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: '冒犯B', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b', 'c'];
      final service = RelationshipEventService(db);

      final bResult = await service.observeAndApply(
        sourceCharacterId: 'b',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b', 'c']),
      );
      expect(bResult, isTrue);

      final cResult = await service.observeAndApply(
        sourceCharacterId: 'c',
        targetId: 'a',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b', 'c']),
      );
      expect(cResult, isTrue);

      final events = db.relationshipEventBox.values.toList();
      expect(events.length, 2);
      final bEvent = events.firstWhere((e) => e.sourceCharacterId == 'b');
      final cEvent = events.firstWhere((e) => e.sourceCharacterId == 'c');
      expect(bEvent.frictionAfter, greaterThan(bEvent.frictionBefore));
      expect(cEvent.frictionAfter, greaterThan(cEvent.frictionBefore));
      expect(bEvent.id, isNot(cEvent.id));
    });

    test('DM: absent AI creates no memory', () async {
      final charA = makeChar('a1');
      final charB = makeChar('a2');
      await db.aiCharacterBox.put('a1', charA);
      await db.aiCharacterBox.put('a2', charB);

      final dmMessage = makeMsg(
        senderType: 'user',
        groupId: 'dm:a2',
        content: '记住我们的秘密',
      );

      final entry = ObservationEntry(db: db);
      await entry.observeMessage(
        message: dmMessage,
        visibleCharacterIds: ['a2'],
        conversationId: 'dm:a2',
        conversationNameSnapshot: 'DM',
        allCharacters: [charA, charB],
        isGroupChat: false,
      );

      final a1Memories = db.permanentMemoryBox.values
          .where((m) => m.observerCharacterId == 'a1')
          .toList();
      expect(a1Memories, isEmpty);

      final a2Memories = db.permanentMemoryBox.values
          .where((m) => m.observerCharacterId == 'a2')
          .toList();
      expect(a2Memories.length, 1);
      expect(a2Memories.first.kind, MemoryKind.explicitInstruction);
    });
  });

  group('full flow verification', () {
    test('explicit memory and local relationship work without API', () async {
      final chars = charList(['a1']);
      for (final c in chars) {
        await db.aiCharacterBox.put(c.id, c);
      }

      // Explicit memory without API.
      final message = makeMsg(senderType: 'user', content: '记住我叫小明');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      final memories = db.permanentMemoryBox.values
          .where((m) => m.observerCharacterId == 'a1')
          .toList();
      expect(memories.length, 1);
      expect(memories.first.kind, MemoryKind.explicitInstruction);
      expect(memories.first.pinned, isTrue);

      // Local relationship without API.
      final relation = RelationshipState.global(
        sourceCharacterId: 'a1',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
      );
      await db.relationshipStateBox.put(relation.id, relation);

      final service = RelationshipEventService(db);
      final relMessage = makeMsg(senderType: 'user', content: '你好');
      relMessage.visibleToCharacterIds = ['a1'];

      final result = await service.observeAndApply(
        sourceCharacterId: 'a1',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        message: relMessage,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
      );
      expect(result, isTrue);
      expect(db.relationshipEventBox.length, 2);
    });
  });

  group('Milestone C regression tests', () {
    test('AI messages cannot create or forget user explicit memories',
        () async {
      await db.permanentMemoryBox.put(
        'user_pinned',
        PermanentMemory(
          id: 'user_pinned',
          observerCharacterId: 'a1',
          kind: MemoryKind.fact,
          content: '用户喜欢吃辣',
          status: MemoryStatus.active,
          pinned: true,
          subjectIds: ['user'],
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: 'TestGroup',
          sourceMessageIds: ['old'],
          participantIds: ['a1'],
          occurredAt: DateTime.now(),
        ),
      );

      final entry = ObservationEntry(db: db);
      for (final content in ['记住用户喜欢下雨', '忘记用户喜欢吃辣']) {
        await entry.observeMessage(
          message: makeMsg(senderType: 'ai', senderId: 'a1', content: content),
          visibleCharacterIds: ['a1'],
          conversationId: 'g1',
          conversationNameSnapshot: 'TestGroup',
          allCharacters: charList(['a1']),
          isGroupChat: true,
        );
      }

      expect(
        db.permanentMemoryBox.values
            .where((memory) => memory.observerCharacterId == 'a1')
            .map((memory) => memory.content),
        ['用户喜欢吃辣'],
      );
    });

    test('disabled automatic memory still executes user explicit commands',
        () async {
      await MemoryControls(db).setAutomaticMemoryEnabled(false);

      await ObservationEntry(db: db).observeMessage(
        message: makeMsg(senderType: 'user', content: '永久记住我的生日'),
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a1']),
        isGroupChat: true,
      );

      expect(db.permanentMemoryBox.length, 1);
      expect(db.permanentMemoryBox.values.single.pinned, isTrue);
      expect(db.relationshipEventBox, isEmpty);
      expect(db.appSettingsBox.get('memory_retry_queue_v1'), isNull);
    });

    test('negation "不要记住" triggers forget, not pinned memory', () async {
      final chars = charList(['a1']);
      final message = makeMsg(senderType: 'user', content: '不要记住我的生日');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      // 不应创建 explicitInstruction (pinned) 记忆。
      final pinned = db.permanentMemoryBox.values
          .where((m) => m.kind == MemoryKind.explicitInstruction && m.pinned)
          .toList();
      expect(pinned, isEmpty);
    });

    test('pinned memory is not superseded by new content', () async {
      await db.permanentMemoryBox.put(
          'pinned_1',
          PermanentMemory(
            id: 'pinned_1',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢打网球',
            status: MemoryStatus.active,
            pinned: true,
            subjectIds: ['user'],
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      final entry = ObservationEntry(db: db);
      final result = await entry.handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.fact,
        content: '用户喜欢打篮球不是打网球',
        subjectIds: ['user'],
        conversationId: 'g1',
        participants: ['a1'],
      );

      // Pinned memory should not appear in supersededIds.
      expect(result.supersededIds, isEmpty);

      // Pinned memory should still be active.
      final pinned = db.permanentMemoryBox.get('pinned_1')!;
      expect(pinned.status, MemoryStatus.active);
    });

    test('pinned memory is not invalidated by profile override', () async {
      await db.permanentMemoryBox.put(
          'pinned_profile',
          PermanentMemory(
            id: 'pinned_profile',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户名字叫小明',
            status: MemoryStatus.active,
            pinned: true,
            subjectIds: ['user'],
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      final entry = ObservationEntry(db: db);
      final result = await entry.handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.fact,
        content: '用户名字叫小绿',
        subjectIds: ['user'],
        conversationId: 'g1',
        participants: ['a1'],
        userProfile: UserProfile(
          displayName: '小红',
          preferredAddress: '你',
          avatar: '',
          bio: '',
        ),
      );
      expect(result.action, ConflictAction.profileOverride);
      expect(result.supersededIds, isEmpty);

      final pinned = db.permanentMemoryBox.get('pinned_profile')!;
      expect(pinned.status, MemoryStatus.active);
    });

    test('forgetting scope narrows to content-matched memories only', () async {
      final chars = charList(['a1']);

      // Create two memories: one about spicy food, one unrelated.
      await db.permanentMemoryBox.put(
          'spicy',
          PermanentMemory(
            id: 'spicy',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢吃辣',
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old1'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      await db.permanentMemoryBox.put(
          'hiking',
          PermanentMemory(
            id: 'hiking',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢徒步旅行',
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'g1',
            originNameSnapshot: 'TestGroup',
            sourceMessageIds: ['old2'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      await db.permanentMemoryBox.put(
          'spicy_pinned_elsewhere',
          PermanentMemory(
            id: 'spicy_pinned_elsewhere',
            observerCharacterId: 'a1',
            kind: MemoryKind.fact,
            content: '用户喜欢吃辣',
            status: MemoryStatus.active,
            pinned: true,
            originType: MemoryOriginType.direct,
            originConversationId: 'dm:a1',
            originNameSnapshot: 'DM',
            sourceMessageIds: ['old3'],
            participantIds: ['a1'],
            occurredAt: DateTime.now(),
          ));

      final message = makeMsg(senderType: 'user', content: '忘记用户喜欢吃辣');
      final entry = ObservationEntry(db: db);

      await entry.observeMessage(
        message: message,
        visibleCharacterIds: ['a1'],
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: chars,
        isGroupChat: true,
      );

      // Spicy memory should be invalidated.
      final spicyMem = db.permanentMemoryBox.get('spicy')!;
      expect(spicyMem.status, MemoryStatus.invalidated);

      // Hiking memory should still be active.
      final hikingMem = db.permanentMemoryBox.get('hiking')!;
      expect(hikingMem.status, MemoryStatus.active);

      // Explicit forget is global for the observer and can invalidate pinned
      // records while retaining their audit history.
      final pinnedElsewhere =
          db.permanentMemoryBox.get('spicy_pinned_elsewhere')!;
      expect(pinnedElsewhere.status, MemoryStatus.invalidated);
    });

    test('profile override compares with actual UserProfile fields', () async {
      // Import the UserProfile model for this test.
      final entry = ObservationEntry(db: db);

      // Test with profile that has displayName '小红'.
      final userProfile = UserProfile(
        displayName: '小红',
        preferredAddress: '你',
        avatar: '',
        bio: '',
        age: 25,
      );

      // "名字叫小明" should conflict with profile displayName '小红'.
      final conflictResult = await entry.handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.fact,
        content: '用户名字叫小明',
        subjectIds: ['user'],
        conversationId: 'g1',
        participants: ['a1'],
        userProfile: userProfile,
      );
      expect(conflictResult.action, ConflictAction.profileOverride);

      // "用户名字叫小红" should NOT conflict (matches profile).
      final noConflict = await entry.handleMemoryConflict(
        observerId: 'a1',
        kind: MemoryKind.fact,
        content: '用户名字叫小红',
        subjectIds: ['user'],
        conversationId: 'g1',
        participants: ['a1'],
        userProfile: userProfile,
      );
      expect(noConflict.action, isNot(ConflictAction.profileOverride));
    });

    test('relationship event ID uses full messageId', () async {
      // Import RelationshipEventService for this test.
      final service = RelationshipEventService(db);
      final message = makeMsg(
          senderType: 'ai', senderId: 'a', content: 'test', groupId: 'g1');
      message.visibleToCharacterIds = ['a', 'b'];

      await db.aiCharacterBox.put('a', makeChar('a'));
      await db.aiCharacterBox.put('b', makeChar('b'));

      // First call creates the event.
      final r1 = await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );
      expect(r1, isTrue);

      // Second call with same message should be idempotent.
      final r2 = await service.observeAndApply(
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: 'g1',
        conversationNameSnapshot: 'TestGroup',
        allCharacters: charList(['a', 'b']),
      );
      expect(r2, isFalse); // Idempotent: returns false.

      // Only one event should exist.
      expect(db.relationshipEventBox.length, 1);

      // Event ID should contain the full messageId.
      final event = db.relationshipEventBox.values.first;
      expect(event.id, contains(message.id));
    });
  });
}
