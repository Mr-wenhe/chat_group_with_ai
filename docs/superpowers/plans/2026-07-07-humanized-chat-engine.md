# Humanized Chat Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first-stage Humanized Chat Engine so group replies are driven by relationships, layered memory, and concrete conversational intent rather than simple random AI answers.

**Architecture:** Add focused Hive models for per-group character memory and directional relationships, then add pure Dart services for reply intent selection, prompt assembly, and memory updates. `ChatRoomPage` remains the UI coordinator and calls these services; it should not absorb the new algorithms.

**Tech Stack:** Flutter, Dart, Hive, Riverpod provider access through the existing `DatabaseService`, Dio-backed chat completions, `flutter_test`, `build_runner`.

---

## File Structure

- Create `lib/core/models/character_memory.dart`: Hive model for one character's memory inside one group.
- Create `lib/core/models/relationship_state.dart`: Hive model for one directional relationship inside one group.
- Generate `lib/core/models/character_memory.g.dart` and `lib/core/models/relationship_state.g.dart` with build_runner.
- Modify `lib/core/database/database_service.dart`: register adapters, open boxes, expose getters, clear new boxes.
- Create `lib/features/chat_group/humanized_chat_orchestrator.dart`: pure Dart reply intent selection and enums.
- Create `lib/features/chat_group/humanized_prompt_builder.dart`: pure Dart prompt/context builder for one `ReplyIntent`.
- Create `lib/features/chat_group/humanized_memory_service.dart`: pure Dart local relationship rules, layered memory parsing, clipping, and legacy migration helper.
- Modify `lib/features/chat_group/chat_room_page.dart`: load new memory/relationship state, use `ReplyIntent` in user-triggered and auto rounds, pass intent to prompt builder, update humanized memory after each round.
- Test `test/humanized_chat_orchestrator_test.dart`.
- Test `test/humanized_prompt_builder_test.dart`.
- Test `test/humanized_memory_service_test.dart`.
- Extend `test/conversation_export_service_test.dart` with a regression that no internal intent/debug fields are exported.

## Task 1: Add Hive Models For Layered Memory And Relationships

**Files:**
- Create: `lib/core/models/character_memory.dart`
- Create: `lib/core/models/relationship_state.dart`
- Create after codegen: `lib/core/models/character_memory.g.dart`
- Create after codegen: `lib/core/models/relationship_state.g.dart`
- Test: `test/humanized_memory_service_test.dart`

- [ ] **Step 1: Write a failing model smoke test**

Create `test/humanized_memory_service_test.dart` with this initial content:

```dart
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Humanized memory models', () {
    test('CharacterMemory stores layered memory per group and character', () {
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'char-1',
        facts: ['用户喜欢夜跑'],
        relationshipNotes: ['我对小林有点不服'],
        personaGrowth: ['我最近说话更爱反问'],
      );

      expect(memory.groupId, 'group-1');
      expect(memory.characterId, 'char-1');
      expect(memory.facts, ['用户喜欢夜跑']);
      expect(memory.relationshipNotes, ['我对小林有点不服']);
      expect(memory.personaGrowth, ['我最近说话更爱反问']);
      expect(memory.lastUpdatedAt, isA<DateTime>());
      expect(memory.createdAt, isA<DateTime>());
    });

    test('RelationshipState stores one directional relationship', () {
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        affinity: 20,
        trust: 15,
        friction: 5,
        familiarity: 40,
        recentMood: RelationshipMood.warm,
        notes: '熟，但偶尔互怼',
      );

      expect(relation.groupId, 'group-1');
      expect(relation.sourceCharacterId, 'char-a');
      expect(relation.targetId, 'char-b');
      expect(relation.targetType, RelationshipTargetType.ai);
      expect(relation.affinity, 20);
      expect(relation.trust, 15);
      expect(relation.friction, 5);
      expect(relation.familiarity, 40);
      expect(relation.recentMood, RelationshipMood.warm);
      expect(relation.notes, '熟，但偶尔互怼');
    });

    test('legacy memorySummary seeds personaGrowth when new memory is empty', () {
      final character = AICharacter(
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: ['敏感'],
        systemPrompt: '说话轻一点',
        memorySummary: '我记得自己在这个群里慢慢开始敢开玩笑。',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );

      final memory = HumanizedMemoryService.memoryForCharacter(
        groupId: 'group-1',
        character: character,
        existing: const [],
      );

      expect(memory.groupId, 'group-1');
      expect(memory.characterId, character.id);
      expect(memory.facts, isEmpty);
      expect(memory.relationshipNotes, isEmpty);
      expect(memory.personaGrowth, ['我记得自己在这个群里慢慢开始敢开玩笑。']);
    });
  });
}
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
flutter test test/humanized_memory_service_test.dart
```

Expected: FAIL because `character_memory.dart`, `relationship_state.dart`, and `humanized_memory_service.dart` do not exist.

- [ ] **Step 3: Create `CharacterMemory`**

Create `lib/core/models/character_memory.dart`:

```dart
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'character_memory.g.dart';

@HiveType(typeId: 5)
class CharacterMemory extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String characterId;

  @HiveField(3)
  List<String> facts;

  @HiveField(4)
  List<String> relationshipNotes;

  @HiveField(5)
  List<String> personaGrowth;

  @HiveField(6)
  DateTime lastUpdatedAt;

  @HiveField(7)
  final DateTime createdAt;

  CharacterMemory({
    String? id,
    required this.groupId,
    required this.characterId,
    List<String>? facts,
    List<String>? relationshipNotes,
    List<String>? personaGrowth,
    DateTime? lastUpdatedAt,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        facts = facts ?? [],
        relationshipNotes = relationshipNotes ?? [],
        personaGrowth = personaGrowth ?? [],
        lastUpdatedAt = lastUpdatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();
}
```

- [ ] **Step 4: Create `RelationshipState`**

Create `lib/core/models/relationship_state.dart`:

