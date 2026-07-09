import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';

class ChatGroupFormPage extends ConsumerStatefulWidget {
  final ChatGroup? group;

  const ChatGroupFormPage({super.key, this.group});

  @override
  ConsumerState<ChatGroupFormPage> createState() => _ChatGroupFormPageState();
}

class _ChatGroupFormPageState extends ConsumerState<ChatGroupFormPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _themeController;
  late TextEditingController _descriptionController;
  late TextEditingController _announcementController;
  late TextEditingController _searchController;

  Set<String> _selectedCharacterIds = {};
  bool _isEditing = false;
  bool _isSaving = false;
  String? _existingGroupId;
  double _replyIntervalSeconds = 12;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.group != null;
    _existingGroupId = widget.group?.id;
    final g = widget.group;

    _nameController = TextEditingController(text: g?.name ?? '');
    _themeController = TextEditingController(text: g?.theme ?? '');
    _descriptionController = TextEditingController(text: g?.description ?? '');
    _announcementController =
        TextEditingController(text: g?.announcement ?? '');
    _searchController = TextEditingController();
    _selectedCharacterIds = g?.aiCharacterIds.toSet() ?? {};
    _replyIntervalSeconds =
        (g?.replyIntervalSeconds ?? 12).clamp(5, 60).toDouble();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _themeController.dispose();
    _descriptionController.dispose();
    _announcementController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allCharacters = ref.watch(aiCharactersProvider);
    final filtered = _searchController.text.isEmpty
        ? allCharacters
        : allCharacters
            .where((c) =>
                c.name.contains(_searchController.text) ||
                c.role.contains(_searchController.text))
            .toList();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_isEditing ? '编辑群聊' : '创建群聊',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 18,
                color: cs.onSurface)),
        actions: [
          TextButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: Icon(
                _isEditing ? Icons.check_rounded : Icons.add_circle_rounded,
                color: cs.primary),
            label: Text(_isEditing ? '更新' : '创建',
                style:
                    TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AppSectionHeader(
                title: '群聊信息', icon: Icons.info_outline_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: appInputDecoration('群聊名称 *', '给你的群聊起个名字',
                      Icons.chat_bubble_outline_rounded, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入群聊名称' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _themeController,
                  decoration: appInputDecoration(
                      '主题 *', '例如：职场吐槽大会', Icons.palette_outlined, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入群聊主题' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _descriptionController,
                  decoration: appInputDecoration(
                      '描述', '可选，描述群聊的背景设定', Icons.description_outlined, cs),
                  maxLines: 3,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _announcementController,
                  decoration: appInputDecoration('群公告', '例如：本周冲刺目标、协作规则或禁忌话题',
                      Icons.campaign_outlined, cs),
                  maxLines: 3,
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Icon(Icons.speed_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'AI 回复速率',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface),
                      ),
                    ),
                    Text('${_replyIntervalSeconds.round()} 秒',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: cs.primary)),
                  ],
                ),
                Slider(
                  value: _replyIntervalSeconds,
                  min: 5,
                  max: 60,
                  divisions: 11,
                  label: '${_replyIntervalSeconds.round()} 秒',
                  onChanged: (value) =>
                      setState(() => _replyIntervalSeconds = value),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AppSectionHeader(
                title: '选择角色', icon: Icons.person_add_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索角色名称或角色...',
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 18, color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outlineVariant)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outlineVariant)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.primary, width: 1.5)),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (allCharacters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('还没有角色，请先创建',
                        style: TextStyle(
                            fontSize: 14, color: cs.onSurfaceVariant)),
                  )
                else if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('未找到匹配的角色',
                        style: TextStyle(
                            fontSize: 14, color: cs.onSurfaceVariant)),
                  )
                else
                  ...filtered.map((c) {
                    final selected = _selectedCharacterIds.contains(c.id);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selectedCharacterIds.add(c.id);
                          } else {
                            _selectedCharacterIds.remove(c.id);
                          }
                        });
                      },
                      title: Text(c.name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurface)),
                      subtitle: Text('${c.role} · ${c.age}岁',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      activeColor: cs.primary,
                    );
                  }),
              ],
            ),
            const SizedBox(height: 32),
            AppPrimaryButton(
              onPressed: _isSaving ? null : _save,
              icon: _isEditing ? Icons.check_rounded : Icons.add_rounded,
              label: _isEditing ? '更新群聊' : '创建群聊',
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    if (_selectedCharacterIds.isEmpty) {
      AppToast.show(context, '请至少选择一个角色', icon: Icons.info_outline_rounded);
      return;
    }
    _isSaving = true;
    setState(() {});

    try {
      final group = ChatGroup(
        id: _existingGroupId,
        name: _nameController.text.trim(),
        theme: _themeController.text.trim(),
        description: _descriptionController.text.trim(),
        announcement: _announcementController.text.trim(),
        replyIntervalSeconds: _replyIntervalSeconds.round(),
        aiCharacterIds: _selectedCharacterIds.toList(),
        createdAt: widget.group?.createdAt ?? DateTime.now(),
        ownerName: widget.group?.ownerName,
      );

      if (_isEditing) {
        await ref.read(chatGroupsProvider.notifier).updateGroup(group);
      } else {
        await ref.read(chatGroupsProvider.notifier).addGroup(group);
      }

      if (mounted) {
        AppToast.show(context, _isEditing ? '群聊已更新' : '群聊已创建',
            icon: Icons.check_circle_outline_rounded);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '保存失败: $e', icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
