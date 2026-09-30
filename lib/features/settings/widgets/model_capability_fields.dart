import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';

/// 能力区块的说明文案。集中在这里，是为了让表单页与治理页弹窗永远说同一句话。
class ModelCapabilityCopy {
  const ModelCapabilityCopy._();

  static const intro = '按「提供商 + 模型名」保存，该模型的所有配置共用。'
      '这些值决定工作模式能不能跑、一次能读多长写多长。';
  static const streaming = '支持逐字输出。关掉后工作模式无法启动。';
  static const vision = '能否读图片附件。关掉后带图任务会暂停并要求换模型。';
  static const tools = '能否调用工具。关掉后工作模式无法启动。';
  static const contextWindow = '一次请求能携带的历史与附件上限；最大输出不会超过它的一半。';
  static const maxOutput = '一次能写多长。调小会让长文档被截断，需要分块写。';
  static const restoreBuiltin = '恢复内置默认';
}

/// 保存能力声明时对存储的动作。
enum ModelCapabilityPersistAction {
  /// 不动存储：没改动，或改了但生效值不会变。
  keep,
  save,
  clear,
}

/// 决定保存时对能力声明做什么——表单页与治理页弹窗共用同一判据。
///
/// 「改动才写」的判据刻意不是「草稿与生效值是否相同」：对内置快照里已有的模型，
/// 上下文与最大输出取「声明值与内置值的较大者」（见
/// [ModelCapabilityRegistry.resolve]），用户把值**调小**时草稿变了、生效值却没变。
/// 此时写入只会凭空固化一份声明，连同流式/视觉/工具一起钉死在当前快照上——
/// 既没有效果，又挡住了将来的快照更新，所以必须判为 [keep]。
ModelCapabilityPersistAction modelCapabilityPersistAction({
  required bool restoreBuiltin,
  required CustomModelCapability? declared,
  required ModelCapabilityRegistry registry,
  required ApiProvider provider,
  required String modelId,
  required ModelCapability effective,
}) {
  if (restoreBuiltin) return ModelCapabilityPersistAction.clear;
  if (declared == null) return ModelCapabilityPersistAction.keep;
  final resolved = registry.resolve(
    provider: provider,
    modelId: modelId,
    custom: declared,
  );
  final changes = resolved.supportsStreaming != effective.supportsStreaming ||
      resolved.supportsVision != effective.supportsVision ||
      resolved.supportsTools != effective.supportsTools ||
      resolved.contextWindow != effective.contextWindow ||
      resolved.maxOutput != effective.maxOutput;
  return changes
      ? ModelCapabilityPersistAction.save
      : ModelCapabilityPersistAction.keep;
}

/// 「模型能力」区块的编辑状态。由调用方持有并 dispose，与 [TextEditingController] 同寿。
class ModelCapabilityController extends ChangeNotifier {
  ModelCapabilityController(ModelCapability effective) {
    _contextController =
        TextEditingController(text: '${effective.contextWindow}');
    _outputController = TextEditingController(text: '${effective.maxOutput}');
    _supportsStreaming = effective.supportsStreaming;
    _supportsVision = effective.supportsVision;
    _supportsTools = effective.supportsTools;
    _contextController.addListener(notifyListeners);
    _outputController.addListener(notifyListeners);
  }

  late final TextEditingController _contextController;
  late final TextEditingController _outputController;
  late bool _supportsStreaming;
  late bool _supportsVision;
  late bool _supportsTools;

  TextEditingController get contextController => _contextController;
  TextEditingController get outputController => _outputController;
  bool get supportsStreaming => _supportsStreaming;
  bool get supportsVision => _supportsVision;
  bool get supportsTools => _supportsTools;

  set supportsStreaming(bool value) {
    _supportsStreaming = value;
    notifyListeners();
  }

  set supportsVision(bool value) {
    _supportsVision = value;
    notifyListeners();
  }

  set supportsTools(bool value) {
    _supportsTools = value;
    notifyListeners();
  }

  /// 按新的生效值重置整块字段。切换提供商、切换模型，或恢复内置默认时调用。
  void seed(ModelCapability effective) {
    _contextController.text = '${effective.contextWindow}';
    _outputController.text = '${effective.maxOutput}';
    _supportsStreaming = effective.supportsStreaming;
    _supportsVision = effective.supportsVision;
    _supportsTools = effective.supportsTools;
    notifyListeners();
  }

  /// 当前字段对应的声明；任一数字非法或最大输出大于上下文时返回 null。
  CustomModelCapability? get declared {
    final contextWindow = int.tryParse(_contextController.text.trim());
    final maxOutput = int.tryParse(_outputController.text.trim());
    if (contextWindow == null || maxOutput == null) return null;
    if (contextWindow <= 0 || maxOutput <= 0 || maxOutput > contextWindow) {
      return null;
    }
    return CustomModelCapability(
      supportsStreaming: _supportsStreaming,
      supportsVision: _supportsVision,
      supportsTools: _supportsTools,
      contextWindow: contextWindow,
      maxOutput: maxOutput,
    );
  }