```dart
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'relationship_state.g.dart';

@HiveType(typeId: 6)
enum RelationshipTargetType {
  @HiveField(0)
  ai,
  @HiveField(1)
  user,
}

@HiveType(typeId: 7)
enum RelationshipMood {
  @HiveField(0)
  neutral,
  @HiveField(1)
  warm,
  @HiveField(2)
  annoyed,
  @HiveField(3)
  awkward,
  @HiveField(4)
  protective,
  @HiveField(5)
  cold,
}

@HiveType(typeId: 8)
class RelationshipState extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String sourceCharacterId;

  @HiveField(3)
  final String targetId;

  @HiveField(4)
  RelationshipTargetType targetType;

  @HiveField(5)
  int affinity;

  @HiveField(6)
  int trust;

  @HiveField(7)
  int friction;

  @HiveField(8)
  int familiarity;

  @HiveField(9)
  RelationshipMood recentMood;

  @HiveField(10)
  String notes;

  @HiveField(11)
  DateTime lastInteractionAt;

  @HiveField(12)
  final DateTime createdAt;

  RelationshipState({
    String? id,
    required this.groupId,
    required this.sourceCharacterId,
    required this.targetId,
    required this.targetType,
    this.affinity = 0,
    this.trust = 0,
    this.friction = 0,
    this.familiarity = 0,
    this.recentMood = RelationshipMood.neutral,
    this.notes = '',
    DateTime? lastInteractionAt,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        lastInteractionAt = lastInteractionAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  void clampScores() {
    affinity = affinity.clamp(-100, 100).toInt();
    trust = trust.clamp(-100, 100).toInt();
    friction = friction.clamp(0, 100).toInt();
    familiarity = familiarity.clamp(0, 100).toInt();
  }
}
```

- [ ] **Step 5: Create the minimal service used by the model test**

Create `lib/features/chat_group/humanized_memory_service.dart`:

```dart
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';

class HumanizedMemoryService {
  static CharacterMemory memoryForCharacter({
    required String groupId,
    required AICharacter character,
    required List<CharacterMemory> existing,
  }) {
    for (final memory in existing) {
      if (memory.groupId == groupId && memory.characterId == character.id) {
        return memory;
      }
    }

    final legacy = character.memorySummary.trim();
    return CharacterMemory(
      groupId: groupId,
      characterId: character.id,
      personaGrowth: legacy.isEmpty ? const [] : [legacy],
    );
  }
}
```

- [ ] **Step 6: Generate Hive adapters**

Run:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Expected: `character_memory.g.dart` and `relationship_state.g.dart` are created.

- [ ] **Step 7: Run the model test and verify it passes**

Run:

```bash
flutter test test/humanized_memory_service_test.dart
```

Expected: PASS.

- [ ] **Step 8: Commit Task 1**

Run:

```bash
git add lib/core/models/character_memory.dart lib/core/models/character_memory.g.dart lib/core/models/relationship_state.dart lib/core/models/relationship_state.g.dart lib/features/chat_group/humanized_memory_service.dart test/humanized_memory_service_test.dart
git commit -m "feat: add humanized memory models"
```

## Task 2: Register New Hive Boxes In DatabaseService

**Files:**
- Modify: `lib/core/database/database_service.dart`
- Test: `test/humanized_memory_service_test.dart`

- [ ] **Step 1: Extend the existing test with adapter registration coverage**

Append this test inside the existing `group('Humanized memory models', ...)` in `test/humanized_memory_service_test.dart`:

```dart
    test('RelationshipState clamps relationship score ranges', () {
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'char-a',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        affinity: 300,
        trust: -300,
        friction: 300,
        familiarity: 300,
      );

      relation.clampScores();

      expect(relation.affinity, 100);
      expect(relation.trust, -100);
      expect(relation.friction, 100);
      expect(relation.familiarity, 100);
    });
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
flutter test test/humanized_memory_service_test.dart
```

Expected: PASS. This verifies the model utility before database wiring.

- [ ] **Step 3: Modify imports and box constants**

In `lib/core/database/database_service.dart`, add imports:

```dart
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
```

Add constants below `_groupMemoryBox`:

```dart
  static const String _characterMemoryBox = 'character_memories';
  static const String _relationshipStateBox = 'relationship_states';
```

- [ ] **Step 4: Register adapters and open boxes**

In `init()`, after `Hive.registerAdapter(GroupMemoryAdapter());`, add:

```dart
    Hive.registerAdapter(CharacterMemoryAdapter());
    Hive.registerAdapter(RelationshipTargetTypeAdapter());
    Hive.registerAdapter(RelationshipMoodAdapter());
    Hive.registerAdapter(RelationshipStateAdapter());
```

After `await _openBoxSafely<GroupMemory>(_groupMemoryBox);`, add:

```dart
    await _openBoxSafely<CharacterMemory>(_characterMemoryBox);
    await _openBoxSafely<RelationshipState>(_relationshipStateBox);
```

- [ ] **Step 5: Clear new boxes with existing data reset**

In `clearAllData()`, after `await groupMemoryBox.clear();`, add:

```dart
    await characterMemoryBox.clear();
    await relationshipStateBox.clear();
```

- [ ] **Step 6: Expose getters**

Add getters near the existing box getters:

```dart
  Box<CharacterMemory> get characterMemoryBox =>
      Hive.box<CharacterMemory>(_characterMemoryBox);
  Box<RelationshipState> get relationshipStateBox =>
      Hive.box<RelationshipState>(_relationshipStateBox);
```

- [ ] **Step 7: Run static analysis**

Run:

```bash
flutter analyze
```

Expected: PASS with no new analyzer errors.

- [ ] **Step 8: Run focused tests**

Run:

```bash
flutter test test/humanized_memory_service_test.dart
```

Expected: PASS.

- [ ] **Step 9: Commit Task 2**

Run:

```bash
git add lib/core/database/database_service.dart test/humanized_memory_service_test.dart
git commit -m "feat: register humanized memory storage"
```

## Task 3: Implement ReplyIntent Selection

**Files:**
- Create: `lib/features/chat_group/humanized_chat_orchestrator.dart`
- Test: `test/humanized_chat_orchestrator_test.dart`

- [ ] **Step 1: Write failing tests for intent selection**

Create `test/humanized_chat_orchestrator_test.dart`:

