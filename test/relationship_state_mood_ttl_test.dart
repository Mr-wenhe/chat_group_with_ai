import 'package:chat_group/core/models/relationship_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = DateTime(2026, 9, 23, 12, 0, 0);

  RelationshipState make({
    RelationshipMood mood = RelationshipMood.neutral,
    DateTime? moodAt,
  }) =>
      RelationshipState(
        groupId: 'global',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        recentMood: mood,
        recentMoodAt: moodAt,
      );

  group('effectiveMood', () {
    test('neutral 恒为 neutral，即使带时间戳', () {
      final s = make(moodAt: base);
      expect(s.effectiveMood(now: base), RelationshipMood.neutral);
    });

    test('非 neutral 但时间戳为空 → neutral（老数据按已过期处理）', () {
      final s = make(mood: RelationshipMood.warm);
      expect(s.effectiveMood(now: base), RelationshipMood.neutral);
    });

    test('未达 TTL → 返回存储心情', () {
      final s = make(mood: RelationshipMood.warm, moodAt: base);
      expect(
        s.effectiveMood(now: base.add(const Duration(minutes: 29))),
        RelationshipMood.warm,
      );
    });

    test('恰好达到 TTL → neutral（边界用 >=）', () {
      final s = make(mood: RelationshipMood.warm, moodAt: base);
      expect(
        s.effectiveMood(now: base.add(kRelationshipMoodTtl)),
        RelationshipMood.neutral,
      );
    });

    test('超过 TTL → neutral', () {
      final s = make(mood: RelationshipMood.annoyed, moodAt: base);
      expect(
        s.effectiveMood(now: base.add(const Duration(hours: 2))),
        RelationshipMood.neutral,
      );
    });
  });

  group('hasActiveMood', () {
    test('neutral / 空时间戳 / 过期 → false', () {
      expect(
        RelationshipState.hasActiveMood(RelationshipMood.neutral, base,
            now: base),
        isFalse,
      );
      expect(
        RelationshipState.hasActiveMood(RelationshipMood.warm, null, now: base),
        isFalse,
      );
      expect(
        RelationshipState.hasActiveMood(RelationshipMood.warm, base,
            now: base.add(const Duration(hours: 1))),
        isFalse,
      );
    });

    test('非 neutral 且未过期 → true', () {
      expect(
        RelationshipState.hasActiveMood(RelationshipMood.warm, base,
            now: base.add(const Duration(minutes: 1))),
        isTrue,
      );
    });
  });

  test('TTL 为 30 分钟', () {
    expect(kRelationshipMoodTtl, const Duration(minutes: 30));
  });
}
