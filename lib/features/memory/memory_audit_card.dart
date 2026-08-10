import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class MemoryAuditCard extends StatelessWidget {
  final PermanentMemory memory;
  final Map<String, AICharacter> charactersById;
  final Map<String, int> supersededCount;
  final VoidCallback onPin;
  final VoidCallback onUnpin;
  final VoidCallback onAction;
  final Map<String, Message> messagesById;

  const MemoryAuditCard({
    super.key,
    required this.memory,
    required this.charactersById,
    required this.supersededCount,
    required this.onPin,
    required this.onUnpin,
    required this.onAction,
    required this.messagesById,
  });

  @override
  Widget build(BuildContext context) {
    final observer = charactersById[memory.observerCharacterId];
    final observerName = observer?.name ?? '已删除角色';
    final subjectNames = memory.subjectIds.map((sid) {
      if (sid == 'user') return '我';
      return charactersById[sid]?.name ?? '已删除角色';
    }).toList();

    final kindLabel = switch (memory.kind) {
      MemoryKind.fact => '知',
      MemoryKind.preference => '偏好',
      MemoryKind.commitment => '承诺',
      MemoryKind.sharedExperience => '经历',
      MemoryKind.relationshipNote => '关系',
      MemoryKind.personaGrowth => '成长',
      MemoryKind.explicitInstruction => '指令',
    };

    final (statusLabel, statusColor) = switch (memory.status) {
      MemoryStatus.active => ('有效', Colors.green),
      MemoryStatus.superseded => ('已取代', Colors.orange),
      MemoryStatus.invalidated => ('已失效', Colors.red),
    };

    return Card(
      child: InkWell(
        onLongPress: onAction,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Chip(label: Text(kindLabel)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(observerName,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: statusColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(statusLabel,
                        style: TextStyle(fontSize: 11, color: statusColor)),
                  ),
                  if (memory.pinned)
                    IconButton(
                      tooltip: '取消固定',
                      icon: const Icon(Icons.push_pin_rounded,
                          size: 18, color: Colors.orange),
                      onPressed: onUnpin,
                    )
                  else
                    IconButton(
                      tooltip: '固定',
                      icon: const Icon(Icons.push_pin_outlined, size: 18),
                      onPressed: onPin,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(memory.content, style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 6),
              if (subjectNames.isNotEmpty)
                Text('主体：${subjectNames.join("、")}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                      '重要度 ${memory.importance} · 置信 ${memory.confidence.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 12)),
                  if (memory.explicitlyRequested)
                    const Text('明确记忆',
                        style: TextStyle(fontSize: 12, color: Colors.purple)),
                  Text(_time(memory.occurredAt),
                      style: const TextStyle(fontSize: 12)),
                  Text(memory.originType.name,
                      style: const TextStyle(fontSize: 12)),
                  Text(memory.originNameSnapshot,
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  if (memory.originType == MemoryOriginType.legacyMigration)
                    Text(
                      memory.sourceMessageIds.isEmpty
                          ? '旧版迁移记录，无原始消息证据'
                          : '${memory.sourceMessageIds.length} 条证据消息',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.orange),
                    )
                  else if (memory.sourceMessageIds.isEmpty)
                    Text(
                      '无原始消息 · ${memory.originNameSnapshot}',
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    )
                  else
                    _SourceTraceButton(
                      memory: memory,
                      messagesById: messagesById,
                    ),
                  if (memory.supersedesIds.isNotEmpty)
                    Text('取代了 ${memory.supersedesIds.length} 条旧记录',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.teal)),
                  if ((supersededCount[memory.id] ?? 0) > 0)
                    Text('被 ${supersededCount[memory.id]} 条记录取代',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.deepOrange)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _time(DateTime value) {
    final df = DateFormat('yyyy-MM-dd HH:mm');
    return df.format(value.toLocal());
  }
}

class _SourceTraceButton extends StatelessWidget {
  final PermanentMemory memory;
  final Map<String, Message> messagesById;

  const _SourceTraceButton({
    required this.memory,
    required this.messagesById,
  });

  @override
  Widget build(BuildContext context) {
    final sourceIds = memory.sourceMessageIds;
    Message? foundMessage;
    for (final id in sourceIds) {
      final candidate = messagesById[id];
      if (candidate != null) {
        foundMessage = candidate;
        break;
      }
    }

    if (foundMessage == null) {
      return Tooltip(
        message: '原消息已不可用（可能已被删除）',
        child: TextButton.icon(
          onPressed: null,
          icon: const Icon(Icons.link_off_rounded, size: 14),
          label: Text('原消息已不可用（${memory.originNameSnapshot}）'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final source = foundMessage;
    return TextButton.icon(
      onPressed: () {
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatRoomPage(
              groupId: source.groupId,
              initialMessageId: source.id,
            ),
          ),
        );
      },
      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
      label: const Text('查看原消息'),
    );
  }
}