```dart
import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter character(String id, String name, String role,
        {List<String> tags = const []}) =>
    AICharacter(
      id: id,
      name: name,
      avatar: name.substring(0, 1),
      age: 25,
      role: role,
      personalityTags: tags,
      systemPrompt: '你是$name',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

void main() {
  group('HumanizedChatOrchestrator.selectReplyIntents', () {
    test('mentioned character gets top priority', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'user',
            senderType: 'user',
            content: '@小林 你怎么看？',
            mentionedAiIds: ['b'],
            isMention: true,
          ),
        ],
        groupId: 'group-1',
        userMessage: '@小林 你怎么看？',
        mentionedIds: ['b'],
        memories: const [],
        relationships: const [],
        isEligible: (_) => true,
        random: Random(1),
      );

      expect(intents, isNotEmpty);
      expect(intents.first.speakerId, 'b');
      expect(intents.first.action, ReplyAction.answer);
      expect(intents.first.reason, contains('mentioned'));
    });

    test('high friction makes challenge intent more likely', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        friction: 80,
        affinity: -20,
        recentMood: RelationshipMood.annoyed,
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '这个想法太粗糙了。',
          ),
        ],
        groupId: 'group-1',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation],
        isEligible: (c) => c.id == 'a',
        random: Random(2),
      );

      expect(intents, hasLength(1));
      expect(intents.first.speakerId, 'a');
      expect(intents.first.action, ReplyAction.challenge);
      expect(intents.first.toneHint, contains('带刺'));
    });

    test('warm relationship can produce comfort or agree intent', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        affinity: 70,
        trust: 60,
        familiarity: 80,
        recentMood: RelationshipMood.warm,
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '我今天有点累。',
          ),
        ],
        groupId: 'group-1',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation],
        isEligible: (c) => c.id == 'a',
        random: Random(3),
      );

      expect(intents, hasLength(1));
      expect(
        [ReplyAction.comfort, ReplyAction.agree, ReplyAction.askBack],
        contains(intents.first.action),
      );
    });

    test('recent speaker receives cooldown penalty', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'a',
            senderType: 'ai',
            content: '我刚说了一大段。',
          ),
          Message(
            groupId: 'group-1',
            senderId: 'user',
            senderType: 'user',
            content: '还有谁想说？',
          ),
        ],
        groupId: 'group-1',
        userMessage: '还有谁想说？',
        mentionedIds: const [],
        memories: const [],
        relationships: const [],
        isEligible: (_) => true,
        random: Random(4),
      );

      expect(intents, isNotEmpty);
      expect(intents.first.speakerId, 'b');
    });

    test('topic interest uses role, tags, and persona growth', () {
      final artist = character('a', '阿月', '插画师', tags: ['审美']);
      final engineer = character('b', '小林', '程序员', tags: ['后端']);
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'a',
        personaGrowth: ['我最近对配色和构图特别较真'],
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [artist, engineer],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'user',
            senderType: 'user',
            content: '这个海报配色怎么调？',
          ),
        ],
        groupId: 'group-1',
        userMessage: '这个海报配色怎么调？',
        mentionedIds: const [],
        memories: [memory],
        relationships: const [],
        isEligible: (_) => true,
        random: Random(5),
      );

      expect(intents, isNotEmpty);
      expect(intents.first.speakerId, 'a');
      expect(intents.first.reason, contains('topic-interest'));
    });
  });
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
flutter test test/humanized_chat_orchestrator_test.dart
```

Expected: FAIL because `humanized_chat_orchestrator.dart` does not exist.

- [ ] **Step 3: Implement `HumanizedChatOrchestrator`**

Create `lib/features/chat_group/humanized_chat_orchestrator.dart`:

```dart
import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';

enum ReplyAction {
  answer,
  agree,
  challenge,
  joke,
  askBack,
  topicShift,
  comfort,
  callOut,
}

enum ReplyLengthHint {
  oneLiner,
  short,
  normal,
}

class ReplyIntent {
  final String speakerId;
  final ReplyAction action;
  final String? targetId;
  final ReplyLengthHint lengthHint;
  final String toneHint;
  final String reason;

  const ReplyIntent({
    required this.speakerId,
    required this.action,
    this.targetId,
    required this.lengthHint,
    required this.toneHint,
    required this.reason,
  });
}

class _ScoredIntent {
  final ReplyIntent intent;
  final int score;

  const _ScoredIntent(this.intent, this.score);
}

class HumanizedChatOrchestrator {
  static List<ReplyIntent> selectReplyIntents({
    required List<AICharacter> characters,
    required List<Message> recentMessages,
    required String groupId,
    required String? userMessage,
    required List<String> mentionedIds,
    required List<CharacterMemory> memories,
    required List<RelationshipState> relationships,
    required bool Function(AICharacter character) isEligible,
    required Random random,
    bool isAutoChat = false,
  }) {
    final eligible = characters.where(isEligible).toList();
    if (eligible.isEmpty) return const [];

    final scored = <_ScoredIntent>[];
    for (final character in eligible) {
      final intent = _intentForCharacter(
        character: character,
        recentMessages: recentMessages,
        groupId: groupId,
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        memories: memories,
        relationships: relationships,
        random: random,
        isAutoChat: isAutoChat,
      );
      if (intent == null) continue;
      scored.add(intent);
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final limit = mentionedIds.isNotEmpty ? 2 : (isAutoChat ? 2 : 3);
    return scored.take(limit).map((s) => s.intent).toList();
  }

  static _ScoredIntent? _intentForCharacter({
    required AICharacter character,
    required List<Message> recentMessages,
    required String groupId,
    required String? userMessage,
    required List<String> mentionedIds,
    required List<CharacterMemory> memories,
    required List<RelationshipState> relationships,
    required Random random,
    required bool isAutoChat,
  }) {
    var score = isAutoChat ? 24 : 18;
    final reasons = <String>[];
    ReplyAction action = ReplyAction.answer;
    ReplyLengthHint length = ReplyLengthHint.short;
    var tone = '自然、口语、像群友';
    String? targetId;

    if (mentionedIds.contains(character.id)) {
      score += 100;
      reasons.add('mentioned');
      action = ReplyAction.answer;
      length = ReplyLengthHint.short;
    }

    if (recentMessages.isNotEmpty) {
      final last = recentMessages.last;
      if (last.senderId == character.id) {
        score -= 45;
        reasons.add('recency-cooldown');
      } else if (last.senderType == 'ai') {
        final relation = _relationToward(
          relationships,
          groupId,
          character.id,
          last.senderId,
        );
        if (relation != null) {
          targetId = last.senderId;
          score += relation.familiarity ~/ 4;
          if (relation.friction >= 60 || relation.affinity < -10) {
            score += 36;
            reasons.add('relationship-friction');
            action = ReplyAction.challenge;
            tone = '带刺、别太客气、但别人身攻击';
            length = ReplyLengthHint.oneLiner;
          } else if (relation.affinity >= 50 || relation.trust >= 50) {
            score += 28;
            reasons.add('relationship-warmth');
            action = _comfortingAction(last.content, random);
            tone = '熟人感、轻一点、别端着';
            length = ReplyLengthHint.short;
          }
          if (relation.recentMood == RelationshipMood.awkward ||
              relation.recentMood == RelationshipMood.cold) {
            score -= 12;
            reasons.add('mood-cooldown');
          }
        }
      }
    }

    final topicScore = _topicInterest(character, memories, userMessage);
    if (topicScore > 0) {
      score += topicScore;
      reasons.add('topic-interest');
      if (action == ReplyAction.answer) {
        length = ReplyLengthHint.normal;
      }
    }

    if (mentionedIds.isEmpty && score < 35 && random.nextDouble() < 0.28) {
      reasons.add('silence');
      return null;
    }

    if (isAutoChat && random.nextDouble() < 0.18) {
      action = ReplyAction.topicShift;
      tone = '随口想到、轻微跑题、自然递话';
      reasons.add('auto-topic-shift');
    } else if (mentionedIds.isEmpty && random.nextDouble() < 0.14) {
      action = ReplyAction.joke;
      tone = '接梗、轻松、短';
      length = ReplyLengthHint.oneLiner;
      reasons.add('interrupt-joke');
    }

    score += random.nextInt(8);
    if (reasons.isEmpty) reasons.add('baseline');

    return _ScoredIntent(
      ReplyIntent(
        speakerId: character.id,
        action: action,
        targetId: targetId,
        lengthHint: length,
        toneHint: tone,
        reason: reasons.join(','),
      ),
      score,
    );
  }

  static RelationshipState? _relationToward(
    List<RelationshipState> relationships,
    String groupId,
    String sourceId,
    String targetId,
  ) {
    for (final relation in relationships) {
      if (relation.groupId == groupId &&
          relation.sourceCharacterId == sourceId &&
          relation.targetId == targetId) {
        return relation;
      }
    }
    return null;
  }

  static ReplyAction _comfortingAction(String content, Random random) {
    final lower = content.toLowerCase();
    if (content.contains('累') ||
        content.contains('难受') ||
        content.contains('烦') ||
        lower.contains('tired')) {
      return ReplyAction.comfort;
    }
    return random.nextBool() ? ReplyAction.agree : ReplyAction.askBack;
  }

  static int _topicInterest(
    AICharacter character,
    List<CharacterMemory> memories,
    String? userMessage,
  ) {
    final text = userMessage?.toLowerCase() ?? '';
    if (text.isEmpty) return 0;
    final haystack = [
      character.role,
      ...character.personalityTags,
      for (final memory in memories.where((m) => m.characterId == character.id))
        ...memory.personaGrowth,
    ].join(' ').toLowerCase();

    var score = 0;
    for (final token in _tokens(text)) {
      if (token.length < 2) continue;
      if (haystack.contains(token)) score += 18;
    }

    if (_creativeTopic(text) && _creativeRole(haystack)) score += 32;
    if (_technicalTopic(text) && _technicalRole(haystack)) score += 32;
    return score.clamp(0, 48).toInt();
  }

  static Iterable<String> _tokens(String text) sync* {
    for (final part in text.split(RegExp(r'\s+|[，。！？、,.!?]'))) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  static bool _creativeTopic(String text) =>
      text.contains('海报') ||
      text.contains('配色') ||
      text.contains('构图') ||
      text.contains('审美') ||
      text.contains('画');

  static bool _creativeRole(String text) =>
      text.contains('插画') ||
      text.contains('设计') ||
      text.contains('审美') ||
      text.contains('配色') ||
      text.contains('构图');

  static bool _technicalTopic(String text) =>
      text.contains('代码') ||
      text.contains('接口') ||
      text.contains('bug') ||
      text.contains('后端') ||
      text.contains('程序');

  static bool _technicalRole(String text) =>
      text.contains('程序') ||
      text.contains('工程') ||
      text.contains('后端') ||
      text.contains('技术');
}
```

