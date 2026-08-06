import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:flutter/material.dart';

class MemoryAuditFilterWidget extends StatelessWidget {
  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final ValueChanged<MemoryAuditFilter> onChanged;

  const MemoryAuditFilterWidget({
    super.key,
    required this.filter,
    required this.characters,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Single "clear filter" button — keeps the widget simple.
    // Full filter pickers (character selector, status, kind) are added
    // by later tasks.
    final isEmpty = filter.isEmpty;
    return isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    if (filter.observerCharacterId != null)
                      Chip(
                        label: Text('角色: ${_charName(filter.observerCharacterId)}'),
                        onDeleted: () => onChanged(filter.copyWith(observerCharacterId: null)),
                      ),
                    if (filter.originConversationId != null)
                      Chip(
                        label: Text('场合: ${filter.originConversationId}'),
                        onDeleted: () => onChanged(filter.copyWith(originConversationId: null)),
                      ),
                    if (filter.status != null)
                      Chip(
                        label: Text('状态: ${filter.status!.name}'),
                        onDeleted: () => onChanged(filter.copyWith(status: null)),
                      ),
                    if (filter.memoryKind != null)
                      Chip(
                        label: Text('类型: ${filter.memoryKind!.name}'),
                        onDeleted: () => onChanged(filter.copyWith(memoryKind: null)),
                      ),
                    if (filter.originType != null)
                      Chip(
                        label: Text('来源: ${filter.originType!.name}'),
                        onDeleted: () => onChanged(filter.copyWith(originType: null)),
                      ),
                  ],
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => onChanged(const MemoryAuditFilter()),
                  icon: const Icon(Icons.filter_list_off_rounded, size: 18),
                  label: const Text('清除筛选'),
                ),
              ],
            ),
          );
  }

  String _charName(String? id) {
    if (id == null) return '';
    final c = characters.cast<AICharacter?>().firstWhere(
          (x) => x?.id == id,
          orElse: () => null,
        );
    return c?.name ?? id;
  }
}