  @override
  void dispose() {
    _contextController.removeListener(notifyListeners);
    _outputController.removeListener(notifyListeners);
    _contextController.dispose();
    _outputController.dispose();
    super.dispose();
  }
}

/// 「模型能力」区块：开关、Token 字段、逐字段说明与校验的唯一实现。
///
/// 字段一律以**生效值**（内置快照与用户声明合并后的结果）回填，而不是裸的
/// [CustomModelCapability] 默认值：后者会把内置快照认为支持流式/工具的模型显示成
/// 「全关 + 8192/2048」，用户一保存就写成用户声明——而用户声明在流式/视觉/工具上
/// 优先级高于内置快照，等于把模型降级。
class ModelCapabilityFields extends StatelessWidget {
  const ModelCapabilityFields({
    super.key,
    required this.cs,
    required this.controller,
    required this.builtin,
    this.onRestoreBuiltin,
  });

  final ColorScheme cs;
  final ModelCapabilityController controller;

  /// 该模型的内置快照值；[ModelCapability.isKnown] 为 false 表示快照里没有它。
  final ModelCapability builtin;

  /// 清除已有声明回到内置快照；为 null 时不显示该按钮。
  final VoidCallback? onRestoreBuiltin;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ModelCapabilityCopy.intro,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('流式'),
            subtitle: const Text(ModelCapabilityCopy.streaming),
            value: controller.supportsStreaming,
            onChanged: (value) => controller.supportsStreaming = value,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('视觉'),
            subtitle: const Text(ModelCapabilityCopy.vision),
            value: controller.supportsVision,
            onChanged: (value) => controller.supportsVision = value,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('工具'),
            subtitle: const Text(ModelCapabilityCopy.tools),
            value: controller.supportsTools,
            onChanged: (value) => controller.supportsTools = value,
          ),
          const SizedBox(height: 4),
          _tokenField(
            key: const Key('capability-context-window'),
            controller: controller.contextController,
            label: '上下文 Token',
            icon: Icons.article_outlined,
            helper: ModelCapabilityCopy.contextWindow,
            validate: (value) => _positiveInt(value, '上下文 Token'),
          ),
          const SizedBox(height: 14),
          _tokenField(
            key: const Key('capability-max-output'),
            controller: controller.outputController,
            label: '最大输出 Token',
            icon: Icons.short_text_rounded,
            helper: ModelCapabilityCopy.maxOutput,
            validate: (value) {
              final error = _positiveInt(value, '最大输出 Token');
              if (error != null) return error;
              final output = int.parse(value!.trim());
              final contextWindow =
                  int.tryParse(controller.contextController.text.trim());
              if (contextWindow != null && output > contextWindow) {
                return '最大输出不能大于上下文 Token';
              }
              return null;
            },
          ),
          if (onRestoreBuiltin != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRestoreBuiltin,
                icon:
                    const Icon(Icons.settings_backup_restore_rounded, size: 18),
                label: const Text(ModelCapabilityCopy.restoreBuiltin),
              ),
            ),
          ],
          _builtinFloorNote(),
        ],
      ),
    );
  }

  Widget _tokenField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String helper,
    required String? Function(String?) validate,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: appInputDecoration(label, null, icon, cs).copyWith(
        helperText: helper,
        helperMaxLines: 2,
        errorMaxLines: 2,
      ),
      validator: validate,
    );
  }

  String? _positiveInt(String? value, String label) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed <= 0) return '$label 需为大于 0 的整数';
    return null;
  }

  /// 低于内置快照的值不会生效（解析时取较大者），就地说明而不是让它静默。
  Widget _builtinFloorNote() {
    if (!builtin.isKnown) return const SizedBox.shrink();
    final contextWindow =
        int.tryParse(controller.contextController.text.trim());
    final maxOutput = int.tryParse(controller.outputController.text.trim());
    final belowContext =
        contextWindow != null && contextWindow < builtin.contextWindow;
    final belowOutput = maxOutput != null && maxOutput < builtin.maxOutput;
    if (!belowContext && !belowOutput) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        '内置快照为 ${builtin.contextWindow} / ${builtin.maxOutput}；'
        '低于内置值的声明不会生效，解析时取两者较大值。',
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
    );
  }
}

/// 能力编辑的结果：写入一份声明，或清除声明回到内置快照。
class ModelCapabilityEditResult {
  const ModelCapabilityEditResult.declared(this.capability)
      : restoreBuiltin = false;

  const ModelCapabilityEditResult.restoreBuiltin()
      : capability = null,
        restoreBuiltin = true;

  final CustomModelCapability? capability;
  final bool restoreBuiltin;
}