- [ ] **Step 4: Run intent tests**

Run:

```bash
flutter test test/humanized_chat_orchestrator_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add lib/features/chat_group/humanized_chat_orchestrator.dart test/humanized_chat_orchestrator_test.dart
git commit -m "feat: select humanized reply intents"
```

## Task 4: Implement Humanized Prompt Builder

**Files:**
- Create: `lib/features/chat_group/humanized_prompt_builder.dart`
- Test: `test/humanized_prompt_builder_test.dart`

- [ ] **Step 1: Write failing prompt builder tests**

Create `test/humanized_prompt_builder_test.dart`:

```dart
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HumanizedPromptBuilder', () {
    test('builds concrete humanized context without debug reason', () {
      final character = AICharacter(
        id: 'a',
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: ['敏感', '会接梗'],
        systemPrompt: '说话轻一点',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );
      final target = AICharacter(
        id: 'b',
        name: '小林',
        avatar: 'B',
        age: 27,
        role: '程序员',
        personalityTags: ['较真'],
        systemPrompt: '说话直接',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'a',
        facts: ['用户最近在准备一个海报'],
        relationshipNotes: ['我觉得小林说话有点冲，但观点有用'],
        personaGrowth: ['我最近习惯先开个小玩笑再认真说'],
      );
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        friction: 70,
        affinity: -10,
        notes: '互相不太服',
        recentMood: RelationshipMood.annoyed,
      );
      const intent = ReplyIntent(
        speakerId: 'a',
        action: ReplyAction.challenge,
        targetId: 'b',
        lengthHint: ReplyLengthHint.oneLiner,
        toneHint: '带刺、别太客气',
        reason: 'relationship-friction,debug-only',
      );

      final content = HumanizedPromptBuilder.buildIntentContext(
        character: character,
        groupName: '灵感群',
        groupTheme: '日常创作',
        ownerName: '老冯',
        intent: intent,
        memory: memory,
        relationships: [relation],
        charactersById: {'a': character, 'b': target},
      );

      expect(content, contains('你是阿月'));
      expect(content, contains('用户最近在准备一个海报'));
      expect(content, contains('我觉得小林说话有点冲'));
      expect(content, contains('互相不太服'));
      expect(content, contains('本轮动作：challenge'));
      expect(content, contains('一句话'));
      expect(content, contains('不要说自己是 AI'));
      expect(content, isNot(contains('debug-only')));
      expect(content, isNot(contains('relationship-friction')));
    });

    test('length hints are explicit', () {
      expect(
        HumanizedPromptBuilder.lengthInstruction(ReplyLengthHint.oneLiner),
        contains('25 个字'),
      );
      expect(
        HumanizedPromptBuilder.lengthInstruction(ReplyLengthHint.short),
        contains('1-2 句'),
      );
      expect(
        HumanizedPromptBuilder.lengthInstruction(ReplyLengthHint.normal),
        contains('2-4 句'),
      );
    });
  });
}
```

