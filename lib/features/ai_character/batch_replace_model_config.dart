import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:flutter/material.dart';

/// 选择源、目标 API 配置，并将 [characters] 中使用源配置的角色切到目标配置。
/// API Key 只保存在共享配置凭据仓库，角色字段不保留副本。
Future<int> batchReplaceCharacterModelConfig({
  required BuildContext context,
  required List<AICharacter> characters,
  required List<ApiConfig> apiConfigs,
  required String subjectLabel,
}) async {
  if (apiConfigs.length < 2) {
    AppToast.show(context, '至少需要两个配置才能批量替换', icon: Icons.info_outline_rounded);
    return 0;
  }

  final usageCount = <String, int>{
    for (final config in apiConfigs) config.id: 0
  };
  for (final character in characters) {
    usageCount[character.apiConfigId] =
        (usageCount[character.apiConfigId] ?? 0) + 1;
  }
  final sourceId = apiConfigs
      .firstWhere(
        (config) => (usageCount[config.id] ?? 0) > 0,
        orElse: () => apiConfigs.first,
      )
      .id;
  if ((usageCount[sourceId] ?? 0) == 0) {
    AppToast.show(context, '当前没有$subjectLabel关联任何配置，无需替换',
        icon: Icons.info_outline_rounded);
    return 0;
  }

  final result = await showDialog<({String sourceId, String targetId})>(
    context: context,
    builder: (_) => _BatchReplaceModelConfigDialog(
      apiConfigs: apiConfigs,
      usageCount: usageCount,
      subjectLabel: subjectLabel,
      initialSourceId: sourceId,
      initialTargetId:
          apiConfigs.firstWhere((config) => config.id != sourceId).id,
    ),
  );
  if (result == null || !context.mounted) return 0;

  final source =
      apiConfigs.firstWhere((config) => config.id == result.sourceId);
  final target =
      apiConfigs.firstWhere((config) => config.id == result.targetId);
  final replaced = await _replaceCharacterModelConfig(
    characters,
    sourceId: source.id,
    target: target,
  );
  if (!context.mounted) return replaced;
  AppToast.show(
    context,
    '已将 $replaced 个$subjectLabel从「${source.name}」替换为「${target.name}」',
    icon: Icons.sync_alt_rounded,
  );
  return replaced;
}

Future<int> _replaceCharacterModelConfig(
  List<AICharacter> characters, {
  required String sourceId,
  required ApiConfig target,
}) async {
  final matched = characters
      .where((character) => character.apiConfigId == sourceId)
      .toList(growable: false);
  for (final character in matched) {
    character.apiConfigId = target.id;
    character.apiKey = '';
    character.apiProvider = target.provider;
    character.modelName = target.modelName;
    character.customBaseUrl = target.customBaseUrl;
    await character.save();
  }
  assert(matched.every((character) =>
      character.apiConfigId == target.id && character.apiKey.isEmpty));
  return matched.length;
}

class _BatchReplaceModelConfigDialog extends StatefulWidget {
  final List<ApiConfig> apiConfigs;
  final Map<String, int> usageCount;
  final String subjectLabel;
  final String initialSourceId;
  final String initialTargetId;

  const _BatchReplaceModelConfigDialog({
    required this.apiConfigs,
    required this.usageCount,
    required this.subjectLabel,
    required this.initialSourceId,
    required this.initialTargetId,
  });

  @override
  State<_BatchReplaceModelConfigDialog> createState() =>
      _BatchReplaceModelConfigDialogState();
}

class _BatchReplaceModelConfigDialogState
    extends State<_BatchReplaceModelConfigDialog> {
  late String _sourceId = widget.initialSourceId;
  late String _targetId = widget.initialTargetId;

  List<ApiConfig> get _sourceCandidates => widget.apiConfigs
      .where((config) => (widget.usageCount[config.id] ?? 0) > 0)
      .toList(growable: false);

  List<ApiConfig> get _targetCandidates =>
      widget.apiConfigs.where((config) => config.id != _sourceId).toList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final affected = widget.usageCount[_sourceId] ?? 0;
    final source =
        widget.apiConfigs.firstWhere((config) => config.id == _sourceId);
    final target =
        widget.apiConfigs.firstWhere((config) => config.id == _targetId);
    return AlertDialog(
      title: const Text('批量替换模型配置'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('源配置（当前正在使用的）',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            _buildSourceDropdown(),
            const SizedBox(height: 14),
            Text('目标配置（替换为）',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            _buildTargetDropdown(),
            const SizedBox(height: 14),
            _buildSummary(cs, affected, source, target),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: affected == 0
              ? null
              : () => Navigator.pop(
                  context, (sourceId: _sourceId, targetId: _targetId)),
          child: Text('替换 $affected 个${widget.subjectLabel}'),
        ),
      ],
    );
  }

  Widget _buildSourceDropdown() => DropdownButtonFormField<String>(
        value: _sourceId,
        isExpanded: true,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: _sourceCandidates
            .map((config) => DropdownMenuItem(
                  value: config.id,
                  child: Text(
                    '${config.name} (${config.provider}) · '
                    '${widget.usageCount[config.id] ?? 0} 个${widget.subjectLabel}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
            .toList(),
        onChanged: (value) {
          if (value == null) return;
          setState(() {
            _sourceId = value;
            if (_targetId == value) {
              _targetId = widget.apiConfigs
                  .firstWhere((config) => config.id != value)
                  .id;
            }
          });
        },
      );

  Widget _buildTargetDropdown() => DropdownButtonFormField<String>(
        value: _targetId,
        isExpanded: true,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: _targetCandidates
            .map((config) => DropdownMenuItem(
                  value: config.id,
                  child: Text('${config.name} (${config.provider})',
                      overflow: TextOverflow.ellipsis),
                ))
            .toList(),
        onChanged: (value) {
          if (value != null) setState(() => _targetId = value);
        },
      );

  Widget _buildSummary(
    ColorScheme colorScheme,
    int affected,
    ApiConfig source,
    ApiConfig target,
  ) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '将把 $affected 个使用「${source.name}」的${widget.subjectLabel}'
          '替换为「${target.name}」（模型 ${target.modelName}）',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
      );
}
