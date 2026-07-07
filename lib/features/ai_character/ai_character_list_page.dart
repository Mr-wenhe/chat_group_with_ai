import 'package:chat_group/core/models/ai_character.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_character_form_page.dart';
import 'providers/ai_character_providers.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';

class AICharacterListPage extends ConsumerWidget {
  const AICharacterListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final characters = ref.watch(aiCharactersProvider);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.smart_toy_rounded, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('AI 角色', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, color: cs.onSurface)),
          ],
        ),
      ),
      body: characters.isEmpty
          ? _buildEmptyState(cs)
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: characters.length,
              itemBuilder: (context, index) {
                final character = characters[index];
                return _CharacterCard(
                  character: character,
                  cs: cs,
                  onTap: () => _editCharacter(context, character),
                  onDelete: () => _confirmDelete(context, ref, character),
                  onToggle: () {
                    character.isActive = !character.isActive;
                    character.save();
                  },
                );
              },
            ),
      floatingActionButton: AppFab(
        onPressed: () => _addCharacter(context),
        icon: Icons.add_rounded,
        label: '创建角色',
      ),
      bottomNavigationBar: AppBottomNav(currentIndex: 0, cs: cs),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primaryContainer.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_add_rounded, size: 44, color: cs.primary),
          ),
          const SizedBox(height: 24),
          Text('还没有 AI 角色', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('点击右下角创建你的第一个 AI', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  void _addCharacter(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const AICharacterFormPage()));
  }

  void _editCharacter(BuildContext context, AICharacter character) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => AICharacterFormPage(character: character)));
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, AICharacter character) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error, size: 28),
        title: Text('删除「${character.name}」？'),
        content: const Text('此操作不可撤销，该角色的所有数据将被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(aiCharactersProvider.notifier).deleteCharacter(character.id);
    }
  }
}

class _CharacterCard extends StatelessWidget {
  final AICharacter character;
  final ColorScheme cs;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggle;

  const _CharacterCard({
    required this.character,
    required this.cs,
    required this.onTap,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final pColor = providerColor(character.apiProvider);
    final label = providerLabel(character.apiProvider);

    return Dismissible(
      key: Key(character.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(18)),
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        color: character.isActive ? cs.surfaceContainer : cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: character.isActive ? pColor.withOpacity(0.35) : cs.outlineVariant,
            width: character.isActive ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildAvatar(pColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(character.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: pColor.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                            child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: pColor)),
                          ),
                          if (!character.isActive) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
                              child: Text('停用', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('${character.role} · ${character.age}岁', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                      if (character.personalityTags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: character.personalityTags.take(4).map((tag) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(6)),
                              child: Text(tag, style: TextStyle(fontSize: 12, color: cs.onPrimaryContainer)),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(character.isActive ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 20),
                      onPressed: onToggle,
                      color: cs.onSurfaceVariant,
                      tooltip: character.isActive ? '停用' : '启用',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: onDelete,
                      color: cs.error,
                      tooltip: '删除',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(Color pColor) {
    final displayAvatar = character.avatar.isNotEmpty ? character.avatar : (character.name.isNotEmpty ? character.name[0] : '?');
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pColor.withOpacity(0.14),
        border: Border.all(color: pColor.withOpacity(0.3), width: 1.5),
      ),
      child: Stack(
        children: [
          Center(child: Text(displayAvatar, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: pColor))),
          if (!character.isActive)
            const Positioned.fill(child: DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black26),
              child: Icon(Icons.pause_rounded, size: 16, color: Colors.white70),
            )),
        ],
      ),
    );
  }
}