- [ ] **Step 2: Run prompt tests and verify they fail**

Run:

```bash
flutter test test/humanized_prompt_builder_test.dart
```

Expected: FAIL because `humanized_prompt_builder.dart` does not exist.

- [ ] **Step 3: Implement `HumanizedPromptBuilder`**

Create `lib/features/chat_group/humanized_prompt_builder.dart`:

```dart
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';

class HumanizedPromptBuilder {
  static String buildIntentContext({
    required AICharacter character,
    required String groupName,
    required String groupTheme,
    required String ownerName,
    required ReplyIntent intent,
    required CharacterMemory memory,
    required List<RelationshipState> relationships,
    required Map<String, AICharacter> charactersById,
  }) {
    final relevantRelations = _relationLines(
      relationships: relationships,
      character: character,
      targetId: intent.targetId,
      charactersById: charactersById,
    );
    final targetName = intent.targetId == null
        ? '当前话题'
        : charactersById[intent.targetId!]?.name ?? ownerName;

    return [
      '【真人化发言上下文】',
      '你是${character.name}，${character.age}岁，身份是${character.role}。',
      '你正在「$groupName」里聊天，群主题是「$groupTheme」，真人用户/群主叫「$ownerName」。',
      if (character.personalityTags.isNotEmpty)
        '你的基础性格标签：${character.personalityTags.join('、')}。',
      if (memory.facts.isNotEmpty) '你记得的事实：${_limit(memory.facts, 4)}',
      if (memory.relationshipNotes.isNotEmpty)
        '你的关系记忆：${_limit(memory.relationshipNotes, 4)}',
      if (memory.personaGrowth.isNotEmpty)
        '你最近形成的表达习惯：${_limit(memory.personaGrowth, 4)}',
      if (relevantRelations.isNotEmpty) '你和相关成员的关系：${relevantRelations.join('；')}',
      '本轮动作：${intent.action.name}，主要对象：$targetName。',
      '本轮语气：${intent.toneHint}。',
      lengthInstruction(intent.lengthHint),
      '你是在群里自然接话，不是在写完整答案。',
      '不要总结全局，不要说自己是 AI，不要替别人发言，不要固定格式，不要带自己的名字前缀。',
    ].join('\n');
  }

  static String lengthInstruction(ReplyLengthHint hint) {
    return switch (hint) {
      ReplyLengthHint.oneLiner => '长度要求：一句话，尽量不超过 25 个字。',
      ReplyLengthHint.short => '长度要求：1-2 句，像群友随手回。',
      ReplyLengthHint.normal => '长度要求：2-4 句，可以稍微展开，但不要写成总结。',
    };
  }

  static String _limit(List<String> values, int count) {
    return values.take(count).join('；');
  }

  static List<String> _relationLines({
    required List<RelationshipState> relationships,
    required AICharacter character,
    required String? targetId,
    required Map<String, AICharacter> charactersById,
  }) {
    final filtered = relationships
        .where((r) => r.sourceCharacterId == character.id)
        .where((r) => targetId == null || r.targetId == targetId)
        .take(4);

    return filtered.map((r) {
      final name = r.targetType == RelationshipTargetType.user
          ? '真人用户'
          : charactersById[r.targetId]?.name ?? '某个群友';
      final mood = r.recentMood.name;
      final note = r.notes.trim().isEmpty ? '没有明确备注' : r.notes.trim();
      return '$name：亲近${r.affinity}，信任${r.trust}，摩擦${r.friction}，最近情绪$mood，$note';
    }).toList();
  }
}
```

- [ ] **Step 4: Run prompt tests**

Run:

```bash
flutter test test/humanized_prompt_builder_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add lib/features/chat_group/humanized_prompt_builder.dart test/humanized_prompt_builder_test.dart
git commit -m "feat: build humanized reply prompts"
```

## Task 5: Implement Memory Update Rules And JSON Parsing

**Files:**
- Modify: `lib/features/chat_group/humanized_memory_service.dart`
- Test: `test/humanized_memory_service_test.dart`

- [ ] **Step 1: Add failing tests for local relationship update and JSON parsing**

Append these tests to `test/humanized_memory_service_test.dart`:

```dart
  group('HumanizedMemoryService relationship and JSON behavior', () {
    test('applyLocalRelationshipRules updates friction after challenge', () {
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        friction: 10,
        familiarity: 20,
      );

      final updated = HumanizedMemoryService.applyLocalRelationshipRules(
        relationships: [relation],
        groupId: 'group-1',
        speakerId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        actionName: 'challenge',
        friendlyTone: false,
      );

      expect(updated.single.friction, greaterThan(10));
      expect(updated.single.familiarity, greaterThan(20));
      expect(updated.single.recentMood, RelationshipMood.annoyed);
    });

    test('applyLocalRelationshipRules creates missing relation', () {
      final updated = HumanizedMemoryService.applyLocalRelationshipRules(
        relationships: const [],
        groupId: 'group-1',
        speakerId: 'a',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        actionName: 'askBack',
        friendlyTone: true,
      );

      expect(updated, hasLength(1));
      expect(updated.single.targetType, RelationshipTargetType.user);
      expect(updated.single.affinity, greaterThan(0));
      expect(updated.single.familiarity, greaterThan(0));
    });

    test('parseLayeredMemoryJson returns clipped unique entries', () {
      final parsed = HumanizedMemoryService.parseLayeredMemoryJson('''
{
  "facts": ["用户喜欢夜跑", "用户喜欢夜跑", "这是一条非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常长的事实"],
  "relationshipNotes": ["我对小林有点不服"],
  "personaGrowth": ["我最近爱用反问"],
  "discard": ["寒暄"]
}
''');

      expect(parsed.facts.length, 2);
      expect(parsed.facts.first, '用户喜欢夜跑');
      expect(parsed.relationshipNotes, ['我对小林有点不服']);
      expect(parsed.personaGrowth, ['我最近爱用反问']);
    });

    test('parseLayeredMemoryJson returns empty result for invalid JSON', () {
      final parsed = HumanizedMemoryService.parseLayeredMemoryJson('not json');

      expect(parsed.facts, isEmpty);
      expect(parsed.relationshipNotes, isEmpty);
      expect(parsed.personaGrowth, isEmpty);
    });

    test('mergeLayeredMemory keeps each layer bounded', () {
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'a',
        facts: List.generate(12, (i) => '旧事实$i'),
        relationshipNotes: List.generate(12, (i) => '旧关系$i'),
        personaGrowth: List.generate(12, (i) => '旧成长$i'),
      );
      final parsed = const LayeredMemoryUpdate(
        facts: ['新事实'],
        relationshipNotes: ['新关系'],
        personaGrowth: ['新成长'],
      );

      HumanizedMemoryService.mergeLayeredMemory(memory, parsed);

      expect(memory.facts.length, lessThanOrEqualTo(10));
      expect(memory.relationshipNotes.length, lessThanOrEqualTo(10));
      expect(memory.personaGrowth.length, lessThanOrEqualTo(10));
      expect(memory.facts.last, '新事实');
      expect(memory.relationshipNotes.last, '新关系');
      expect(memory.personaGrowth.last, '新成长');
    });
  });
```

