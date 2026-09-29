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

/// 多人联机里另一位真人的展示信息。
///
/// 真人没有 [AICharacter]，也没有本机档案：主人端拿不到客人的角色设置，
/// 客人端更是连角色都没有。所以这里只保留"叫什么、什么身份"两件事，
/// 列表项也就不提供进设置/发起私聊这两个动作。
class SharedGroupMember {
  const SharedGroupMember({required this.name, required this.label});

  final String name;

  /// 身份标签：「主人」或「客人」。
  final String label;
}

class MemberSheet extends StatefulWidget {
  final List<AICharacter> characters;
  final String ownerName;
  final Color Function(AICharacter character) senderColor;
  final String Function(AICharacter character) statusText;
  final ValueChanged<AICharacter> onOpenSettings;
  final ValueChanged<AICharacter> onDirectChat;

  /// 本机用户在群里的身份，显示在自己那一行下面。
  final String ownerRole;

  /// 本机用户是否是群主，决定是否显示「群主」徽章。
  final bool ownerIsHost;

  /// 多人联机里的其他真人。纯本机的群为空。
  final List<SharedGroupMember> sharedMembers;

  const MemberSheet({
    super.key,
    required this.characters,
    required this.ownerName,
    required this.senderColor,
    required this.statusText,
    required this.onOpenSettings,
    required this.onDirectChat,
    this.ownerRole = '群主',
    this.ownerIsHost = true,
    this.sharedMembers = const <SharedGroupMember>[],
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
    // 真人只按名字搜：他们没有角色和标签。
    final filteredMembers = query.isEmpty
        ? widget.sharedMembers
        : widget.sharedMembers
            .where((member) => member.name.contains(query))
            .toList(growable: false);
    final total = widget.characters.length + widget.sharedMembers.length + 1;

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
                '$total',
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
                _MemberTile(
                  avatarText: '我',
                  avatarColor: colorScheme.primary,
                  name: widget.ownerName,
                  subtitle: widget.ownerRole,
                  badge: widget.ownerIsHost ? '群主' : null,
                ),
                Divider(
                  height: 24,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
                // 真人排在 AI 角色前面：客人端压根没有角色，主人端也更关心
                // "谁进来了"。没有可点的动作——远端真人在本机没有档案。
                ...filteredMembers.map((member) => _MemberTile(
                      avatarText: member.name.characters.first,
                      avatarColor: colorScheme.primary,
                      name: member.name,
                      subtitle: member.label,
                    )),
                if (filtered.isEmpty && filteredMembers.isEmpty)
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

  /// 名字后面的小徽章，null 表示不加。
  final String? badge;

  final VoidCallback? onOpenSettings;
  final VoidCallback? onDirectChat;

  const _MemberTile({
    required this.avatarText,
    required this.avatarColor,
    required this.name,
    required this.subtitle,
    this.badge,
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
                    if (badge != null) ...[
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
                          badge!,
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
