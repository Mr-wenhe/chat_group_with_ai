import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class MemoryAuditCard extends StatelessWidget {
  final Map<String, int> supersededCount;
  final MemoryAuditRow displayRow;
  final VoidCallback onPin;
  final VoidCallback onUnpin;
  final VoidCallback onAction;
  final Map<String, Message> messagesById;

  const MemoryAuditCard({
    super.key,
    required this.supersededCount,
    required this.displayRow,
    required this.onPin,
    required this.onUnpin,
    required this.onAction,
    required this.messagesById,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (displayRow.statusValue) {
      MemoryStatus.active => Colors.green,
      MemoryStatus.superseded => Colors.orange,
      MemoryStatus.invalidated => Colors.red,
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
                  Chip(label: Text(displayRow.kind.label)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(displayRow.observerName,
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
                    child: Text(displayRow.status.label,
                        style: TextStyle(fontSize: 11, color: statusColor)),
                  ),
                  if (displayRow.pinnedValue)
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
              Text(displayRow.content, style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 6),
              if (displayRow.subjectNames.isNotEmpty)
                Text('主体：${displayRow.subjectNames.join("、")}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                      '重要度 ${displayRow.importance} · 置信 ${displayRow.confidence.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 12)),
                  if (displayRow.explicitlyRequested)
                    const Text('明确记忆',
                        style: TextStyle(fontSize: 12, color: Colors.purple)),
                  Text(_time(displayRow.occurredAt),
                      style: const TextStyle(fontSize: 12)),
                  Text(displayRow.originType.label,
                      style: const TextStyle(fontSize: 12)),
                  Text(displayRow.originName,
                      style: const TextStyle(fontSize: 12)),
                  if (displayRow.invalidationReason != null)
                    Text('失效原因：${displayRow.invalidationReason}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.red)),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  if (displayRow.originTypeValue ==
                      MemoryOriginType.legacyMigration)
                    Text(
                      displayRow.sourceMessageIds.isEmpty
                          ? '旧版迁移记录，无原始消息证据'
                          : '${displayRow.sourceMessageIds.length} 条证据消息',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.orange),
                    )
                  else if (displayRow.sourceMessageIds.isEmpty)
                    Text(
                      '无原始消息 · ${displayRow.originName}',
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    )
                  else
                    _SourceTraceButton(
                      sourceMessageIds: displayRow.sourceMessageIds,
                      originName: displayRow.originName,
                      messagesById: messagesById,
                    ),
                  if (displayRow.supersedesCount > 0)
                    Text('取代了 ${displayRow.supersedesCount} 条旧记录',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.teal)),
                  if ((supersededCount[displayRow.memoryId] ?? 0) > 0)
                    Text('被 ${supersededCount[displayRow.memoryId]} 条记录取代',
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
  final List<String> sourceMessageIds;
  final String originName;
  final Map<String, Message> messagesById;

  const _SourceTraceButton({
    required this.sourceMessageIds,
    required this.originName,
    required this.messagesById,
  });

  @override
  Widget build(BuildContext context) {
    Message? foundMessage;
    for (final id in sourceMessageIds) {
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
          label: Text('原消息已不可用（$originName）'),
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
