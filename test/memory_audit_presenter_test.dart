import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers current observer, subject, and conversation names', () {
    final memory = _memory(
      observer: 'observer-id',
      subjects: const ['subject-id', 'user'],
      conversationId: 'group-id',
      snapshot: '旧群名',
    );

    final row = MemoryAuditPresenter(
      characterNames: const {
        'observer-id': '当前观察 AI',
        'subject-id': '当前对象',
      },
      conversationNames: const {'group-id': '当前群名'},
    ).present(memory);

    expect(row.observerName, '当前观察 AI');
    expect(row.subjectNames, ['当前对象', '我']);
    expect(row.originName, '当前群名');
  });

  test('uses deleted character and conversation snapshots without IDs', () {
    final row = MemoryAuditPresenter(
      characterSnapshotNames: const {
        'deleted-observer': '旧观察 AI',
        'deleted-subject': '旧对象',
      },
    ).present(
      _memory(
        observer: 'deleted-observer',
        subjects: const ['deleted-subject'],
        conversationId: 'deleted-group-id',
        snapshot: '旧群聊',
      ),
    );

    expect(row.observerName, '旧观察 AI');
    expect(row.subjectNames, ['旧对象']);
    expect(row.originName, '旧群聊');
    expect(row.userVisibleText, isNot(contains('deleted-')));
  });

  test('uses explicit deleted placeholders when no snapshot exists', () {
    final presenter = MemoryAuditPresenter();

    final groupRow = presenter.present(
      _memory(
        observer: 'deleted-observer-id',
        subjects: const ['deleted-subject-id'],
        conversationId: 'deleted-group-id',
      ),
    );
    final directRow = presenter.present(
      _memory(
        observer: 'deleted-observer-id',
        conversationId: 'dm:deleted-character-id',
      ),
    );

    expect(groupRow.observerName, '已删除角色');
    expect(groupRow.subjectNames, ['已删除角色']);
    expect(groupRow.originName, '已删除群聊');
    expect(directRow.originName, '已删除私聊');
    expect(groupRow.userVisibleText, isNot(contains('deleted-')));
    expect(directRow.userVisibleText, isNot(contains('deleted-')));
  });

  test('formats direct and group conversation names for current and deleted AI',
      () {
    final presenter = MemoryAuditPresenter(
      characterNames: const {'character-id': '小雨'},
    );

    expect(
      presenter
          .present(
            _memory(conversationId: 'dm:character-id'),
          )
          .originName,
      '与 小雨 的私聊',
    );
    expect(
      presenter
          .present(
            _memory(conversationId: 'dm:deleted-id', snapshot: '旧角色'),
          )
          .originName,
      '与 旧角色 的私聊',
    );
  });

  test('normalizes legacy direct snapshots with a friendly name', () {
    final row = MemoryAuditPresenter().present(
      _memory(
        conversationId: 'dm:deleted-id',
        snapshot: '私聊:阿月',
      ),
    );

    expect(row.originName, '与 阿月 的私聊');
  });

  test('does not expose a legacy direct snapshot ID', () {
    final row = MemoryAuditPresenter().present(
      _memory(
        conversationId: 'dm:deleted-id',
        snapshot: '私聊:deleted-id',
      ),
    );

    expect(row.originName, '已删除私聊');
    expect(row.userVisibleText, isNot(contains('deleted-id')));
  });

  test('normalizes legacy group snapshots with a friendly name', () {
    final row = MemoryAuditPresenter().present(
      _memory(
        conversationId: 'deleted-group-id',
        snapshot: '群聊:产品群',
      ),
    );

    expect(row.originName, '产品群');
  });

  test('does not expose a legacy group snapshot ID', () {
    final row = MemoryAuditPresenter().present(
      _memory(
        conversationId: 'deleted-group-id',
        snapshot: '群聊:deleted-group-id',
      ),
    );

    expect(row.originName, '已删除群聊');
    expect(row.userVisibleText, isNot(contains('deleted-group-id')));
  });

  test('provides one-line Chinese labels and explanations', () {
    for (final kind in MemoryKind.values) {
      _expectLabel(MemoryAuditLabels.kind(kind));
    }
    for (final origin in MemoryOriginType.values) {
      _expectLabel(MemoryAuditLabels.originType(origin));
    }
    for (final status in MemoryStatus.values) {
      _expectLabel(MemoryAuditLabels.status(status));
    }
    _expectLabel(MemoryAuditLabels.pinned(true));
    _expectLabel(MemoryAuditLabels.pinned(false));
  });

  test(
      'searches friendly projection fields but never internal IDs or enum names',
      () {
    final memory = _memory(
      observer: 'observer-uuid',
      subjects: const ['subject-uuid'],
      conversationId: 'group-uuid',
      snapshot: '产品交流群',
      content: '用户喜欢咖啡',
    );
    final presenter = MemoryAuditPresenter(
      characterNames: const {
        'observer-uuid': 'Amy',
        'subject-uuid': '小林',
      },
      conversationNames: const {'group-uuid': '产品交流群'},
    );

    final projection = presenter.present(memory).searchProjection;
    for (final query in const ['Amy', '咖啡', '小林', '产品交流群', '偏好']) {
      expect(projection.searchableText, contains(query));
    }
    expect(projection.searchableText, isNot(contains('observer-uuid')));
    expect(projection.searchableText, isNot(contains('preference')));
  });

  test('groups active and history rows and keeps sorting deterministic', () {
    final timestamp = DateTime(2026, 8, 12);
    PermanentMemory item({
      required String id,
      required MemoryStatus status,
      MemoryOriginType origin = MemoryOriginType.manual,
      bool pinned = false,
    }) {
      return _memory(
        id: id,
        status: status,
        origin: origin,
        updatedAt: timestamp,
        pinned: pinned,
      );
    }

    final sections = MemoryAuditPresenter().sections([
      item(id: 'b', status: MemoryStatus.active),
      item(
          id: 'legacy',
          status: MemoryStatus.active,
          origin: MemoryOriginType.legacyMigration),
      item(id: 'invalid', status: MemoryStatus.invalidated),
      item(id: 'pinned', status: MemoryStatus.active, pinned: true),
      item(id: 'a', status: MemoryStatus.active),
      item(id: 'replaced', status: MemoryStatus.superseded),
    ]);

    expect(sections.active.map((row) => row.memoryId), ['pinned', 'a', 'b']);
    expect(
      sections.history.map((row) => row.memoryId),
      ['invalid', 'legacy', 'replaced'],
    );
    expect(
        sections.active.every(
            (row) => row.originTypeValue != MemoryOriginType.legacyMigration),
        isTrue);
  });

  test('row keeps a value snapshot after the source model changes', () {
    final memory = _memory(
      id: 'stable-row',
      observer: 'observer-id',
      subjects: const ['user'],
      conversationId: 'group-id',
      snapshot: '原来源',
      content: '原正文',
    );
    final row = MemoryAuditPresenter(
      characterNames: const {'observer-id': '原观察 AI'},
      conversationNames: const {'group-id': '原群名'},
    ).present(memory);

    memory.content = '新正文';
    memory.subjectIds = ['changed-subject'];
    memory.pinned = true;
    memory.updatedAt = DateTime(2027);
    memory.originNameSnapshot = '新来源';

    expect(row.memoryId, 'stable-row');
    expect(row.content, '原正文');
    expect(row.subjectNames, ['我']);
    expect(row.originName, '原群名');
    expect(row.pinnedValue, isFalse);
    expect(row.updatedAt, DateTime(2026, 8, 12, 10));
    expect(row.searchProjection.content, '原正文');
    expect(row.userVisibleText, contains('原正文'));
  });
}

void _expectLabel(MemoryAuditLabel value) {
  expect(value.label, isNotEmpty);
  expect(value.description, isNotEmpty);
  expect(value.description, isNot(contains('\n')));
}

PermanentMemory _memory({
  String id = 'memory-id',
  String observer = 'observer-id',
  List<String> subjects = const ['user'],
  String? conversationId,
  String snapshot = '',
  String content = '正文',
  MemoryStatus status = MemoryStatus.active,
  MemoryOriginType origin = MemoryOriginType.group,
  bool pinned = false,
  DateTime? updatedAt,
}) {
  final time = updatedAt ?? DateTime(2026, 8, 12, 10);
  return PermanentMemory(
    id: id,
    observerCharacterId: observer,
    kind: MemoryKind.preference,
    content: content,
    subjectIds: subjects,
    status: status,
    originType: origin,
    originConversationId: conversationId,
    originNameSnapshot: snapshot,
    updatedAt: time,
    occurredAt: time,
    createdAt: time,
    pinned: pinned,
  );
}
