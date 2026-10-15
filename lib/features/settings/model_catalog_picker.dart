import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter/material.dart';

/// 配置表单里 Base URL 的起手值。
///
/// 内置提供商过去不显示地址、请求时也只认预设地址，于是「换了协议子路径」这类
/// 需求无法配置（内置 DeepSeek + Anthropic 协议会打到 `/messages`）。显示就必须
/// 认它，所以这里与请求侧同一条规则：配置里存了地址就用存的，没存才用预设。
String initialBaseUrl(
    {required ApiConfig? config, required ApiProvider provider}) {
  final stored = config?.customBaseUrl.trim() ?? '';
  return stored.isNotEmpty ? stored : provider.baseUrl;
}

/// 模型选择面板的候选项。
///
/// 拉到的真实清单在最前面，内置候选补在后面（离线也能选，别名也不丢）。当前已填的
/// 模型一定在列表里——否则用户打开面板看不到自己配的那个，会以为配置丢了。
List<ProviderModelInfo> modelChoices({
  required List<ProviderModelInfo>? fetched,
  required ApiProvider provider,
  required String currentModel,
}) {
  final choices = <ProviderModelInfo>[...?fetched];
  // 真实清单在前，内置候选补在后：`/models` 只列当前主推模型，而服务商往往还
  // 接受别名（DeepSeek 的 chat / reasoner / v4-flash 就是这样），补在后面既不
  // 丢能力信息也不把可用别名藏起来。
  for (final id in ApiProvider.providerModels[provider.name] ?? const []) {
    if (!choices.any((model) => model.id == id)) {
      choices.add(ProviderModelInfo(id: id));
    }
  }
  final current = currentModel.trim();
  if (current.isNotEmpty && !choices.any((model) => model.id == current)) {
    choices.insert(0, ProviderModelInfo(id: current));
  }
  return choices;
}

/// 模型选择面板：点选一个模型返回它，取消返回 null。
Future<ProviderModelInfo?> showModelPicker(
  BuildContext context, {
  required List<ProviderModelInfo> models,
  String? selectedId,
}) {
  return showModalBottomSheet<ProviderModelInfo>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ModelPickerSheet(
      models: models,
      selectedId: selectedId,
    ),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({required this.models, this.selectedId});

  final List<ProviderModelInfo> models;
  final String? selectedId;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final query = _query.trim().toLowerCase();
    final visible = query.isEmpty
        ? widget.models
        : widget.models
            .where((model) =>
                model.id.toLowerCase().contains(query) ||
                (model.displayName?.toLowerCase().contains(query) ?? false))
            .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('选择模型（${widget.models.length} 个可用）',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: cs.onSurface)),
            const SizedBox(height: 10),
            TextField(
              key: const Key('model-picker-search'),
              autofocus: false,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                hintText: '按名称筛选',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final model = visible[index];
                  final selected = model.id == widget.selectedId;
                  return ListTile(
                    key: Key('model-option-${model.id}'),
                    dense: true,
                    title: Text(model.id,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13)),
                    subtitle: _subtitleFor(model),
                    trailing: selected
                        ? Icon(Icons.check_rounded, size: 18, color: cs.primary)
                        : null,
                    onTap: () => Navigator.pop(context, model),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _subtitleFor(ProviderModelInfo model) {
    final parts = <String>[
      if (model.displayName != null) model.displayName!,
      if (model.contextWindow != null) '窗口 ${model.contextWindow}',
      if (model.maxOutputTokens != null) '输出 ${model.maxOutputTokens}',
      if (model.supportsVision == true) '可读图',
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '), style: const TextStyle(fontSize: 11));
  }
}
