import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryAuditFilter', () {
    test('isEmpty returns true for default filter', () {
      expect(MemoryAuditFilter().isEmpty, isTrue);
    });

    test('apply without filters returns all memories', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c2', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originNameSnapshot: 'dm',
        ),
      ];
      final result = MemoryAuditFilter().apply(memories);
      expect(result.length, 2);
    });

    test('apply filters by observerCharacterId', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c2', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result = MemoryAuditFilter(observerCharacterId: 'c1').apply(memories);
      expect(result.length, 1);
      expect(result.first.observerCharacterId, 'c1');
    });

    test('apply filters by status', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.superseded,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result = MemoryAuditFilter(status: MemoryStatus.active).apply(memories);
      expect(result.length, 1);
      expect(result.first.status, MemoryStatus.active);
    });

    test('apply filters by originType', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.manual,
          originNameSnapshot: 'manual',
        ),
      ];
      final result = MemoryAuditFilter(originType: MemoryOriginType.manual).apply(memories);
      expect(result.length, 1);
      expect(result.first.originType, MemoryOriginType.manual);
    });

    test('apply filters by memoryKind', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.preference,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result = MemoryAuditFilter(memoryKind: MemoryKind.preference).apply(memories);
      expect(result.length, 1);
      expect(result.first.kind, MemoryKind.preference);
    });

    test('apply filters pinnedOnly true', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', pinned: true,
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', pinned: false,
        ),
      ];
      final result = MemoryAuditFilter(pinnedOnly: true).apply(memories);
      expect(result.length, 1);
      expect(result.first.pinned, isTrue);
    });

    test('subjectFilter aboutMe matches user subjectIds', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', subjectIds: const ['c2'],
        ),
      ];
      final result = MemoryAuditFilter(subjectFilter: SubjectFilter.aboutMe()).apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, contains('user'));
    });

    test('subjectFilter aboutCharacter matches given id', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', subjectIds: const ['c2'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', subjectIds: const ['c3'],
        ),
      ];
      final result = MemoryAuditFilter(subjectFilter: SubjectFilter.aboutCharacter('c2')).apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, contains('c2'));
    });

    test('subjectFilter selfGrowth matches empty subjectIds', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.personaGrowth,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', subjectIds: const [],
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', subjectIds: const ['user'],
        ),
      ];
      final result = MemoryAuditFilter(subjectFilter: SubjectFilter.selfGrowth()).apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, isEmpty);
    });

    test('filters combine with AND', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'a', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', pinned: true,
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: 'b', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', pinned: false,
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c2', kind: MemoryKind.fact,
          content: 'c', status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1', pinned: true,
          subjectIds: const ['user'],
        ),
      ];
      final result = MemoryAuditFilter(
        observerCharacterId: 'c1',
        pinnedOnly: true,
        subjectFilter: SubjectFilter.aboutMe(),
      ).apply(memories);
      expect(result.length, 1);
      expect(result.first.observerCharacterId, 'c1');
      expect(result.first.pinned, isTrue);
    });
  });
}
