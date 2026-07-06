import 'package:chat_group/core/models/ai_character.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_character_form_page.dart';
import 'providers/ai_character_providers.dart';
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
              decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.smart_toy_rounded, size: 18, color: cs.onPrimary),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCharacter(context),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        icon: const Icon(Icons.add_rounded, size: 22),
        label: const Text('创建角色', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      bottomNavigationBar: _buildBottomNav(context, 0),
    );
  }

  Widget _buildBottomNav(BuildContext context, int currentIndex) {
    final cs = Theme.of(context).colorScheme;
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: (i) {
        if (i != currentIndex) {
          if (i == 0) {
            Navigator.of(context).pushReplacementNamed('/');
          } else if (i == 1) {
            Navigator.of(context).pushReplacementNamed('/groups');
          } else {
            Navigator.of(context).pushReplacementNamed('/settings');
          }
        }
      },
      backgroundColor: cs.surface,
      indicatorColor: cs.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.smart_toy_rounded, size: 22),
          selectedIcon: Icon(Icons.smart_toy_rounded, size: 22),
          label: '角色',
        ),
        NavigationDestination(
          icon: Icon(Icons.group_outlined, size: 22),
          selectedIcon: Icon(Icons.group_rounded, size: 22),
          label: '群聊',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined, size: 22),
          selectedIcon: Icon(Icons.settings_rounded, size: 22),
          label: '设置',
        ),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_add_rounded, size: 64, color: cs.primary.withOpacity(0.3)),
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
    final providerColor = _providerColor();

    return Dismissible(
      key: Key(character.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)),
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: character.isActive ? providerColor.withOpacity(0.3) : cs.outlineVariant,
            width: character.isActive ? 1.5 : 1,
          ),
        ),
        color: character.isActive ? cs.surface : cs.surfaceContainerHighest,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildAvatar(providerColor),
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
                            decoration: BoxDecoration(color: providerColor.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                            child: Text(_providerLabel(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: providerColor)),
                          ),
                          if (!character.isActive) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
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

  Widget _buildAvatar(Color providerColor) {
    final displayAvatar = character.avatar.isNotEmpty ? character.avatar : (character.name.isNotEmpty ? character.name[0] : '?');
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: providerColor.withOpacity(0.12),
        border: Border.all(color: providerColor.withOpacity(0.25), width: 1.5),
      ),
      child: Stack(
        children: [
          Center(child: Text(displayAvatar, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: providerColor))),
          if (!character.isActive)
            const Positioned.fill(child: DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black26),
              child: Icon(Icons.pause_rounded, size: 16, color: Colors.white70),
            )),
        ],
      ),
    );
  }

  String _providerLabel() {
    switch (character.apiProvider) {
      case 'deepseek': return 'DeepSeek';
      case 'qwen': return '通义千问';
      case 'zhipu': return '智谱AI';
      case 'moonshot': return 'Moonshot';
      case 'baidu': return '百度文心';
      case 'custom': return '自定义';
      default: return character.apiProvider;
    }
  }

  Color _providerColor() {
    switch (character.apiProvider) {
      case 'deepseek': return const Color(0xFF1565C0);
      case 'qwen': return const Color(0xFF6A1B9A);
      case 'zhipu': return const Color(0xFF0277BD);
      case 'moonshot': return const Color(0xFF4527A0);
      case 'baidu': return const Color(0xFF283593);
      case 'custom': return const Color(0xFFE65100);
      default: return const Color(0xFF2563EB);
    }
  }
}
