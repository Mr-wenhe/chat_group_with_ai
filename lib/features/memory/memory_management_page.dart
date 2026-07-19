import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class MemoryManagementPage extends ConsumerStatefulWidget {
  final String conversationId;

  const MemoryManagementPage({
    super.key,
    required this.conversationId,
  });

  @override
  ConsumerState<MemoryManagementPage> createState() =>
      _MemoryManagementPageState();
}

class _MemoryManagementPageState extends ConsumerState<MemoryManagementPage> {
  late final DatabaseService _db;
  late final MemoryControls _controls;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _controls = MemoryControls(_db);
  }

  List<AICharacter> get _characters {
    final directId = DirectChatSession.characterIdFrom(widget.conversationId);
    if (directId != null) {
      return [_db.aiCharacterBox.get(directId)]
          .whereType<AICharacter>()
          .toList();
    }
    final group = _db.chatGroupBox.get(widget.conversationId);
    return (group?.aiCharacterIds ?? const <String>[])
        .map(_db.aiCharacterBox.get)
        .whereType<AICharacter>()
        .toList(growable: false);
  }

  List<GroupMemory> get _groupMemories => _db.groupMemoryBox.values
      .where((item) =>
          item.groupId == widget.conversationId &&
          item.topicSummary.trim().isNotEmpty)
      .toList(growable: false);

  List<CharacterMemory> get _characterMemories => _db.characterMemoryBox.values
      .where((item) => item.groupId == widget.conversationId)
      .toList(growable: false);

  List<RelationshipState> get _relationships => _db.relationshipStateBox.values
      .where((item) => item.groupId == widget.conversationId)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final memories = _characterMemories;
    final charactersById = {for (final item in _characters) item.id: item};
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆审计与控制'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '快捷遗忘',
            onSelected: _forget,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'topic', child: Text('忘记这个话题')),
              PopupMenuItem(value: 'user', child: Text('忘记关于我的内容')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动记忆'),
            subtitle: const Text('关闭后不再发起群摘要、角色记忆或上下文记忆 API 调用'),
            value: _controls.automaticMemoryEnabled,
            onChanged: (value) async {
              await _controls.setAutomaticMemoryEnabled(value);
              if (mounted) setState(() {});
            },
          ),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('下列内容就是后续请求实际使用的本地记忆。固定会暂停该记录的自动更新；'
                  '角色记忆可单条固定，编辑或删除会立即同步清理 legacy 摘要。'),
            ),
          ),
          if (_groupMemories.isNotEmpty) ...[
            const _SectionTitle('群记忆'),
            for (final memory in _groupMemories) _groupMemoryCard(memory),
          ],
          const _SectionTitle('角色记忆'),
          if (memories.isEmpty &&
              _characters.every((item) => item.memorySummary.trim().isEmpty))
            const ListTile(title: Text('当前会话还没有角色记忆')),
          for (final character in _characters)
            _characterCard(
              character,
              memories
                  .where((item) => item.characterId == character.id)
                  .toList(growable: false),
            ),
          if (_relationships.isNotEmpty) ...[
            const _SectionTitle('关系状态'),
            for (final relationship in _relationships)
              _relationshipCard(relationship, charactersById),
          ],
        ],
      ),
    );
  }

  Widget _groupMemoryCard(GroupMemory memory) {
    final key = _controls.groupKey(memory);
    return Card(
      child: ListTile(
        title: Text(memory.topicSummary),
        subtitle: Text('来源：群聊自动摘要 · 更新：${_time(memory.lastSummaryAt)}'),
        trailing: _actions(
          pinned: _controls.isPinned(key),
          onPin: (value) => _controls.setPinned(key, value),
          onEdit: () => _editText(
            title: '编辑群记忆',
            initial: memory.topicSummary,
            save: (value) => _controls.updateGroup(memory, value),
          ),
          onDelete: () => _controls.deleteGroup(memory),
        ),
      ),
    );
  }

  Widget _characterCard(
    AICharacter character,
    List<CharacterMemory> memories,
  ) {
    return Card(
      child: ExpansionTile(
        title: Text(character.name),
        subtitle: Text('${memories.length} 条会话记忆记录'),
        children: [
          if (character.memorySummary.trim().isNotEmpty)
            ListTile(
              title: const Text('跨会话 legacy 摘要'),
              subtitle: Text(character.memorySummary),
              trailing: _actions(
                pinned: _controls.isPinned(_controls.legacyKey(character)),
                onPin: (value) =>
                    _controls.setPinned(_controls.legacyKey(character), value),
                onEdit: () => _editText(
                  title: '编辑跨会话摘要',
                  initial: character.memorySummary,
                  save: (value) => _controls.updateLegacy(character, value),
                ),
                onDelete: () => _controls.deleteLegacy(character),
              ),
            ),
          for (final memory in memories) ...[
            ListTile(
              title: Text('会话记忆 · ${_time(memory.lastUpdatedAt)}'),
              subtitle: Text('来源：对话摘要 · 适用：${memory.groupId}'),
              trailing: IconButton(
                tooltip: _controls.isPinned(_controls.characterKey(memory))
                    ? '取消固定'
                    : '固定，暂停自动覆盖',
                icon: Icon(_controls.isPinned(_controls.characterKey(memory))
                    ? Icons.push_pin
                    : Icons.push_pin_outlined),
                onPressed: () => _pin(
                  _controls.characterKey(memory),
                  !_controls.isPinned(_controls.characterKey(memory)),
                ),
              ),
            ),
            ..._layerTiles(character, memory, CharacterMemoryLayer.facts),
            ..._layerTiles(
              character,
              memory,
              CharacterMemoryLayer.relationshipNotes,
            ),
            ..._layerTiles(
              character,
              memory,
              CharacterMemoryLayer.personaGrowth,
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _layerTiles(
    AICharacter character,
    CharacterMemory memory,
    CharacterMemoryLayer layer,
  ) {
    final values = switch (layer) {
      CharacterMemoryLayer.facts => memory.facts,
      CharacterMemoryLayer.relationshipNotes => memory.relationshipNotes,
      CharacterMemoryLayer.personaGrowth => memory.personaGrowth,
    };
    final label = switch (layer) {
      CharacterMemoryLayer.facts => '事实',
      CharacterMemoryLayer.relationshipNotes => '关系变化',
      CharacterMemoryLayer.personaGrowth => '偏好/表达摘要',
    };
    return [
      for (var index = 0; index < values.length; index++)
        ListTile(
          dense: true,
          leading: Chip(label: Text(label)),
          title: Text(values[index]),
          subtitle: const Text('状态：有效 · 置信：未提供'),
          trailing: _actions(
            pinned: _controls.isPinned(
              _controls.characterEntryKey(memory, layer, values[index]),
            ),
            onPin: (value) => _controls.setPinned(
              _controls.characterEntryKey(memory, layer, values[index]),
              value,
            ),
            onEdit: () => _editText(
              title: '编辑$label',
              initial: values[index],
              save: (value) => _controls.updateCharacterEntry(
                memory: memory,
                character: character,
                layer: layer,
                index: index,
                value: value,
              ),
            ),
            onDelete: () => _controls.deleteCharacterEntry(
              memory: memory,
              character: character,
              layer: layer,
              index: index,
            ),
          ),
        ),
    ];
  }

  Widget _relationshipCard(
    RelationshipState relationship,
    Map<String, AICharacter> charactersById,
  ) {
    final source = charactersById[relationship.sourceCharacterId]?.name ?? '角色';
    final target = relationship.targetType == RelationshipTargetType.user
        ? '我'
        : charactersById[relationship.targetId]?.name ?? '已删除角色';
    return Card(
      child: ListTile(
        title: Text('$source → $target · ${relationship.recentMood.name}'),
        subtitle:
            Text('亲近 ${relationship.affinity} · 信任 ${relationship.trust} · '
                '摩擦 ${relationship.friction}\n${relationship.notes}'),
        trailing: _actions(
          pinned: _controls.isPinned(
            _controls.relationshipKey(relationship),
          ),
          onPin: (value) => _controls.setPinned(
            _controls.relationshipKey(relationship),
            value,
          ),
          onEdit: () => _editText(
            title: '编辑关系备注',
            initial: relationship.notes,
            save: (value) => _controls.updateRelationship(relationship, value),
          ),
          onDelete: () => _controls.deleteRelationship(relationship),
        ),
      ),
    );
  }

  Widget _actions({
    bool? pinned,
    Future<void> Function(bool value)? onPin,
    required Future<void> Function() onEdit,
    required Future<void> Function() onDelete,
  }) {
    return Wrap(
      children: [
        if (pinned != null)
          IconButton(
            tooltip: pinned ? '取消固定' : '固定，暂停自动覆盖',
            icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: () async {
              await onPin!(!pinned);
              if (mounted) setState(() {});
            },
          ),
        IconButton(
          tooltip: '编辑',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () async {
            await onEdit();
            if (mounted) setState(() {});
          },
        ),
        IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmDelete(onDelete),
        ),
      ],
    );
  }

  Future<void> _editText({
    required String title,
    required String initial,
    required Future<void> Function(String value) save,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.trim().isNotEmpty) await save(value);
  }

  Future<void> _confirmDelete(Future<void> Function() delete) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条记忆？'),
        content: const Text('删除后，后续请求不会再注入该内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await delete();
    if (mounted) setState(() {});
  }

  Future<void> _pin(String key, bool value) async {
    await _controls.setPinned(key, value);
    if (mounted) setState(() {});
  }

  Future<void> _forget(String kind) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(kind == 'topic' ? '忘记这个话题？' : '忘记关于我的内容？'),
        content: Text(kind == 'topic'
            ? '当前会话的群摘要会被清空。'
            : '当前会话角色的事实、关系记忆和跨会话 legacy 摘要会被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认遗忘'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (kind == 'topic') {
      await _controls.forgetTopic(widget.conversationId);
    } else {
      await _controls.forgetAboutUser(widget.conversationId);
    }
    if (mounted) setState(() {});
  }

  String _time(DateTime value) =>
      DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}
