import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/widgets/tool_permission_chips.dart';
import 'package:flutter/material.dart';

class CharacterSkillEditor extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final List<CharacterSkill> inferredSkills;
  final List<ExpertSkillTemplate> recommendedTemplates;
  final Set<String> selectedTemplateIds;
  final ValueChanged<String>? onTemplateToggle;
  final List<ToolPermission> selectedPermissions;
  final ValueChanged<ToolPermission> onPermissionToggle;

  const CharacterSkillEditor({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    required this.inferredSkills,
    required this.recommendedTemplates,
    this.selectedTemplateIds = const {},
    this.onTemplateToggle,
    required this.selectedPermissions,
    required this.onPermissionToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: enabled,
          onChanged: onEnabledChanged,
          title: const Text('开启行动能力'),
          subtitle: const Text('角色可根据技能请求工具、生成工作流，并通过本地桥接层工作'),
        ),
        if (enabled) ...[
          const SizedBox(height: 12),
          Text('推断技能',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: inferredSkills.map((skill) {
              return Chip(
                label: Text(skill.name),
                avatar: const Icon(Icons.psychology_rounded, size: 16),
              );
            }).toList(),
          ),
          if (recommendedTemplates.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('可安装专家 Skill',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: recommendedTemplates.map((template) {
                final selected = selectedTemplateIds.contains(template.id);
                return InputChip(
                  label: Text(template.name),
                  avatar: const Icon(Icons.download_rounded, size: 16),
                  selected: selected,
                  showCheckmark: true,
                  onSelected: onTemplateToggle == null
                      ? null
                      : (value) => onTemplateToggle!.call(template.id),
                  tooltip: selected ? '已安装：点按移除' : '点按安装到该角色',
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 14),
          Text('工具权限',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          ToolPermissionChips(
            selected: selectedPermissions,
            onToggle: onPermissionToggle,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '文件、命令和浏览器能力通过本地桥接层执行；写文件、运行命令和读取浏览器上下文仍需要单次批准。',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