- [ ] **Step 2: Run memory tests and verify they fail**

Run:

```bash
flutter test test/humanized_memory_service_test.dart
```

Expected: FAIL because the new service methods are not implemented.

- [ ] **Step 3: Replace `humanized_memory_service.dart` with full implementation**

Update `lib/features/chat_group/humanized_memory_service.dart`:

```dart
import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';

class LayeredMemoryUpdate {
  final List<String> facts;
  final List<String> relationshipNotes;
  final List<String> personaGrowth;

  const LayeredMemoryUpdate({
    this.facts = const [],
    this.relationshipNotes = const [],
    this.personaGrowth = const [],
  });
}

class HumanizedMemoryService {
  static const int maxLayerEntries = 10;
  static const int maxEntryChars = 80;

  static CharacterMemory memoryForCharacter({
    required String groupId,
    required AICharacter character,
    required List<CharacterMemory> existing,
  }) {
    for (final memory in existing) {
      if (memory.groupId == groupId && memory.characterId == character.id) {
        return memory;
      }
    }

    final legacy = character.memorySummary.trim();
    return CharacterMemory(
      groupId: groupId,
      characterId: character.id,
      personaGrowth: legacy.isEmpty ? const [] : [_clip(legacy)],
    );
  }

  static List<RelationshipState> applyLocalRelationshipRules({
    required List<RelationshipState> relationships,
    required String groupId,
    required String speakerId,
    required String? targetId,
    required RelationshipTargetType targetType,
    required String actionName,
    required bool friendlyTone,
  }) {
    if (targetId == null || targetId.isEmpty) return relationships;

    final updated = relationships.toList();
    var index = updated.indexWhere((r) =>
        r.groupId == groupId &&
        r.sourceCharacterId == speakerId &&
        r.targetId == targetId);
    if (index == -1) {
      updated.add(RelationshipState(
        groupId: groupId,
        sourceCharacterId: speakerId,
        targetId: targetId,
        targetType: targetType,
      ));
      index = updated.length - 1;
    }

    final relation = updated[index];
    relation.familiarity += 6;
    relation.lastInteractionAt = DateTime.now();

    switch (actionName) {
      case 'challenge':
      case 'callOut':
        relation.friction += 12;
        relation.affinity -= 3;
        relation.recentMood = RelationshipMood.annoyed;
        break;
      case 'agree':
      case 'comfort':
        relation.affinity += 8;
        relation.trust += 6;
        relation.recentMood = RelationshipMood.warm;
        break;
      case 'askBack':
        relation.affinity += friendlyTone ? 5 : 1;
        relation.recentMood =
            friendlyTone ? RelationshipMood.warm : RelationshipMood.neutral;
        break;
      case 'joke':
        relation.affinity += friendlyTone ? 4 : 0;
        relation.friction += friendlyTone ? 0 : 4;
        relation.recentMood =
            friendlyTone ? RelationshipMood.warm : RelationshipMood.awkward;
        break;
      default:
        relation.familiarity += 2;
    }

    relation.clampScores();
    return updated;
  }

  static LayeredMemoryUpdate parseLayeredMemoryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const LayeredMemoryUpdate();
      return LayeredMemoryUpdate(
        facts: _readLayer(decoded['facts']),
        relationshipNotes: _readLayer(decoded['relationshipNotes']),
        personaGrowth: _readLayer(decoded['personaGrowth']),
      );
    } catch (_) {
      return const LayeredMemoryUpdate();
    }
  }

  static void mergeLayeredMemory(
    CharacterMemory memory,
    LayeredMemoryUpdate update,
  ) {
    memory.facts = _mergeLayer(memory.facts, update.facts);
    memory.relationshipNotes =
        _mergeLayer(memory.relationshipNotes, update.relationshipNotes);
    memory.personaGrowth =
        _mergeLayer(memory.personaGrowth, update.personaGrowth);
    memory.lastUpdatedAt = DateTime.now();
  }

  static List<String> _readLayer(Object? raw) {
    if (raw is! List) return const [];
    final result = <String>[];
    for (final item in raw) {
      final text = _clip(item.toString().trim());
      if (text.isEmpty || result.contains(text)) continue;
      result.add(text);
    }
    return result.take(maxLayerEntries).toList();
  }

  static List<String> _mergeLayer(List<String> existing, List<String> incoming) {
    final result = <String>[];
    for (final text in [...existing, ...incoming]) {
      final clipped = _clip(text.trim());
      if (clipped.isEmpty) continue;
      result.remove(clipped);
      result.add(clipped);
    }
    if (result.length <= maxLayerEntries) return result;
    return result.sublist(result.length - maxLayerEntries);
  }

  static String _clip(String text) {
    if (text.length <= maxEntryChars) return text;
    return text.substring(0, maxEntryChars);
  }
}
```

- [ ] **Step 4: Run memory tests**

Run:

```bash
flutter test test/humanized_memory_service_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit Task 5**

Run:

```bash
git add lib/features/chat_group/humanized_memory_service.dart test/humanized_memory_service_test.dart
git commit -m "feat: update humanized memory state"
```

## Task 6: Wire Humanized Intent And Prompt Into ChatRoomPage

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart`
- Test: existing tests plus focused humanized tests.

- [ ] **Step 1: Add imports to `chat_room_page.dart`**

Add these imports near the existing app imports:

```dart
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
```

- [ ] **Step 2: Add state fields**

Inside `_ChatRoomPageState`, near `_groupMemory`, add:

```dart
  List<CharacterMemory> _characterMemories = [];
  List<RelationshipState> _relationshipStates = [];
  final Map<String, ReplyIntent> _pendingReplyIntents = {};
  int _autoChatMemoryTick = 0;
```

- [ ] **Step 3: Load humanized state with room data**

Add these local variables in `_loadData()` after the group memory has been created and before the existing `setState` call:

