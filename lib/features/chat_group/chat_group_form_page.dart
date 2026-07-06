import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  late TextEditingController _searchController;

  Set<String> _selectedCharacterIds = {};
  bool _isEditing = false;
  bool _isSaving = false;
  String? _existingGroupId;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.group != null;
    _existingGroupId = widget.group?.id;
    final g = widget.group;

    _nameController = TextEditingController(text: g?.name ?? '');
    _themeController = TextEditingController(text: g?.theme ?? '');
    _descriptionController = TextEditingController(text: g?.description ?? '');
    _searchController = TextEditingController();
    _selectedCharacterIds = g?.aiCharacterIds.toSet() ?? {};
  }

  @override
  void dispose() {
    _nameController.dispose();
    _themeController.dispose();
    _descriptionController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allCharacters = ref.watch(aiCharactersProvider);
    final filtered = _searchController.text.isEmpty
        ? allCharacters
        : allCharacters.where((c) => c.name.contains(_searchController.text) || c.role.contains(_searchController.text)).toList();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_isEditing ? '编辑群聊' : '创建群聊', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18, color: cs.onSurface)),
        actions: [
          TextButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: Icon(_isEditing ? Icons.check_rounded : Icons.add_circle_rounded, color: cs.primary),
            label: Text(_isEditing ? '更新' : '创建', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _SectionHeader(title: '群聊信息', icon: Icons.info_outline_rounded, cs: cs),
            const SizedBox(height: 12),
            _Card(
              cs: cs,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: _inputDecoration('群聊名称 *', '给你的群聊起个名字', Icons.chat_bubble_outline_rounded, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入群聊名称' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _themeController,
                  decoration: _inputDecoration('主题 *', '例如：职场吐槽大会', Icons.palette_outlined, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入群聊主题' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _descriptionController,
                  decoration: _inputDecoration('描述', '可选，描述群聊的背景设定', Icons.description_outlined, cs),
                  maxLines: 3,
                ),
              ],
            ),

            const SizedBox(height: 24),
            _SectionHeader(title: '选择角色', icon: Icons.person_add_rounded, cs: cs),
            const SizedBox(height: 12),
            _Card(
              cs: cs,
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索角色名称或角色...',
                    prefixIcon: Icon(Icons.search_rounded, size: 18, color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest.withOpacity(0.4),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (allCharacters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('还没有角色，请先创建', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                  )
                else if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('未找到匹配的角色', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
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
                      title: Text(c.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: cs.onSurface)),
                      subtitle: Text('${c.role} · ${c.age}岁', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      activeColor: cs.primary,
                    );
                  }),
              ],
            ),

            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: Icon(_isEditing ? Icons.check_rounded : Icons.add_rounded, size: 20),
                label: Text(_isEditing ? '更新群聊' : '创建群聊', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, String? hint, IconData icon, ColorScheme cs) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.primary, width: 1.5)),
      filled: true,
      fillColor: cs.surfaceContainerHighest.withOpacity(0.4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
      hintStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant.withOpacity(0.5)),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    if (_selectedCharacterIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请至少选择一个角色'), behavior: SnackBarBehavior.floating));
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
        aiCharacterIds: _selectedCharacterIds.toList(),
        createdAt: widget.group?.createdAt ?? DateTime.now(),
      );

      if (_isEditing) {
        await ref.read(chatGroupsProvider.notifier).updateGroup(group);
      } else {
        await ref.read(chatGroupsProvider.notifier).addGroup(group);
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_isEditing ? '群聊已更新' : '群聊已创建'), behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), behavior: SnackBarBehavior.floating, backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final ColorScheme cs;
  const _SectionHeader({required this.title, required this.icon, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.primary, letterSpacing: 0.8)),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: cs.primary.withOpacity(0.15), thickness: 0.5)),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final ColorScheme cs;
  final List<Widget> children;
  const _Card({required this.cs, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: cs.outlineVariant.withOpacity(0.5))),
      color: cs.surfaceContainerHighest.withOpacity(0.4),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(children: children)),
    );
  }
}
