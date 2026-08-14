import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

const _sourceMessageSummaryLimit = 160;

class MemoryDetailPage extends ConsumerStatefulWidget {
  final PermanentMemory memory;
  final MemoryConversationScope scope;

  /// Test seam for exercising action failure and duplicate-submission paths.
  @visibleForTesting
  final MemoryControls? testControls;

  const MemoryDetailPage({
    super.key,
    required this.memory,
    required this.scope,
    this.testControls,
  });

  @override
  ConsumerState<MemoryDetailPage> createState() => _MemoryDetailPageState();
}

class _MemoryDetailPageState extends ConsumerState<MemoryDetailPage> {
  bool _submitting = false;
  bool _changed = false;

  DatabaseService get _db => ref.read(databaseServiceProvider);
  bool get _canManage => !widget.scope.isReadOnly;
  MemoryControls get _controls => widget.testControls ?? MemoryControls(_db);

  void _popWithResult() {
    if (_isPopping) return;
    _isPopping = true;
    Navigator.of(context).pop(_changed);
  }

  bool _isPopping = false;

  PermanentMemory? get _storedMemory => _db.permanentMemoryBox.values
      .cast<PermanentMemory?>()
      .firstWhere((item) => item?.id == widget.memory.id, orElse: () => null);

  PermanentMemory? get _memory {
    final stored = _storedMemory;
    return stored == null ? null : _isAllowed(stored);
  }

  bool get _isOutOfScope {
    final stored = _storedMemory;
    return stored != null && _isAllowed(stored) == null;
  }

  PermanentMemory? _isAllowed(PermanentMemory memory) =>
      widget.scope.apply([memory]).isEmpty ? null : memory;

