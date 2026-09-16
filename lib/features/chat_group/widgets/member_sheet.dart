import 'package:chat_group/core/models/ai_character.dart';
import 'package:flutter/material.dart';

class MemberStackChip extends StatelessWidget {
  final List<AICharacter> characters;
  final Color Function(AICharacter character) senderColor;

  const MemberStackChip({
    super.key,
    required this.characters,
    required this.senderColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shown = characters.take(3).toList(growable: false);
    const overlap = 16.0;
    final stackWidth =
        shown.isEmpty ? 0.0 : 26.0 + (shown.length - 1) * overlap;
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 10, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (shown.isNotEmpty)
            SizedBox(
              width: stackWidth,
              height: 26,
              child: Stack(
                children: [
                  for (var index = 0; index < shown.length; index++)
                    Positioned(
                      left: index * overlap,
                      child: _MiniAvatar(
                        character: shown[index],
                        color: senderColor(shown[index]),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(width: 6),
          Text(
            '${characters.length}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final AICharacter character;
  final Color color;

  const _MiniAvatar({required this.character, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        character.avatar.isNotEmpty
            ? character.avatar
            : character.name.characters.first,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class MemberSheet extends StatefulWidget {
  final List<AICharacter> characters;
  final String ownerName;
  final Color Function(AICharacter character) senderColor;
  final String Function(AICharacter character) statusText;
  final ValueChanged<AICharacter> onOpenSettings;
  final ValueChanged<AICharacter> onDirectChat;
  final VoidCallback? onAddMember;

  const MemberSheet({
    super.key,
    required this.characters,
    required this.ownerName,
    required this.senderColor,
    required this.statusText,
    required this.onOpenSettings,
    required this.onDirectChat,
    this.onAddMember,
  });

  @override
  State<MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<MemberSheet> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _searchController.text.trim();
    final filtered = query.isEmpty
        ? widget.characters
        : widget.characters
            .where((character) =>
                character.name.contains(query) ||
                character.role.contains(query) ||
                character.personalityTags.any((tag) => tag.contains(query)))
            .toList(growable: false);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Text(
                '群成员',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.characters.length + 1}',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索名称、角色或标签',
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              isDense: true,
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                if (widget.onAddMember != null) ...[
                  _AddMemberTile(onTap: widget.onAddMember!),
                  const SizedBox(height: 4),
                ],
                _MemberTile(
                  avatarText: '我',
                  avatarColor: colorScheme.primary,
                  name: widget.ownerName,
                  subtitle: '群主',
                  isOwner: true,
                ),
                Divider(
                  height: 24,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
                if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '未找到匹配成员',
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else
                  ...filtered.map((character) => _MemberTile(
                        avatarText: character.avatar.isNotEmpty
                            ? character.avatar
                            : character.name.characters.first,
                        avatarColor: widget.senderColor(character),
                        name: character.name,
                        subtitle: widget.statusText(character),
                        onOpenSettings: () {
                          Navigator.pop(context);
                          widget.onOpenSettings(character);
                        },
                        onDirectChat: () {
                          Navigator.pop(context);
                          widget.onDirectChat(character);
                        },
                      )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final String avatarText;
  final Color avatarColor;
  final String name;
  final String subtitle;
  final bool isOwner;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onDirectChat;

  const _MemberTile({
    required this.avatarText,
    required this.avatarColor,
    required this.name,
    required this.subtitle,
    this.isOwner = false,
    this.onOpenSettings,
    this.onDirectChat,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          InkWell(
            onTap: onOpenSettings,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: avatarColor.withValues(alpha: 0.15),
                border: Border.all(
                  color: avatarColor.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                avatarText,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: avatarColor,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (isOwner) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '群主',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (onDirectChat != null)
            IconButton(
              onPressed: onDirectChat,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 20),
              color: colorScheme.primary,
              tooltip: '私聊',
            ),
        ],
      ),
    );
  }
}

/// 成员面板顶部的「添加成员」入口行。
class _AddMemberTile extends StatelessWidget {
  final VoidCallback onTap;

  const _AddMemberTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.primary.withValues(alpha: 0.12),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.person_add_alt_1_rounded,
                size: 22,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '添加成员',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 添加成员选择器：从候选角色（尚未进群）中多选，确认后 pop 出选中列表。
class MemberAddSheet extends StatefulWidget {
  final List<AICharacter> candidates;
  final String Function(AICharacter character) statusText;

  const MemberAddSheet({
    super.key,
    required this.candidates,
    required this.statusText,
  });

  @override
  State<MemberAddSheet> createState() => _MemberAddSheetState();
}

class _MemberAddSheetState extends State<MemberAddSheet> {
  final _searchController = TextEditingController();
  final _selectedIds = <String>{};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _searchController.text.trim();
    final filtered = query.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((character) =>
                character.name.contains(query) ||
                character.role.contains(query) ||
                character.personalityTags.any((tag) => tag.contains(query)))
            .toList(growable: false);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Text(
                '添加成员',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '已选 ${_selectedIds.length}',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索名称、角色或标签',
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              isDense: true,
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      '没有可添加的角色',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final character in filtered)
                        CheckboxListTile(
                          value: _selectedIds.contains(character.id),
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              _selectedIds.add(character.id);
                            } else {
                              _selectedIds.remove(character.id);
                            }
                          }),
                          title: Text(
                            character.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            widget.statusText(character),
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          activeColor: colorScheme.primary,
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _selectedIds.isEmpty
                  ? null
                  : () => Navigator.pop(
                        context,
                        widget.candidates
                            .where((character) =>
                                _selectedIds.contains(character.id))
                            .toList(growable: false),
                      ),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text('添加 ${_selectedIds.length} 人'),
            ),
          ),
        ],
      ),
    );
  }
}
