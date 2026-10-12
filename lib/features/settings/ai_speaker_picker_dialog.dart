import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/providers/providers.dart';

/// 选择「AI 接话选人器」使用的 API 配置。
///
/// 只把所选配置的 **id** 写进 app_settings：不保存明文 Key、凭据对象或配置
/// 副本，也不要求为选人器新增任何 API Key。选人不影响各角色自己的发言配置。
///
/// 调用方负责在返回后刷新自己（本函数不持有任何页面状态）。
Future<void> showSpeakerPickerConfigDialog({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  final db = ref.read(databaseServiceProvider);
  final settings = AiSpeakerPickerSettings(db);
  final configs = ref.read(apiConfigsProvider);
  final validIds = {for (final config in configs) config.id};
  final selectedId = settings.selectedConfigId();
  // 失效引用按"未选择"呈现：给一个点了必然报错的选项比不给更糟。
  var draft = validIds.contains(selectedId) ? selectedId : null;

  final saved = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('AI 接话选人器'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选人器按最新对话决定下一位由谁说。它是幕后的选人步骤，不是群成员，'
                '不会产生聊天气泡；每位角色的实际发言仍使用各自绑定的配置。',
                style: TextStyle(
                    fontSize: 13,
                    color:
                        Theme.of(dialogContext).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: draft ?? '',
                decoration: const InputDecoration(
                  labelText: '选人器使用的配置',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('不启用（使用本地规则）'),
                  ),
                  ...configs.map(
                    (config) => DropdownMenuItem(
                      value: config.id,
                      child: Text(config.name),
                    ),
                  ),
                ],
                onChanged: (value) => setDialogState(
                  () => draft = (value ?? '').isEmpty ? null : value,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft ?? ''),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  // null 表示用户取消；空串表示"不启用"。
  if (saved == null) return;
  await settings.select(saved);
}