  @override
  Widget build(BuildContext context) {
    final memory = _memory;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _popWithResult();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('记忆详情'),
          leading: BackButton(onPressed: _popWithResult),
        ),
        body: memory == null
            ? Center(
                child: Text(_isOutOfScope ? '这条记忆不可用' : '这条记忆已不存在'),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _DetailSection(title: '记忆正文', child: Text(memory.content)),
                  _DetailSection(title: '记录信息', child: _metadata(memory)),
                  _DetailSection(title: '来源', child: _origin(memory)),
                  _DetailSection(title: '时间', child: _timestamps(memory)),
                  if (_canManage) ...[
                    _managementActions(memory),
                    _technicalInformation(memory),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _metadata(PermanentMemory memory) => Column(children: [
        _DetailRow('观察 AI', _characterName(memory.observerCharacterId)),
        _DetailRow('对象', _subjectNames(memory)),
        _DetailRow('类型', MemoryAuditLabels.kind(memory.kind).label),
        _DetailRow('状态', MemoryAuditLabels.status(memory.status).label),
        _DetailRow('固定', MemoryAuditLabels.pinned(memory.pinned).label),
      ]);

  Widget _origin(PermanentMemory memory) {
    final messages = _sourceMessages(memory);
    final sourceMessage = _firstOpenableSourceMessage(messages);
    final hasMissingMessages =
        messages.length < memory.sourceMessageIds.toSet().length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          '${MemoryAuditLabels.originType(memory.originType).label} · ${_originName(memory)}'),
      const SizedBox(height: 12),
      if (memory.sourceMessageIds.isEmpty)
        Text(_emptySourceLabel(memory.originType))
      else if (messages.isEmpty) ...[
        const Text('原始消息已不可用'),
        _unavailableSourceButton(),
      ] else ...[
        if (hasMissingMessages) const Text('部分原始消息已不可用'),
        ...messages.map((message) => Text(_sourceMessageSummary(message))),
        if (sourceMessage != null)
          TextButton.icon(
            key: const ValueKey('memory-detail-open-source'),
            onPressed: () => _openSourceMessage(sourceMessage),
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
            label: const Text('查看原消息'),
          )
        else
          _unavailableSourceButton(),
      ],
    ]);
  }

  List<Message> _sourceMessages(PermanentMemory memory) {
    final seen = <String>{};
    final messages = <Message>[];
    for (final id in memory.sourceMessageIds) {
      if (!seen.add(id)) continue;
      final message = _db.messageBox.get(id);
      if (message != null) messages.add(message);
    }
    return messages;
  }

  Message? _firstOpenableSourceMessage(List<Message> messages) {
    for (final message in messages) {
      if (_canOpenSource(message)) return message;
    }
    return null;
  }

  bool _canOpenSource(Message message) {
    if (message.groupId.startsWith('dm:')) {
      final characterId = message.groupId.substring(3);
      return _db.aiCharacterBox.get(characterId) != null ||
          DataLifecycleService(db: _db).deletedCharacter(characterId) != null;
    }
    return _db.chatGroupBox.get(message.groupId) != null;
  }

  void _openSourceMessage(Message message) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomPage(
          groupId: message.groupId,
          initialMessageId: message.id,
        ),
      ),
    );
  }

  Widget _unavailableSourceButton() => Tooltip(
        message: '来源消息或来源场合已不可用',
        child: TextButton.icon(
          key: const ValueKey('memory-detail-open-source-unavailable'),
          onPressed: null,
          icon: const Icon(Icons.link_off_rounded, size: 16),
          label: const Text('查看原消息'),
        ),
      );

  String _emptySourceLabel(MemoryOriginType originType) => switch (originType) {
        MemoryOriginType.manual => '人工记录，无原始消息证据',
        MemoryOriginType.legacyMigration => '旧版迁移记录，无原始消息证据',
        _ => '没有关联原始消息',
      };

  String _sourceMessageSummary(Message message) {
    final normalized = message.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= _sourceMessageSummaryLimit
        ? normalized
        : '${normalized.substring(0, _sourceMessageSummaryLimit)}…';
  }

  Widget _timestamps(PermanentMemory memory) => Column(children: [
        _DetailRow('发生时间', _formatTime(memory.occurredAt)),
        _DetailRow('创建时间', _formatTime(memory.createdAt)),
        _DetailRow('更新时间', _formatTime(memory.updatedAt)),
      ]);

  Widget _managementActions(PermanentMemory memory) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('memory-detail-pin'),
            onPressed: _submitting ? null : () => _togglePin(memory),
            icon:
                Icon(memory.pinned ? Icons.push_pin_outlined : Icons.push_pin),
            label: Text(memory.pinned ? '取消固定' : '固定'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('memory-detail-correct'),
            onPressed: _submitting ? null : () => _correct(memory),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('修正'),
          ),
          FilledButton.icon(
            key: const ValueKey('memory-detail-delete'),
            onPressed: _submitting ? null : () => _delete(memory),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除'),
          ),
        ],
      );

  Widget _technicalInformation(PermanentMemory memory) => ExpansionTile(
        key: const ValueKey('memory-detail-technical-information'),
        title: const Text('技术信息'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _DetailRow('记忆 ID', memory.id),
          _DetailRow('观察者 ID', memory.observerCharacterId),
          if (memory.originConversationId != null)
            _DetailRow('来源场合 ID', memory.originConversationId!),
        ],
      );

  Future<void> _togglePin(PermanentMemory memory) => _runManaged(() async {
        if (memory.pinned) {
          await _controls.unpinPermanent(memory);
        } else {
          await _controls.pinPermanent(memory);
        }
      });

  Future<void> _delete(PermanentMemory memory) async {
    if (!_canManage || _submitting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条记忆？'),
        content: const Text('删除后，后续不会再注入，旧版本不会自动恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runManaged(() => _controls.deletePermanent(memory),
          popAfter: true);
    }
  }

  Future<void> _correct(PermanentMemory memory) async {
    if (!_canManage || _submitting) return;
    final controller = TextEditingController(text: memory.content);
    final content = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修正记忆'),
        content: TextField(
            key: const ValueKey('memory-correction-content'),
            controller: controller,
            maxLines: 4),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存修正')),
        ],
      ),
    );
    controller.dispose();
    if (content == null || content.trim().isEmpty) return;
    if (memory.pinned) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('修正固定记忆？'),
          content: const Text('固定记忆将被新的修正记录取代。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续修正')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    await _runManaged(
      () async {
        await _controls.editPermanent(
          memory,
          correctedContent: content,
          subjectIds: memory.subjectIds,
        );
      },
      popAfter: true,
    );
  }

  Future<void> _runManaged(
    Future<void> Function() action, {
    bool popAfter = false,
  }) async {
    if (!_canManage || _submitting) return;
    setState(() => _submitting = true);
    var didPop = false;
    try {
      await action();
      _changed = true;
      if (mounted && popAfter) {
        didPop = true;
        Navigator.of(context).pop(true);
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后重试。')),
        );
      }
    } finally {
      if (mounted && !didPop) setState(() => _submitting = false);
    }
  }

  String _characterName(String id) {
    if (id == 'user') return '我';
    final character = DataLifecycleService(db: _db).characterOrDeleted(id);
    final name = character?.name.trim() ?? '';
    return character == null ||
            name.isEmpty ||
            MemoryAuditPresenter.isTechnicalName(name, character.id)
        ? '已删除角色'
        : name;
  }

  String _subjectNames(PermanentMemory memory) => memory.subjectIds.isEmpty
      ? (memory.kind == MemoryKind.personaGrowth ? '自身成长' : '未指定对象')
      : memory.subjectIds.map(_characterName).join('、');

  String _originName(PermanentMemory memory) {
    final presenter = MemoryAuditPresenter(
      characterNames: {
        for (final character in DataLifecycleService(db: _db).charactersForIds({
          ..._db.aiCharacterBox.values.map((character) => character.id),
          ..._db.permanentMemoryBox.values.expand((item) => [
                item.observerCharacterId,
                ...item.subjectIds,
              ]),
        }))
          character.id: character.name
      },
      conversationNames: {
        for (final group in _db.chatGroupBox.values) group.id: group.name
      },
    );
    return presenter.present(memory).originName;
  }

  String _formatTime(DateTime value) =>
      DateFormat('yyyy-MM-dd HH:mm').format(value);
}

class _DetailSection extends StatelessWidget {
  final String title;
  final Widget child;
  const _DetailSection({required this.title, required this.child});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ]),
      );
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 76, child: Text(label)),
          Expanded(child: Text(value)),
        ]),
      );
}
