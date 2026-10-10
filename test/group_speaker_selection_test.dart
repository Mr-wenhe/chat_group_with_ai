import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/group_speaker_selection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  List<AICharacter> members(int count) =>
      [for (var index = 1; index <= count; index++) testCharacter('c$index')];

  List<AICharacter> pick(
    List<AICharacter> characters, {
    bool Function(AICharacter)? isEligible,
    bool Function(AICharacter)? mayAutoPick,
    Set<String> agenticRunning = const {},
    List<String> alreadySpoken = const [],
  }) =>
      GroupSpeakerSelection.candidates(
        characters: characters,
        isEligible: isEligible ?? (_) => true,
        mayAutoPick: mayAutoPick ?? (_) => true,
        agenticRunningCharacterIds: agenticRunning,
        alreadySpoken: alreadySpoken,
      );

  group('candidates', () {
    test('覆盖全部合格成员，不截断成前几名', () {
      final characters = members(6);
      final candidates = pick(characters);

      expect(candidates.map((c) => c.id).toList(),
          ['c1', 'c2', 'c3', 'c4', 'c5', 'c6']);
    });

    test('按稳定 ID 区分重名角色', () {
      final characters = [
        testCharacter('c1')..name = '同名',
        testCharacter('c2')..name = '同名',
        testCharacter('c3')..name = '同名',
      ];
      final candidates = pick(characters);

      // 名字相同也各自是独立候选，模型按 id 选人不会歧义。
      expect(candidates.map((c) => c.id).toSet(), {'c1', 'c2', 'c3'});
    });

    test('无资格成员、被禁言成员与正在跑任务的成员都退出候选', () {
      final characters = members(5);
      final candidates = pick(
        characters,
        isEligible: (c) => c.id != 'c2',
        mayAutoPick: (c) => c.id != 'c3',
        agenticRunning: {'c4'},
        alreadySpoken: const ['c5'],
      );

      expect(candidates.map((c) => c.id).toList(), ['c1']);
    });

    test('禁言例外由调用方的 mayAutoPick 决定：点名后重新入选', () {
      final characters = members(3);
      bool muted = true;
      final mentioned = {'c2'};

      final candidates = pick(
        characters,
        mayAutoPick: (c) => !muted || mentioned.contains(c.id),
      );

      expect(candidates.map((c) => c.id).toList(), ['c2']);
    });
  });

  group('avoidConsecutiveSpeaker', () {
    test('多个候选且无点名时排除上一位发言者', () {
      final candidates = members(3);
      final result = GroupSpeakerSelection.avoidConsecutiveSpeaker(
        candidates: candidates,
        lastAiSenderId: 'c2',
        hasMentions: false,
      );

      expect(result.map((c) => c.id).toList(), ['c1', 'c3']);
    });

    test('点名回合不套用连说保护', () {
      final candidates = members(3);
      final result = GroupSpeakerSelection.avoidConsecutiveSpeaker(
        candidates: candidates,
        lastAiSenderId: 'c2',
        hasMentions: true,
      );

      expect(result.length, 3);
    });

    test('只剩一个候选时保留它，宁可连说也不让整轮没人回应', () {
      final candidates = [testCharacter('c1')];
      final result = GroupSpeakerSelection.avoidConsecutiveSpeaker(
        candidates: candidates,
        lastAiSenderId: 'c1',
        hasMentions: false,
      );

      expect(result.map((c) => c.id).toList(), ['c1']);
    });
  });

  group('priorityMentionIds', () {
    test('本轮点名的排在前，历史待回应点名的排在后，且去重', () {
      final candidates = members(3);
      final ids = GroupSpeakerSelection.priorityMentionIds(
        mentionedIds: const ['c3'],
        pendingMentionedIds: const ['c2', 'c3'],
        candidates: candidates,
      );

      expect(ids, ['c3', 'c2']);
    });

    test('不在候选里的点名者不进入优先队列', () {
      final candidates = members(2);
      final ids = GroupSpeakerSelection.priorityMentionIds(
        mentionedIds: const ['c9'],
        pendingMentionedIds: const ['c1'],
        candidates: candidates,
      );

      expect(ids, ['c1']);
    });
  });

  group('nextStep', () {
    test('没有候选时不调用模型', () {
      final step = GroupSpeakerSelection.nextStep(
        candidates: const [],
        priorityMentionIds: const [],
      );
      expect(step.kind, SpeakerStepKind.finished);
    });

    test('明确点名的独立候选直接选定，不调用模型', () {
      final step = GroupSpeakerSelection.nextStep(
        candidates: members(4),
        priorityMentionIds: const ['c3'],
      );
      expect(step.kind, SpeakerStepKind.decided);
      expect(step.characterId, 'c3');
    });

    test('只剩一个候选时直接选定，不调用模型', () {
      final step = GroupSpeakerSelection.nextStep(
        candidates: members(1),
        priorityMentionIds: const [],
      );
      expect(step.kind, SpeakerStepKind.decided);
      expect(step.characterId, 'c1');
    });

    test('多候选且无点名时才需要问选人器', () {
      final step = GroupSpeakerSelection.nextStep(
        candidates: members(2),
        priorityMentionIds: const [],
      );
      expect(step.kind, SpeakerStepKind.askModel);
    });
  });

  group('maxReplies', () {
    test('沿用既有上限：用户回合 3、点名回合 2、空闲单轮 2', () {
      expect(
        GroupSpeakerSelection.maxReplies(hasMentions: false, isAutoChat: false),
        3,
      );
      expect(
        GroupSpeakerSelection.maxReplies(hasMentions: true, isAutoChat: false),
        2,
      );
      expect(
        GroupSpeakerSelection.maxReplies(hasMentions: false, isAutoChat: true),
        2,
      );
    });
  });
}
