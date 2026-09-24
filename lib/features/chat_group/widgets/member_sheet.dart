import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/text/pinyin_search.dart';
import 'package:flutter/material.dart';

/// 成员行溢出菜单里的操作。
enum _MemberAction { toggleMute, mention }

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

  /// 当前群被禁言的角色 id。面板内部持一份可变副本，使保存结果可见——
  /// `showModalBottomSheet` 构建的 widget 不会随页面 `setState` 重建。
  final Set<String> mutedIds;

  /// 切换某角色的禁言状态。面板不自动关闭，方便连续设置多个成员。
  final Future<void> Function(AICharacter character, bool muted)? onToggleMute;

  /// 点名某角色发言：由页面把 `@` 插入输入框，复用既有提及通路。
  final ValueChanged<AICharacter>? onMention;

  final VoidCallback? onAddMember;

  const MemberSheet({
    super.key,
    required this.characters,
    required this.ownerName,
    required this.senderColor,
    required this.statusText,
    required this.onOpenSettings,
    required this.onDirectChat,
    this.mutedIds = const {},
    this.onToggleMute,
    this.onMention,
    this.onAddMember,
  });

  @override
  State<MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<MemberSheet> {
  final _searchController = TextEditingController();

  /// 面板内的禁言状态副本，只在保存成功后刷新。
  late Set<String> _mutedIds;
  bool _savingMute = false;
  String? _muteError;

  @override
  void initState() {
    super.initState();
    _mutedIds = {...widget.mutedIds};
  }

  Future<void> _toggleMute(AICharacter character) async {
    if (_savingMute || widget.onToggleMute == null) return;
    final muted = !_mutedIds.contains(character.id);
    setState(() {
      _savingMute = true;
      _muteError = null;
    });
    try {
      await widget.onToggleMute!(character, muted);
      if (!mounted) return;
      setState(() {
        if (muted) {
          _mutedIds.add(character.id);
        } else {
          _mutedIds.remove(character.id);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _muteError = '禁言设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingMute = false);
    }
  }

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
        : PinyinSearch.exactFirst(
            widget.characters
                .where((character) => PinyinSearch.matchesFields(
                      character.searchFields,
                      query,
                      mode: PinyinMatchMode.name,
                    ))
                .toList(growable: false),
            (character) =>
                PinyinSearch.matchesLiterally(character.searchFields, query),
          );

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
              hintText: '搜索名称、角色或标签，支持拼音',
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
          if (_muteError != null)
            Text(_muteError!, style: TextStyle(color: colorScheme.error)),
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
                        isMuted: _mutedIds.contains(character.id),
                        onOpenSettings: () {
                          Navigator.pop(context);
                          widget.onOpenSettings(character);
                        },
                        onDirectChat: () {
                          Navigator.pop(context);
                          widget.onDirectChat(character);
                        },
                        onToggleMute: widget.onToggleMute == null || _savingMute
                            ? null
                            : () => _toggleMute(character),
                        onMention: widget.onMention == null
                            ? null
                            : () {
                                // 点名要把 @ 写进输入框，必须先收起面板。
                                Navigator.pop(context);
                                widget.onMention!(character);
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
  final bool isMuted;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onDirectChat;
  final VoidCallback? onToggleMute;
  final VoidCallback? onMention;

  const _MemberTile({
    required this.avatarText,
    required this.avatarColor,
    required this.name,
    required this.subtitle,
    this.isOwner = false,
    this.isMuted = false,
    this.onOpenSettings,
    this.onDirectChat,
    this.onToggleMute,
    this.onMention,
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
                  // 禁言放在副标题里：它是"该成员当前状态"，与在线/未配置 API 同类。
                  isMuted ? '已禁言 · $subtitle' : subtitle,
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
          // 禁言与点名放进溢出菜单：一行里挤三个图标按钮会挤掉成员名，
          // 而这两个操作都是低频、非连续点击的动作。
          if (onToggleMute != null || onMention != null)
            PopupMenuButton<_MemberAction>(
              tooltip: '更多操作',
              icon: Icon(
                Icons.more_vert_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              onSelected: (action) => switch (action) {
                _MemberAction.toggleMute => onToggleMute?.call(),
                _MemberAction.mention => onMention?.call(),
              },
              itemBuilder: (context) => [
                if (onToggleMute != null)
                  PopupMenuItem(
                    value: _MemberAction.toggleMute,
                    child: Text(isMuted ? '取消禁言' : '禁言（@ 点名仍可回复）'),
                  ),
                if (onMention != null)
                  const PopupMenuItem(
                    value: _MemberAction.mention,
                    child: Text('点名发言'),
                  ),
              ],
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
        : PinyinSearch.exactFirst(
            widget.candidates
                .where((character) => PinyinSearch.matchesFields(
                      character.searchFields,
                      query,
                      mode: PinyinMatchMode.name,
                    ))
                .toList(growable: false),
            (character) =>
                PinyinSearch.matchesLiterally(character.searchFields, query),
          );

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
              hintText: '搜索名称、角色或标签，支持拼音',
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
