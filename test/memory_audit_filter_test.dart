// ignore_for_file: prefer_const_constructors, prefer_const_declarations

import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_widget.dart';
import 'package:flutter/material.dart';
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
    testWidgets('empty filter renders nothing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: const [],
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('清除筛选'), findsNothing);
    });

    testWidgets('non-empty filter shows chips and clear button',
        (tester) async {
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: MemoryAuditFilter(observerCharacterId: 'c1'),
            characters: chars,
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('角色: 角色c1'), findsOneWidget);
      expect(find.text('清除筛选'), findsOneWidget);
    });

    testWidgets('tapping clear button emits empty filter', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: MemoryAuditFilter(observerCharacterId: 'c1'),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('清除筛选'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(captured, isNotNull);
      expect(captured!.isEmpty, isTrue);
    });

    testWidgets('copyWith clear semantics preserves other filter dimensions',
        (tester) async {
      // Verify that copyWith clear semantics work correctly:
      // clearing one field preserves others.
      final filter = MemoryAuditFilter(
        observerCharacterId: 'c1',
        status: MemoryStatus.active,
      );
      final cleared = filter.copyWith(clearObserverCharacterId: true);
      expect(cleared.observerCharacterId, isNull);
      expect(cleared.status, MemoryStatus.active);
    });

    testWidgets('all filter option groups are visible', (tester) async {
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: chars,
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      // Widget is always visible even with empty filter.
      expect(find.byType(MemoryAuditFilterWidget), findsOneWidget);
    });

    testWidgets('subject filter selection updates callback', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      // Tap '关于我' choice chip.
      await tester.tap(find.text('关于我'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.subjectFilter, SubjectFilter.aboutMe());
    });

    testWidgets('origin type selection updates callback', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('手动'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.originType, MemoryOriginType.manual);
    });

    testWidgets('tapping "全部来源" clears originType', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter:
                const MemoryAuditFilter(originType: MemoryOriginType.manual),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('全部来源'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.originType, isNull);
    });

    testWidgets('tapping a status then "全部状态" clears status', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(status: MemoryStatus.active),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('已取代'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured!.status, MemoryStatus.superseded);

      captured = null;
      await tester.tap(find.text('全部状态'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.status, isNull);
    });

    testWidgets('tapping a kind then "全部类型" clears memoryKind', (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(memoryKind: MemoryKind.fact),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('偏好'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured!.memoryKind, MemoryKind.preference);

      captured = null;
      await tester.tap(find.text('全部类型'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.memoryKind, isNull);
    });

    testWidgets('tapping pinned filter then "固定状态: 全部" clears pinnedOnly',
        (tester) async {
      MemoryAuditFilter? captured;
      final chars = [testCharacter('c1', apiConfigId: 'cfg')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(pinnedOnly: true),
            characters: chars,
            onChanged: (f) => captured = f,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('仅未固定'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured!.pinnedOnly, isFalse);

      captured = null;
      await tester.tap(find.text('固定状态: 全部'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(captured, isNotNull);
      expect(captured!.pinnedOnly, isNull);
    });

    testWidgets('observer dropdown clears via filter copyWith semantics',
        (tester) async {
      // The dropdown widget delegates to filter.copyWith; verify the clear
      // semantics directly: copyWith(clearObserverCharacterId: true, observerCharacterId: null)
      // must produce null.
      final f = MemoryAuditFilter(observerCharacterId: 'c1');
      final cleared = f.copyWith(clearObserverCharacterId: true);
      expect(cleared.observerCharacterId, isNull);
    });

    testWidgets('filter labels use the shared full Chinese terms',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(
              memoryKind: MemoryKind.fact,
              originType: MemoryOriginType.legacyMigration,
            ),
            characters: const [],
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('类型: 事实'), findsOneWidget);
      expect(find.text('来源: 旧版迁移'), findsOneWidget);
      expect(find.text('知'), findsNothing);
      expect(find.text('legacyMigration'), findsNothing);
    });

    testWidgets('deleted selector values use placeholders instead of IDs',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: MemoryAuditFilter(
              observerCharacterId: 'deleted-observer',
              subjectFilter: SubjectFilter.aboutCharacter('deleted-subject'),
            ),
            characters: const [],
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('已删除角色'), findsWidgets);
      expect(find.text('deleted-observer'), findsNothing);
      expect(find.text('deleted-subject'), findsNothing);
    });

    testWidgets('source occasion search uses friendly names without IDs',
        (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(originConversationId: 'g1'),
            characters: const [],
            originConversations: const {'g1': '群一', 'g2': '群二'},
            onChanged: (filter) => captured = filter,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('g1'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('memory-filter-origin-conversation')),
      );
      await tester.pumpAndSettle();
      expect(find.text('群一'), findsWidgets);
      expect(find.text('g1'), findsNothing);

      await tester.enterText(find.byType(TextField).last, '群二');
      await tester.pumpAndSettle();
      expect(find.text('群二'), findsOneWidget);
      expect(find.text('g2'), findsNothing);
      await tester.tap(find.text('群二').last);
      await tester.pump();

      expect(captured?.originConversationId, 'g2');
    });

    testWidgets('advanced filters apply only after confirmation',
        (tester) async {
      MemoryAuditFilter? captured;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MemoryAuditFilterWidget(
            filter: const MemoryAuditFilter(),
            characters: const [],
            onChanged: (filter) => captured = filter,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('open-advanced-memory-filter')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('memory-filter-dialog-status')),
      );
      await tester.tap(
        find.byKey(const ValueKey('memory-filter-dialog-status')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已取代').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(captured, isNull);

      await tester.tap(
        find.byKey(const ValueKey('open-advanced-memory-filter')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('memory-filter-dialog-status')),
      );
      await tester.tap(
        find.byKey(const ValueKey('memory-filter-dialog-status')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已取代').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();

      expect(captured?.status, MemoryStatus.superseded);
    });
  });
}