```dart
    final characterMemories = _db.characterMemoryBox.values
        .where((m) => m.groupId == widget.groupId)
        .toList();
    final relationshipStates = _db.relationshipStateBox.values
        .where((r) => r.groupId == widget.groupId)
        .toList();
```

Inside the existing `setState(() { ... })` block, after `_groupMemory = memory;`, add:

```dart
      _characterMemories = characterMemories;
      _relationshipStates = relationshipStates;
```

- [ ] **Step 4: Replace user-round character selection with intents**

In `_runAiRound`, replace:

```dart
    final charactersToReply = _selectReplyCharacters(mentionedIds, userMessage);
```

with:

```dart
    final replyIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _recentMessagesForContext(),
      groupId: widget.groupId,
      userMessage: userMessage,
      mentionedIds: mentionedIds ?? const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _random,
      isAutoChat: isAutoChat,
    );
    final charactersToReply = replyIntents
        .map((intent) => _characters.firstWhere((c) => c.id == intent.speakerId))
        .toList();
    _pendingReplyIntents
      ..clear()
      ..addEntries(replyIntents.map((intent) => MapEntry(intent.speakerId, intent)));
```

Keep the existing empty-state handling that follows.

- [ ] **Step 5: Pass intents into `_generateAiReply`**

Change the `_generateAiReply` signature:

```dart
  Future<String> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false, ReplyIntent? intent}) async {
```

Change the call inside `_runAiRound`:

```dart
      final replyContent = await _generateAiReply(
        character,
        _recentMessagesForContext(),
        userMessage,
        isAutoChat: isAutoChat,
        intent: _pendingReplyIntents[character.id],
      );
```

Task 7 replaces the auto-chat speaker loop and passes the matching intent there.

- [ ] **Step 6: Pass intent into `_buildApiMessages`**

Change `_buildApiMessages` signature:

```dart
  List<Map<String, dynamic>> _buildApiMessages(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false, ReplyIntent? intent}) {
```

Change the call in `_generateAiReply`:

```dart
    final apiMessages = _buildApiMessages(
      character,
      context,
      userMessage,
      isAutoChat: isAutoChat,
      intent: intent,
    );
```

Change the regenerate call that passes `_regenerateContext` to include `intent: null`.

- [ ] **Step 7: Add humanized prompt context inside `_buildApiMessages`**

After the existing character memory system block and before the broad group scene block, insert:

```dart
    if (intent != null) {
      final memory = HumanizedMemoryService.memoryForCharacter(
        groupId: widget.groupId,
        character: character,
        existing: _characterMemories,
      );
      final byId = {for (final c in _characters) c.id: c};
      msgs.add({
        'role': 'system',
        'content': HumanizedPromptBuilder.buildIntentContext(
          character: character,
          groupName: _group?.name ?? '这个群',
          groupTheme: _group?.theme ?? '日常聊天',
          ownerName: (_group?.ownerName.trim().isNotEmpty ?? false)
              ? _group!.ownerName.trim()
              : '我',
          intent: intent,
          memory: memory,
          relationships: _relationshipStates,
          charactersById: byId,
        ),
      });
    }
```

- [ ] **Step 8: Update local relationship state after each successful reply**

After `fullContent` is finalized and before `return fullContent;` in `_generateAiReply`, add:

```dart
    if (!failed && intent != null) {
      final targetType = intent.targetId == null || intent.targetId == 'user'
          ? RelationshipTargetType.user
          : RelationshipTargetType.ai;
      _relationshipStates = HumanizedMemoryService.applyLocalRelationshipRules(
        relationships: _relationshipStates,
        groupId: widget.groupId,
        speakerId: character.id,
        targetId: intent.targetId,
        targetType: targetType,
        actionName: intent.action.name,
        friendlyTone: !intent.toneHint.contains('带刺') &&
            !intent.toneHint.contains('冷淡'),
      );
      for (final relation in _relationshipStates) {
        await _db.relationshipStateBox.put(relation.id, relation);
      }
    }
```

- [ ] **Step 9: Run analyzer**

Run:

```bash
flutter analyze
```

Expected: PASS. Fix every analyzer error introduced by this task before continuing.

- [ ] **Step 10: Run focused pure tests**

Run:

```bash
flutter test test/humanized_chat_orchestrator_test.dart test/humanized_prompt_builder_test.dart test/humanized_memory_service_test.dart
```

Expected: PASS.

- [ ] **Step 11: Commit Task 6**

Run:

```bash
git add lib/features/chat_group/chat_room_page.dart
git commit -m "feat: wire humanized intents into chat room"
```

## Task 7: Use Humanized Intents For Auto Chat And Layered Memory Persistence

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart`
- Test: `test/humanized_chat_orchestrator_test.dart`, `test/humanized_memory_service_test.dart`

- [ ] **Step 1: Replace auto-chat speaker selection**

In `_tryAutoChatRound`, replace the call to `ChatActivityPolicy.selectAutoChatSpeakers(...)` with:

```dart
    final autoIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _messages.toList(),
      groupId: widget.groupId,
      userMessage: null,
      mentionedIds: const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _autoChatRandom,
      isAutoChat: true,
    );
    final speakers = autoIntents
        .map((intent) => _characters.firstWhere((c) => c.id == intent.speakerId))
        .toList();
    _pendingReplyIntents
      ..clear()
      ..addEntries(autoIntents.map((intent) => MapEntry(intent.speakerId, intent)));
```

Keep the existing `speakers.isEmpty` handling.

- [ ] **Step 2: Pass auto-chat intent into generation**

In the auto-chat loop, change:

```dart
        final replyContent = await _generateAiReply(
          speaker,
          _messages.toList(),
          null,
          isAutoChat: true,
        );
```

to:

```dart
        final replyContent = await _generateAiReply(
          speaker,
          _messages.toList(),
          null,
          isAutoChat: true,
          intent: _pendingReplyIntents[speaker.id],
        );
```

- [ ] **Step 3: Add helper to persist character memory**

Inside `_ChatRoomPageState`, add this method near `_maybeEvolveCharacterMemory`:

```dart
  Future<void> _mergeHumanizedMemory(
    AICharacter character,
    String rawJson,
  ) async {
    final update = HumanizedMemoryService.parseLayeredMemoryJson(rawJson);
    if (update.facts.isEmpty &&
        update.relationshipNotes.isEmpty &&
        update.personaGrowth.isEmpty) {
      return;
    }

    final memory = HumanizedMemoryService.memoryForCharacter(
      groupId: widget.groupId,
      character: character,
      existing: _characterMemories,
    );
    HumanizedMemoryService.mergeLayeredMemory(memory, update);
    await _db.characterMemoryBox.put(memory.id, memory);
    final index = _characterMemories.indexWhere((m) => m.id == memory.id);
    if (index == -1) {
      _characterMemories = [..._characterMemories, memory];
    } else {
      _characterMemories = [..._characterMemories]..[index] = memory;
    }
  }
