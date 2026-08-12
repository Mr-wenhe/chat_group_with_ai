// ignore_for_file: prefer_const_constructors, prefer_const_declarations

import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  group('MemoryConversationScope', () {
    PermanentMemory memory({
      required String content,
      String observer = 'a',
      List<String> subjectIds = const ['user'],
      MemoryKind kind = MemoryKind.fact,
      MemoryStatus status = MemoryStatus.active,
      MemoryOriginType originType = MemoryOriginType.group,
      String? originConversationId = 'cross-source',
    }) {
      return PermanentMemory(
        observerCharacterId: observer,
        kind: kind,
        content: content,
        subjectIds: subjectIds,
        status: status,
        originType: originType,
        originConversationId: originConversationId,
        originNameSnapshot: '来源场合',
      );
    }

    final aboutUser = PermanentMemory(
      observerCharacterId: 'a',
      kind: MemoryKind.fact,
      content: '用户喜欢咖啡',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '别的群',
    );
    final aboutMember = PermanentMemory(
      observerCharacterId: 'a',
      kind: MemoryKind.fact,
      content: 'B喜欢茶',
      subjectIds: const ['b'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '别的群',
    );
    final aboutOutsider = PermanentMemory(
      observerCharacterId: 'a',
      kind: MemoryKind.fact,
      content: '群外角色喜欢水',
      subjectIds: const ['outside'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '别的群',
    );

    test('direct chat shows only the target AI memories about the user', () {
      final scope = MemoryConversationScope.direct('a');

      expect(scope.apply([aboutUser, aboutMember]), [aboutUser]);
    });

    test('group chat includes cross-occasion memories for current members', () {
      final scope = MemoryConversationScope.group({'a', 'b'});

      expect(scope.apply([aboutUser, aboutMember, aboutOutsider]),
          [aboutUser, aboutMember]);
    });

    test('scope read-only permission follows the entry point table', () {
      final cases = [
        (scope: MemoryConversationScope.settings(), readOnly: false),
        (scope: MemoryConversationScope.direct('a'), readOnly: true),
        (scope: MemoryConversationScope.group({'a', 'b'}), readOnly: true),
      ];

      for (final testCase in cases) {
        expect(testCase.scope.isReadOnly, testCase.readOnly);
      }
    });

    test('scope exposes only the entry-safe observer and subject candidates',
        () {
      final settings = MemoryConversationScope.settings();
      final direct = MemoryConversationScope.direct('a');
      final group = MemoryConversationScope.group({'a', 'b'});

      expect(settings.allowedObserverCharacterIds, isNull);
      expect(settings.allowedSubjectIds, isNull);
      expect(direct.allowedObserverCharacterIds, {'a'});
      expect(direct.allowedSubjectIds, {'user'});
      expect(direct.subjectIdsForObserver('b'), isEmpty);
      expect(group.allowedObserverCharacterIds, {'a', 'b'});
      expect(group.allowedSubjectIds, {'user', 'a', 'b'});
      expect(group.subjectIdsForObserver('a'), {'user', 'b'});
      expect(group.subjectIdsForObserver('outside'), isEmpty);
    });

    final scopeCases = [
      (
        name: 'settings keeps every observer, object, status, and source',
        scope: MemoryConversationScope.settings(),
        memories: [
          memory(content: '当前 AI 关于用户'),
          memory(
            content: '历史状态',
            observer: 'outside-observer',
            subjectIds: const ['outside-subject'],
            status: MemoryStatus.superseded,
          ),
        ],
        visible: ['当前 AI 关于用户', '历史状态'],
      ),
      (
        name: 'direct keeps current AI memories that include the user',
        scope: MemoryConversationScope.direct('a'),
        memories: [
          memory(content: '有效用户记忆'),
          memory(content: '已取代用户记忆', status: MemoryStatus.superseded),
          memory(content: '已失效用户记忆', status: MemoryStatus.invalidated),
          memory(content: '混合主体', subjectIds: const ['user', 'b']),
          memory(content: '只有其他角色', subjectIds: const ['b']),
          memory(content: '其他 AI 的用户记忆', observer: 'b'),
          memory(content: '无主体记录', subjectIds: const []),
        ],
        visible: [
          '有效用户记忆',
          '已取代用户记忆',
          '已失效用户记忆',
          '混合主体',
        ],
      ),
      (
        name: 'group keeps current observers and allowed cross-source subjects',
        scope: MemoryConversationScope.group({'a', 'b'}),
        memories: [
          memory(content: '用户记忆', originConversationId: 'other-group'),
          memory(content: '群内其他 AI 记忆', subjectIds: const ['b']),
          memory(content: '允许的多主体', subjectIds: const ['user', 'b']),
          memory(
            content: '无主体成长',
            kind: MemoryKind.personaGrowth,
            subjectIds: const [],
            originConversationId: 'dm:b',
          ),
          memory(content: '普通空主体', subjectIds: const []),
          memory(
            content: 'personaGrowth 自身成长',
            kind: MemoryKind.personaGrowth,
            subjectIds: const ['a'],
          ),
          memory(content: '观察 AI 自身普通主体', subjectIds: const ['a']),
          memory(
            content: '混合群外主体',
            subjectIds: const ['b', 'outside-subject'],
          ),
          memory(
            content: '群外观察 AI',
            observer: 'outside-observer',
            subjectIds: const ['user'],
          ),
          memory(
            content: 'personaGrowth 含群外主体',
            kind: MemoryKind.personaGrowth,
            subjectIds: const ['a', 'outside-subject'],
          ),
        ],
        visible: [
          '用户记忆',
          '群内其他 AI 记忆',
          '允许的多主体',
          '无主体成长',
          'personaGrowth 自身成长',
        ],
      ),
    ];

    for (final testCase in scopeCases) {
      test(testCase.name, () {
        final visible = testCase.scope.apply(testCase.memories);

        expect(
          visible.map((item) => item.content),
          testCase.visible,
        );
      });
    }
  });

  group('MemoryAuditFilter', () {
    test('isEmpty returns true for default filter', () {
      expect(MemoryAuditFilter().isEmpty, isTrue);
    });

    test('apply without filters returns all memories', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c2',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originNameSnapshot: 'dm',
        ),
      ];
      final result = MemoryAuditFilter().apply(memories);
      expect(result.length, 2);
    });

    test('search matches content and friendly source name, not source IDs', () {
      final memories = [
        PermanentMemory(
          id: 'coffee',
          observerCharacterId: 'c1',
          kind: MemoryKind.preference,
          content: '用户喜欢咖啡',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'group-uuid-1',
          originNameSnapshot: '旅行群',
        ),
        PermanentMemory(
          id: 'tea',
          observerCharacterId: 'c1',
          kind: MemoryKind.preference,
          content: '用户喜欢茶',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'group-uuid-2',
          originNameSnapshot: '读书群',
        ),
      ];

      expect(
        MemoryAuditFilter(searchQuery: ' 咖啡 ').apply(memories),
        [memories.first],
      );
      expect(
        MemoryAuditFilter(searchQuery: '旅行群').apply(memories),
        [memories.first],
      );
      expect(
        MemoryAuditFilter(searchQuery: 'group-uuid-1').apply(memories),
        isEmpty,
      );
    });

    test('search ignores IDs wrapped in legacy source snapshots', () {
      final memories = [
        PermanentMemory(
          id: 'legacy-direct',
          observerCharacterId: 'c1',
          kind: MemoryKind.preference,
          content: '正文',
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originConversationId: 'dm:character-id',
          originNameSnapshot: '私聊:character-id',
        ),
        PermanentMemory(
          id: 'legacy-group',
          observerCharacterId: 'c1',
          kind: MemoryKind.preference,
          content: '正文',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'group-id',
          originNameSnapshot: '群聊:group-id',
        ),
      ];

      expect(
        MemoryAuditFilter(searchQuery: 'character-id').apply(memories),
        isEmpty,
      );
      expect(
        MemoryAuditFilter(searchQuery: 'group-id').apply(memories),
        isEmpty,
      );
    });

    test('search accepts a friendly projection for observer and subject names',
        () {
      final memory = PermanentMemory(
        id: 'amy-memory',
        observerCharacterId: 'character-id',
        kind: MemoryKind.preference,
        content: '用户喜欢咖啡',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '旅行群',
      );

      final result = MemoryAuditFilter(searchQuery: 'Amy').apply(
        [memory],
        searchText: (_) => const MemoryAuditSearchProjection(
          content: '用户喜欢咖啡',
          observerName: 'Amy',
          subjectNames: ['用户'],
          originName: '旅行群',
          kindLabel: '偏好',
          statusLabel: '有效',
        ),
      );

      expect(result, [memory]);
    });

    test('search projection contract covers every user-visible search field',
        () {
      final memory = PermanentMemory(
        id: 'projection-memory',
        observerCharacterId: 'observer-id',
        kind: MemoryKind.preference,
        content: '正文字段',
        subjectIds: const ['user', 'subject-id'],
        status: MemoryStatus.invalidated,
        originType: MemoryOriginType.group,
        originNameSnapshot: '来源快照',
      );
      MemoryAuditSearchProjection projection(PermanentMemory _) {
        return const MemoryAuditSearchProjection(
          content: '正文字段',
          observerName: '观察者名称',
          subjectNames: ['用户名称', '对象名称'],
          originName: '来源名称',
          kindLabel: '偏好',
          statusLabel: '已失效',
        );
      }

      final queries = [
        '正文字段',
        '观察者名称',
        '用户名称',
        '对象名称',
        '来源名称',
        '偏好',
        '已失效',
      ];
      for (final query in queries) {
        expect(
          MemoryAuditFilter(searchQuery: query).apply(
            [memory],
            searchText: projection,
          ),
          [memory],
          reason: 'query should search the projection field: $query',
        );
      }
    });

    test('default search includes localized kind and status labels', () {
      final memory = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.preference,
        content: '正文',
        status: MemoryStatus.invalidated,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动',
      );

      expect(
        MemoryAuditFilter(searchQuery: '偏好').apply([memory]),
        [memory],
      );
      expect(
        MemoryAuditFilter(searchQuery: '已失效').apply([memory]),
        [memory],
      );
    });

    test('default search includes localized origin labels, not enum names', () {
      final memory = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.preference,
        content: '正文',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '旅行群',
      );

      expect(
        MemoryAuditFilter(searchQuery: '群聊').apply([memory]),
        [memory],
      );
      expect(
        MemoryAuditFilter(searchQuery: 'group').apply([memory]),
        isEmpty,
      );
      expect(
        MemoryAuditFilter(searchQuery: 'preference').apply([memory]),
        isEmpty,
      );
    });

    test('active sorting keeps legacy migration records in history order', () {
      final time = DateTime(2026, 1, 1);
      PermanentMemory item({
        required String id,
        required MemoryOriginType origin,
      }) {
        return PermanentMemory(
          id: id,
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: id,
          status: MemoryStatus.active,
          originType: origin,
          originNameSnapshot: '来源',
          occurredAt: time,
          createdAt: time,
          updatedAt: time,
        );
      }

      final result = MemoryAuditFilter().apply([
        item(id: 'current', origin: MemoryOriginType.manual),
        item(id: 'legacy', origin: MemoryOriginType.legacyMigration),
      ]);

      expect(result.map((memory) => memory.id), ['current', 'legacy']);
    });

    test('default search uses the Chinese name 事实 for fact memories', () {
      final memory = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '正文',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动',
      );

      expect(
        MemoryAuditFilter(searchQuery: '事实').apply([memory]),
        [memory],
      );
    });

    test('sorts pinned, status, and timestamps with stable ID tie-breakers',
        () {
      final sameTime = DateTime(2026, 1, 1);
      PermanentMemory item({
        required String id,
        required String content,
        required DateTime updatedAt,
        bool pinned = false,
        MemoryStatus status = MemoryStatus.active,
      }) {
        return PermanentMemory(
          id: id,
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: content,
          status: status,
          originType: MemoryOriginType.manual,
          originNameSnapshot: '手动',
          occurredAt: updatedAt,
          createdAt: updatedAt,
          updatedAt: updatedAt,
          pinned: pinned,
        );
      }

      final memories = [
        item(id: 'b', content: '同时间 B', updatedAt: sameTime),
        item(
            id: 'old',
            content: '旧有效',
            updatedAt: sameTime.subtract(const Duration(days: 1))),
        item(
            id: 'pinned',
            content: '固定旧记录',
            updatedAt: sameTime.subtract(const Duration(days: 2)),
            pinned: true),
        item(
            id: 'history',
            content: '历史记录',
            updatedAt: sameTime.add(const Duration(days: 1)),
            status: MemoryStatus.superseded),
        item(id: 'a', content: '同时间 A', updatedAt: sameTime),
      ];

      final result = MemoryAuditFilter().apply(memories);

      expect(
        result.map((memory) => memory.id),
        ['pinned', 'a', 'b', 'old', 'history'],
      );
    });

    test('sortOrder can use occurredAt independently of updatedAt', () {
      final olderOccurrence = PermanentMemory(
        id: 'older-occurrence',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '更早发生但更新较晚',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动',
        occurredAt: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 10),
      );
      final newerOccurrence = PermanentMemory(
        id: 'newer-occurrence',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '更晚发生但更新较早',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动',
        occurredAt: DateTime(2026, 1, 2),
        createdAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 3),
      );

      final result = MemoryAuditFilter(
        sortOrder: MemoryAuditSortOrder.occurredAtDescending,
      ).apply([olderOccurrence, newerOccurrence]);

      expect(result.map((memory) => memory.id), [
        'newer-occurrence',
        'older-occurrence',
      ]);
    });

    test('history sorting remains based on updatedAt', () {
      PermanentMemory history({
        required String id,
        required DateTime occurredAt,
        required DateTime updatedAt,
        MemoryStatus status = MemoryStatus.superseded,
      }) {
        return PermanentMemory(
          id: id,
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: id,
          status: status,
          originType: MemoryOriginType.manual,
          originNameSnapshot: '手动',
          occurredAt: occurredAt,
          createdAt: occurredAt,
          updatedAt: updatedAt,
        );
      }

      final occurredLater = history(
        id: 'occurred-later',
        occurredAt: DateTime(2026, 1, 10),
        updatedAt: DateTime(2026, 1, 1),
      );
      final updatedLater = history(
        id: 'updated-later',
        occurredAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 10),
      );
      final invalidatedLater = history(
        id: 'invalidated-later',
        occurredAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 11),
        status: MemoryStatus.invalidated,
      );

      final result = MemoryAuditFilter(
        sortOrder: MemoryAuditSortOrder.occurredAtDescending,
      ).apply([occurredLater, updatedLater, invalidatedLater]);

      expect(result.map((memory) => memory.id),
          ['invalidated-later', 'updated-later', 'occurred-later']);
    });

    test('page state preserves scope and browsing state when one field changes',
        () {
      final scope = MemoryConversationScope.group({'a', 'b'});
      final filter = MemoryAuditFilter(
        searchQuery: '咖啡',
        sortOrder: MemoryAuditSortOrder.occurredAtDescending,
      );
      final state = MemoryAuditPageState(
        scope: scope,
        filter: filter,
        historyExpanded: true,
        scrollOffset: 128,
      );

      final changed = state.copyWith(scrollOffset: 256);

      expect(changed.scope, same(scope));
      expect(changed.filter, same(filter));
      expect(changed.historyExpanded, isTrue);
      expect(changed.scrollOffset, 256);
    });

    test('scope is applied before a user filter and cannot be widened', () {
      final scope = MemoryConversationScope.group({'a', 'b'});
      final memories = [
        PermanentMemory(
          observerCharacterId: 'a',
          kind: MemoryKind.fact,
          content: '群外来源但主体合法',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originConversationId: 'dm:outside',
          originNameSnapshot: '其他私聊',
        ),
        PermanentMemory(
          observerCharacterId: 'outside',
          kind: MemoryKind.fact,
          content: '群外观察者',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g-outside',
          originNameSnapshot: '群外',
        ),
        PermanentMemory(
          observerCharacterId: 'a',
          kind: MemoryKind.fact,
          content: '群外主体',
          subjectIds: const ['outside'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g-outside',
          originNameSnapshot: '群外',
        ),
      ];

      final cases = [
        (
          filter: const MemoryAuditFilter(observerCharacterId: 'outside'),
          visible: <String>[],
        ),
        (
          filter: MemoryAuditFilter(
            subjectFilter: SubjectFilter.aboutCharacter('outside'),
          ),
          visible: <String>[],
        ),
        (
          filter: const MemoryAuditFilter(originConversationId: 'dm:outside'),
          visible: ['群外来源但主体合法'],
        ),
      ];

      for (final testCase in cases) {
        final result = testCase.filter.apply(memories, scope: scope);
        expect(result.map((item) => item.content), testCase.visible);
      }
    });

    test('search runs after scope and user filters', () {
      final scope = MemoryConversationScope.group({'a', 'b'});
      final excludedByObserver = PermanentMemory(
        id: 'excluded-observer',
        observerCharacterId: 'b',
        kind: MemoryKind.fact,
        content: '命中但观察者不匹配',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊',
      );
      final excludedByScope = PermanentMemory(
        id: 'excluded-scope',
        observerCharacterId: 'outside',
        kind: MemoryKind.fact,
        content: '命中但超出入口范围',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群外',
      );
      final included = PermanentMemory(
        id: 'included',
        observerCharacterId: 'a',
        kind: MemoryKind.fact,
        content: '命中且符合范围',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊',
      );
      final projectedIds = <String>[];
      MemoryAuditSearchProjection project(PermanentMemory memory) {
        projectedIds.add(memory.id);
        return MemoryAuditSearchProjection(
          content: memory.content,
          observerName: memory.observerCharacterId,
          subjectNames: const [],
          originName: memory.originNameSnapshot,
          kindLabel: '事实',
          statusLabel: '有效',
        );
      }

      final result = MemoryAuditFilter(
        observerCharacterId: 'a',
        searchQuery: '命中',
      ).apply(
        [excludedByObserver, excludedByScope, included],
        scope: scope,
        searchText: project,
      );

      expect(result, [included]);
      expect(projectedIds, ['included']);
    });

    test('apply filters by observerCharacterId', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c2',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result =
          MemoryAuditFilter(observerCharacterId: 'c1').apply(memories);
      expect(result.length, 1);
      expect(result.first.observerCharacterId, 'c1');
    });

    test('apply filters by status', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.superseded,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result =
          MemoryAuditFilter(status: MemoryStatus.active).apply(memories);
      expect(result.length, 1);
      expect(result.first.status, MemoryStatus.active);
    });

    test('apply filters by originType', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.manual,
          originNameSnapshot: 'manual',
        ),
      ];
      final result = MemoryAuditFilter(originType: MemoryOriginType.manual)
          .apply(memories);
      expect(result.length, 1);
      expect(result.first.originType, MemoryOriginType.manual);
    });

    test('apply filters by memoryKind', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.preference,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
        ),
      ];
      final result =
          MemoryAuditFilter(memoryKind: MemoryKind.preference).apply(memories);
      expect(result.length, 1);
      expect(result.first.kind, MemoryKind.preference);
    });

    test('apply filters pinnedOnly true', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: false,
        ),
      ];
      final result = MemoryAuditFilter(pinnedOnly: true).apply(memories);
      expect(result.length, 1);
      expect(result.first.pinned, isTrue);
    });

    test('pinnedOnly false filters pinned out', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: false,
        ),
      ];
      final result = MemoryAuditFilter(pinnedOnly: false).apply(memories);
      expect(result.length, 1);
      expect(result.first.pinned, isFalse);
    });

    test('subjectFilter aboutMe matches user subjectIds', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['c2'],
        ),
      ];
      final result = MemoryAuditFilter(subjectFilter: SubjectFilter.aboutMe())
          .apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, contains('user'));
    });

    test('subjectFilter aboutCharacter matches given id', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['c2'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['c3'],
        ),
      ];
      final result =
          MemoryAuditFilter(subjectFilter: SubjectFilter.aboutCharacter('c2'))
              .apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, contains('c2'));
    });

    test('subjectFilter selfGrowth matches empty subjectIds', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.personaGrowth,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const [],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '无主体普通记录',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const [],
        ),
      ];
      final result =
          MemoryAuditFilter(subjectFilter: SubjectFilter.selfGrowth())
              .apply(memories);
      expect(result.length, 1);
      expect(result.first.subjectIds, isEmpty);
      expect(result.first.kind, MemoryKind.personaGrowth);
    });

    test('subjectFilter selfGrowth includes personaGrowth with subjects', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.personaGrowth,
          content: '成长也涉及用户',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '普通事实',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          subjectIds: const ['user'],
        ),
      ];

      final result = MemoryAuditFilter(
        subjectFilter: SubjectFilter.selfGrowth(),
      ).apply(memories);

      expect(result.map((memory) => memory.content), ['成长也涉及用户']);
    });

    test('apply filters by origin conversation id', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '群一',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g1',
          originNameSnapshot: '群一',
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '群二',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originConversationId: 'g2',
          originNameSnapshot: '群二',
        ),
      ];

      final result = MemoryAuditFilter(
        originConversationId: 'g2',
      ).apply(memories);

      expect(result.map((memory) => memory.content), ['群二']);
    });

    test('filters combine with AND', () {
      final memories = [
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'a',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: 'b',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: false,
          subjectIds: const ['user'],
        ),
        PermanentMemory(
          observerCharacterId: 'c2',
          kind: MemoryKind.fact,
          content: 'c',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: 'g1',
          pinned: true,
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

    test('copyWith clear semantics — clearObserverCharacterId resets to null',
        () {
      final f = MemoryAuditFilter(
          observerCharacterId: 'c1', status: MemoryStatus.active);
      final cleared = f.copyWith(clearObserverCharacterId: true);
      expect(cleared.observerCharacterId, isNull);
      expect(cleared.status, MemoryStatus.active);
    });

    test('copyWith clear semantics — clearStatus resets to null', () {
      final f = MemoryAuditFilter(
          observerCharacterId: 'c1', status: MemoryStatus.active);
      final cleared = f.copyWith(clearStatus: true);
      expect(cleared.status, isNull);
      expect(cleared.observerCharacterId, 'c1');
    });

    test('copyWith clear semantics — all clear produces empty filter', () {
      final f = MemoryAuditFilter(
        observerCharacterId: 'c1',
        status: MemoryStatus.active,
        memoryKind: MemoryKind.fact,
        originType: MemoryOriginType.group,
        originConversationId: 'g1',
        pinnedOnly: true,
        subjectFilter: SubjectFilter.aboutMe(),
      );
      final cleared = f.copyWith(
        clearObserverCharacterId: true,
        clearStatus: true,
        clearMemoryKind: true,
        clearOriginType: true,
        clearOriginConversationId: true,
        clearPinnedOnly: true,
        clearSubjectFilter: true,
      );
      expect(cleared.isEmpty, isTrue);
    });
  });

  group('MemoryAuditFilterWidget', () {
    testWidgets('renders one transactional trigger without a tag wall',
        (tester) async {
      await tester.pumpWidget(_filterApp(
        filter: const MemoryAuditFilter(),
        characters: [testCharacter('c1', apiConfigId: 'cfg')],
      ));

      expect(find.byKey(const ValueKey('open-advanced-memory-filter')),
          findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byKey(const ValueKey('memory-audit-search')), findsOneWidget);
      expect(
          tester
              .getSize(
                  find.byKey(const ValueKey('open-advanced-memory-filter')))
              .height,
          greaterThanOrEqualTo(44));
    });

    testWidgets('cancel and barrier close do not apply the draft',
        (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(_filterApp(
        filter: const MemoryAuditFilter(status: MemoryStatus.active),
        onChanged: (filter) => captured = filter,
      ));

      await _openAdvanced(tester);
      await tester.ensureVisible(
          find.byKey(const ValueKey('memory-filter-dialog-status')));
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已取代').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(captured, isNull);

      await _openAdvanced(tester);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(captured, isNull);
    });

    testWidgets('reset changes only the draft until apply', (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(_filterApp(
        filter: MemoryAuditFilter(
          status: MemoryStatus.active,
          memoryKind: MemoryKind.fact,
        ),
        onChanged: (filter) => captured = filter,
      ));

      await _openAdvanced(tester);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(captured, isNull);
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.isEmpty, isTrue);
      expect(captured!.status, isNull);
      expect(captured!.memoryKind, isNull);
    });

    testWidgets('apply emits the changed filter once', (tester) async {
      var applyCount = 0;
      MemoryAuditFilter? captured;
      await tester.pumpWidget(_filterApp(
        onChanged: (filter) {
          applyCount++;
          captured = filter;
        },
      ));

      await _openAdvanced(tester);
      await tester.ensureVisible(
          find.byKey(const ValueKey('memory-filter-dialog-status')));
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已取代').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();

      expect(applyCount, 1);
      expect(captured?.status, MemoryStatus.superseded);
    });

    testWidgets('searchable selectors use friendly names and search text',
        (tester) async {
      final chars = [testCharacter('c1'), testCharacter('c2')];
      await tester.pumpWidget(_filterApp(
        characters: chars,
        originConversations: const {'g1': '群一', 'g2': '群二'},
      ));

      await _openAdvanced(tester);
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-observer')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '角色c2');
      await tester.pumpAndSettle();
      expect(find.text('角色c2'), findsOneWidget);
      expect(find.text('c2'), findsNothing);
      await tester.tap(find.text('角色c2').last);

      await tester.ensureVisible(
          find.byKey(const ValueKey('memory-filter-dialog-subject')));
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-subject')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '角色c1');
      await tester.pumpAndSettle();
      expect(find.text('角色c1'), findsOneWidget);
      expect(find.text('c1'), findsNothing);
      await tester.tap(find.text('角色c1').last);

      await tester.ensureVisible(find
          .byKey(const ValueKey('memory-filter-dialog-origin-conversation')));
      await tester.tap(find
          .byKey(const ValueKey('memory-filter-dialog-origin-conversation')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '群二');
      await tester.pumpAndSettle();
      expect(find.text('群二'), findsOneWidget);
      expect(find.text('g2'), findsNothing);
    });

    testWidgets('scope hides fixed direct fields and limits group candidates',
        (tester) async {
      final chars = [
        testCharacter('a'),
        testCharacter('b'),
        testCharacter('outside'),
      ];
      await tester.pumpWidget(_filterApp(
        characters: chars,
        scope: MemoryConversationScope.direct('a'),
      ));
      await _openAdvanced(tester);
      expect(find.byKey(const ValueKey('memory-filter-dialog-observer')),
          findsNothing);
      expect(find.byKey(const ValueKey('memory-filter-dialog-subject')),
          findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_filterApp(
        characters: chars,
        scope: MemoryConversationScope.group({'a', 'b'}),
      ));
      await _openAdvanced(tester);
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-observer')));
      await tester.pumpAndSettle();
      expect(find.text('角色a'), findsOneWidget);
      expect(find.text('角色b'), findsOneWidget);
      expect(find.text('角色outside'), findsNothing);
      await tester.tap(find.text('角色a').last);
      await tester.ensureVisible(
          find.byKey(const ValueKey('memory-filter-dialog-subject')));
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-subject')));
      await tester.pumpAndSettle();
      expect(find.text('角色b'), findsOneWidget);
      expect(find.text('角色outside'), findsNothing);
    });

    testWidgets('small filter dimensions use labeled standard controls',
        (tester) async {
      await tester.pumpWidget(_filterApp(
        originConversations: const {'g1': '群一'},
      ));
      await _openAdvanced(tester);

      for (final key in const [
        'memory-filter-dialog-origin-type',
        'memory-filter-dialog-status',
        'memory-filter-dialog-kind',
        'memory-filter-dialog-pinned',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('来源方式'), findsOneWidget);
      expect(find.text('记忆状态'), findsOneWidget);
      expect(find.text('记忆类型'), findsOneWidget);
      expect(find.text('固定状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deleted selector values use friendly placeholders',
        (tester) async {
      await tester.pumpWidget(_filterApp(
        filter: MemoryAuditFilter(
          observerCharacterId: 'deleted-observer',
          subjectFilter: SubjectFilter.aboutCharacter('deleted-subject'),
          originConversationId: 'deleted-group',
        ),
        originConversations: const {'existing-group': '群一'},
      ));

      await _openAdvanced(tester);
      expect(find.text('已删除角色'), findsWidgets);
      expect(find.text('deleted-observer'), findsNothing);
      expect(find.text('deleted-subject'), findsNothing);
      expect(find.text('已删除群聊'), findsOneWidget);
      expect(find.text('deleted-group'), findsNothing);
    });

    testWidgets('empty source candidates show an explicit empty state',
        (tester) async {
      await tester.pumpWidget(_filterApp(
        characters: const [],
        originConversations: const {},
      ));

      await _openAdvanced(tester);
      expect(find.text('暂无可选来源场合'), findsOneWidget);
      expect(
          find.byKey(
              const ValueKey('memory-filter-dialog-origin-conversation')),
          findsOneWidget);
    });

    testWidgets('narrow keyboard keeps actions above the view inset',
        (tester) async {
      MemoryAuditFilter? captured;
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(_filterApp(
        characters: [testCharacter('observer')],
        originConversations: const {'g1': '群一'},
        onChanged: (filter) => captured = filter,
      ));
      await _openAdvanced(tester);
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-observer')));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, '角色');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();

      final visibleBottom = 800 - 320;
      for (final key in const [
        'memory-filter-dialog-reset',
        'memory-filter-dialog-cancel',
        'memory-filter-dialog-apply',
      ]) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        expect(tester.getRect(find.byKey(ValueKey(key))).bottom,
            lessThanOrEqualTo(visibleBottom));
      }
      expect(tester.takeException(), isNull);
      await tester
          .tap(find.byKey(const ValueKey('memory-filter-dialog-apply')));
      await tester.pumpAndSettle();
      expect(captured, isNotNull);
    });

    testWidgets('filter dialog exposes keyboard traversal and semantics',
        (tester) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(_filterApp(
        characters: [testCharacter('observer')],
        originConversations: const {'g1': '群一'},
      ));
      await _openAdvanced(tester);

      for (final label in const [
        '观察 AI，可输入搜索',
        '记忆对象，可输入搜索',
        '来源场合，可输入搜索',
      ]) {
        final key = switch (label) {
          '观察 AI，可输入搜索' => 'memory-filter-dialog-observer',
          '记忆对象，可输入搜索' => 'memory-filter-dialog-subject',
          _ => 'memory-filter-dialog-origin-conversation',
        };
        expect(tester.getSemantics(find.byKey(ValueKey(key))).label,
            contains(label));
      }
      for (final key in const [
        'memory-filter-dialog-reset',
        'memory-filter-dialog-cancel',
        'memory-filter-dialog-apply',
      ]) {
        expect(tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(44));
      }

      final resetFocus = _buttonFocusNode(
          tester, find.byKey(const ValueKey('memory-filter-dialog-reset')));
      resetFocus.requestFocus();
      await tester.pump();
      final initialFocus = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(same(initialFocus)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(initialFocus));
      semantics.dispose();
    });

    testWidgets('filter buttons activate with Enter and Space', (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(_filterApp(
        filter: const MemoryAuditFilter(status: MemoryStatus.active),
        onChanged: (filter) => captured = filter,
      ));
      await _openAdvanced(tester);

      final applyFocus = _buttonFocusNode(
          tester, find.byKey(const ValueKey('memory-filter-dialog-apply')));
      applyFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(captured?.status, MemoryStatus.active);

      await _openAdvanced(tester);
      final cancelFocus = _buttonFocusNode(
          tester, find.byKey(const ValueKey('memory-filter-dialog-cancel')));
      cancelFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('narrow screens use the same content in a bottom sheet',
        (tester) async {
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_filterApp());
      await _openAdvanced(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('memory-filter-dialog-status')),
          findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(
          tester
              .getSemantics(
                  find.byKey(const ValueKey('memory-filter-dialog-close')))
              .label,
          contains('关闭'));
      semantics.dispose();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('desktop escape closes without applying', (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(_filterApp(
        onChanged: (filter) => captured = filter,
      ));
      await _openAdvanced(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(captured, isNull);
    });
  });
}

Widget _filterApp({
  MemoryAuditFilter filter = const MemoryAuditFilter(),
  List<AICharacter> characters = const [],
  Map<String, String> originConversations = const {},
  MemoryConversationScope scope = const MemoryConversationScope.settings(),
  ValueChanged<MemoryAuditFilter>? onChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MemoryAuditFilterWidget(
        filter: filter,
        characters: characters,
        originConversations: originConversations,
        scope: scope,
        onChanged: onChanged ?? (_) {},
      ),
    ),
  );
}

Future<void> _openAdvanced(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-advanced-memory-filter')));
  await tester.pumpAndSettle();
}

FocusNode _buttonFocusNode(WidgetTester tester, Finder button) {
  final focusFinder = find.descendant(of: button, matching: find.byType(Focus));
  expect(focusFinder, findsWidgets);
  return (tester.state(focusFinder.last) as dynamic).focusNode as FocusNode;
}