```

- [ ] **Step 4: Change `_maybeEvolveCharacterMemory` to ask for JSON**

Replace the two message entries passed to `_chatApi.sendChatMessage` in `_maybeEvolveCharacterMemory` with:

```dart
      messages: [
        {
          'role': 'system',
          'content': '你只负责更新角色长期记忆。必须输出严格 JSON，不要 Markdown，不要解释。',
        },
        {
          'role': 'user',
          'content': '$prompt\n\n输出 JSON 形状：'
              '{"facts":["稳定事实"],"relationshipNotes":["关系或情绪变化"],'
              '"personaGrowth":["表达习惯、偏好、雷点或长期执念"],"discard":["不保存内容"]}',
        },
      ],
```

After extracting `updated`, replace the direct `character.memorySummary = ...` block with:

```dart
    await _mergeHumanizedMemory(character, updated);
    character.memorySummary = _compactMemoryText(updated);
    await character.save();
    if (_canTouchUi) setState(() {});
```

This keeps legacy `memorySummary` compatible while making `CharacterMemory` the primary structured store.

- [ ] **Step 5: Throttle automatic memory updates**

In `_tryAutoChatRound`, replace:

```dart
      await _maybeUpdateMemory();
```

with:

```dart
      _autoChatMemoryTick++;
      if (_autoChatMemoryTick >= 3) {
        _autoChatMemoryTick = 0;
        await _maybeUpdateMemory();
      }
```

- [ ] **Step 6: Run analyzer and focused tests**

Run:

```bash
flutter analyze
flutter test test/humanized_chat_orchestrator_test.dart test/humanized_memory_service_test.dart
```

Expected: PASS. Fix every analyzer error introduced by this task before continuing.

- [ ] **Step 7: Commit Task 7**

Run:

```bash
git add lib/features/chat_group/chat_room_page.dart
git commit -m "feat: persist humanized chat memory"
```

## Task 8: Export Safety Regression

**Files:**
- Modify: `test/conversation_export_service_test.dart`
- No production code change expected unless the test reveals a leak.

- [ ] **Step 1: Add regression test**

Append this test in `test/conversation_export_service_test.dart` inside the existing `ConversationExportService` group:

```dart
    test('exports do not include humanized intent debug fields', () {
      final chatGroup = ChatGroup(
        id: 'g1',
        name: '灵感群',
        description: '',
        theme: '日常创作',
        aiCharacterIds: const ['c1'],
      );
      final character = AICharacter(
        id: 'c1',
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: const ['敏感'],
        systemPrompt: 'secret system prompt',
        apiKey: 'secret-key',
        apiProvider: 'deepseek',
      );
      final messages = [
        Message(
          groupId: 'g1',
          senderId: 'c1',
          senderType: 'ai',
          content: '这配色有点太满了。',
        ),
      ];

      final json = ConversationExportService().toJson(
        chatGroup,
        messages,
        {'c1': character},
      );
      final markdown = ConversationExportService().toMarkdown(
        chatGroup,
        messages,
        {'c1': character},
      );

      expect(json.toString(), isNot(contains('ReplyIntent')));
      expect(json.toString(), isNot(contains('reason')));
      expect(json.toString(), isNot(contains('secret-key')));
      expect(json.toString(), isNot(contains('secret system prompt')));
      expect(markdown, isNot(contains('ReplyIntent')));
      expect(markdown, isNot(contains('secret-key')));
      expect(markdown, isNot(contains('secret system prompt')));
    });
```

- [ ] **Step 2: Run export tests**

Run:

```bash
flutter test test/conversation_export_service_test.dart
```

Expected: PASS.

- [ ] **Step 3: Commit Task 8**

Run:

```bash
git add test/conversation_export_service_test.dart
git commit -m "test: cover humanized export safety"
```

## Task 9: Full Verification And Final Cleanup

**Files:**
- May modify any file touched by earlier tasks only to fix analyzer, formatting, or failing tests.

- [ ] **Step 1: Format changed Dart files**

Run:

```bash
dart format lib/core/models/character_memory.dart lib/core/models/relationship_state.dart lib/core/database/database_service.dart lib/features/chat_group/humanized_chat_orchestrator.dart lib/features/chat_group/humanized_prompt_builder.dart lib/features/chat_group/humanized_memory_service.dart lib/features/chat_group/chat_room_page.dart test/humanized_chat_orchestrator_test.dart test/humanized_prompt_builder_test.dart test/humanized_memory_service_test.dart test/conversation_export_service_test.dart
```

Expected: command completes and prints formatted file names if changes were needed.

- [ ] **Step 2: Regenerate code after formatting**

Run:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Expected: generated Hive adapters are current.

- [ ] **Step 3: Run analyzer**

Run:

```bash
flutter analyze
```

Expected: PASS. If it reports a new error, fix the exact file and rerun.

- [ ] **Step 4: Run full test suite**

Run:

```bash
flutter test
```

Expected: PASS.

- [ ] **Step 5: Inspect changed files**

Run:

```bash
git status --short
git diff --stat
```

Expected: only files related to the Humanized Chat Engine are changed.

- [ ] **Step 6: Commit verification cleanup**

If formatting, generated adapters, or small fixes changed files after the previous commits, run:

```bash
git add lib test
git commit -m "chore: verify humanized chat engine"
```

If `git status --short` is clean, skip this commit.

## Completion Checklist

- [ ] New Hive models are registered and opened.
- [ ] Existing `AICharacter.memorySummary` is preserved and used as migration input.
- [ ] Humanized reply selection uses relationships, topic interest, recency cooldown, silence, and auto-chat behavior.
- [ ] Prompt context includes intent, layered memory, and relevant relationships while excluding debug reason.
- [ ] Memory update failure cannot block chat completion.
- [ ] Auto-chat memory updates are throttled.
- [ ] Export tests prove API keys, system prompt, and internal intent/debug fields are not exported.
- [ ] `dart run build_runner build --delete-conflicting-outputs` has run.
- [ ] `flutter analyze` passes.
- [ ] `flutter test` passes.
