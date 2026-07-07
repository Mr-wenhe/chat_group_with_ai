import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_presets.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'providers/ai_character_providers.dart';
import '../settings/providers/api_config_providers.dart';
import '../settings/api_config_form_page.dart';

class AICharacterFormPage extends ConsumerStatefulWidget {
  final AICharacter? character;

  /// 可选：从角色预设库快速创建的预设模板，进入即填充展示字段。
  final CharacterPreset? preset;

  const AICharacterFormPage({super.key, this.character, this.preset});

  @override
  ConsumerState<AICharacterFormPage> createState() =>
      _AICharacterFormPageState();
}

class _AICharacterFormPageState extends ConsumerState<AICharacterFormPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _avatarController;
  late TextEditingController _ageController;
  late TextEditingController _roleController;
  late TextEditingController _systemPromptController;
  late TextEditingController _personalityController;
  late TextEditingController _hourlyLimitController;

  bool _isEditing = false;
  String? _existingCharacterId;
  String _selectedApiConfigId = '';
  bool _isSaving = false;
  bool _hasLegacyApiData = false;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.character != null;
    _existingCharacterId = widget.character?.id;
    final c = widget.character;

    _nameController = TextEditingController(text: c?.name ?? '');
    _avatarController = TextEditingController(text: c?.avatar ?? '');
    _ageController =
        TextEditingController(text: c != null ? c.age.toString() : '');
    _roleController = TextEditingController(text: c?.role ?? '');
    _systemPromptController =
        TextEditingController(text: c?.systemPrompt ?? '');
    _personalityController = TextEditingController(
        text: c == null ? '' : c.personalityTags.join(', '));
    _hourlyLimitController =
        TextEditingController(text: (c?.hourlyReplyLimit ?? 5).toString());

    _selectedApiConfigId = c?.apiConfigId ?? '';
    _hasLegacyApiData = _selectedApiConfigId.isEmpty &&
        (c?.apiKey.isNotEmpty ?? false) &&
        (c?.apiProvider.isNotEmpty ?? false);

    // 新建角色时默认选中讯飞星火(xfyun)配置，若无则选第一个可用配置
    if (_selectedApiConfigId.isEmpty && _isEditing == false) {
      final configs = ref.read(apiConfigsProvider);
      final xfyunConfig =
          configs.where((cfg) => cfg.provider == 'xfyun').firstOrNull;
      if (xfyunConfig != null) {
        _selectedApiConfigId = xfyunConfig.id;
      } else if (configs.isNotEmpty) {
        _selectedApiConfigId = configs.first.id;
      }
    }

    // 若从「预设快速创建」进入，直接用预设填充展示字段（仍要求后续选 ApiConfig）。
    if (widget.preset != null) _fillFromPreset(widget.preset!);
  }

  /// 用预设填充表单控制器（仅展示字段，绝不写入 API Key / 配置）。
  void _fillFromPreset(CharacterPreset p) {
    _nameController.text = p.name;
    _avatarController.text = p.avatar;
    _ageController.text = p.age.toString();
    _roleController.text = p.role;
    _personalityController.text = p.personalityTags.join(', ');
    _systemPromptController.text = p.systemPrompt;
  }

  /// 从「从预设套用」弹窗选择后套用：只填展示字段，密钥仍由用户选 ApiConfig 决定。
  void _applyPreset(CharacterPreset p) {
    _fillFromPreset(p);
    setState(() {});
  }

  /// 弹出预设选择底部弹窗。
  void _showPresetPicker() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, color: cs.primary, size: 18),
                  const SizedBox(width: 8),
                  Text('选择角色预设',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface)),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(ctx),
                      tooltip: '关闭'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.count(
                controller: controller,
                crossAxisCount: 2,
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.25,
                children: CharacterPreset.presets
                    .map((p) => _presetTile(p, cs))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 预设网格单元：头像 + 名称 + 角色 + 性格标签。
  Widget _presetTile(CharacterPreset p, ColorScheme cs) {
    return Card(
      margin: EdgeInsets.zero,
      color: cs.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          _applyPreset(p);
          Navigator.pop(context);
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.primary.withOpacity(0.12)),
                    child: Center(
                        child: Text(p.avatar,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: cs.primary))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(p.name,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
              const SizedBox(height: 8),
              Text(p.role,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 6),
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: p.personalityTags
                      .take(3)
                      .map((t) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius: BorderRadius.circular(6)),
                            child: Text(t,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onPrimaryContainer)),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _avatarController.dispose();
    _ageController.dispose();
    _roleController.dispose();
    _systemPromptController.dispose();
    _personalityController.dispose();
    _hourlyLimitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_isEditing ? '编辑角色' : '创建 AI 角色',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 18,
                color: cs.onSurface)),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome_rounded),
            color: cs.primary,
            tooltip: '从预设套用',
            onPressed: _showPresetPicker,
          ),
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
                title: '角色信息', icon: Icons.person_outline_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _nameController,
                        decoration: appInputDecoration(
                            '名字 *', 'AI 的名字', Icons.badge_outlined, cs),
                        validator: (v) => v?.isEmpty ?? true ? '请输入名字' : null,
                      ),
                    ),
                    const SizedBox(width: 14),
                    _buildAvatarPreview(cs),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _ageController,
                        decoration: appInputDecoration(
                            '年龄', '25', Icons.cake_outlined, cs),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v?.isEmpty ?? true) return null;
                          final age = int.tryParse(v!);
                          if (age == null || age < 1 || age > 150) {
                            return '1-150';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: TextFormField(
                        controller: _roleController,
                        decoration: appInputDecoration('角色 *', '游戏达人 / 心理咨询师',
                            Icons.work_outline_rounded, cs),
                        validator: (v) => v?.isEmpty ?? true ? '请输入角色' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _personalityController,
                  decoration: appInputDecoration('性格标签', '话痨, 温柔, 毒舌, 理性...',
                      Icons.psychology_outlined, cs),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AppSectionHeader(
                title: 'AI 配置', icon: Icons.smart_toy_outlined, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                if (_hasLegacyApiData)
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: cs.tertiaryContainer.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 18, color: cs.tertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('该角色已有 API 配置，请选择下方配置以关联',
                              style: TextStyle(
                                  fontSize: 13, color: cs.onSurfaceVariant)),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Consumer(
                        builder: (context, ref, child) {
                          final configs = ref.watch(apiConfigsProvider);

                          return DropdownButtonFormField<String>(
                            value: _selectedApiConfigId.isNotEmpty
                                ? _selectedApiConfigId
                                : null,
                            decoration: appInputDecoration(
                                'API 配置 *',
                                '先在设置中创建 API 配置',
                                Icons.settings_remote_outlined,
                                cs),
                            isExpanded: true,
                            items: [
                              if (configs.isEmpty)
                                const DropdownMenuItem(
                                    value: '',
                                    child: Text('暂无配置，请先在设置中创建',
                                        style: TextStyle(fontSize: 13))),
                              ...configs.map((c) => DropdownMenuItem(
                                    value: c.id,
                                    child: Text(
                                        '${c.name} (${c.provider})',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14)),
                                  )),
                            ],
                            onChanged: configs.isEmpty
                                ? null
                                : (v) {
                                    if (v != null && v.isNotEmpty) {
                                      setState(() {
                                        _selectedApiConfigId = v;
                                      });
                                    }
                                  },
                            validator: (v) =>
                                v == null || v.isEmpty ? '请选择 API 配置' : null,
                          );
                        },
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add_circle_outline_rounded,
                          color: cs.primary, size: 24),
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ApiConfigFormPage()),
                        );
                        setState(() {});
                      },
                      tooltip: '新建配置',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _hourlyLimitController,
                  decoration: appInputDecoration(
                      '每小时回复上限', '默认 5 次/小时', Icons.speed_rounded, cs),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
            const SizedBox(height: 24),
            AppSectionHeader(title: '行为设定', icon: Icons.tune_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                TextFormField(
                  controller: _systemPromptController,
                  decoration: appInputDecoration(
                      'System Prompt',
                      '定义 AI 的行为、风格和知识领域...',
                      Icons.chat_bubble_outline_rounded,
                      cs),
                  maxLines: 8,
                ),
              ],
            ),
            const SizedBox(height: 32),
            AppPrimaryButton(
              onPressed: _isSaving ? null : _save,
              icon: _isEditing ? Icons.check_rounded : Icons.add_rounded,
              label: _isEditing ? '更新角色' : '创建角色',
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarPreview(ColorScheme cs) {
    final displayAvatar = _avatarController.text.isEmpty
        ? (_nameController.text.isNotEmpty ? _nameController.text[0] : '?')
        : _avatarController.text;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.primaryContainer,
        border: Border.all(color: cs.primary.withOpacity(0.2), width: 1.5),
      ),
      child: Center(
          child: Text(displayAvatar,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: cs.onPrimaryContainer))),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    _isSaving = true;
    setState(() {});

    try {
      final c = widget.character;
      ApiConfig? config;

      if (_selectedApiConfigId.isNotEmpty) {
        config =
            ref.read(apiConfigsProvider.notifier).getById(_selectedApiConfigId);
      }

      if (config == null && _hasLegacyApiData && c != null) {
        config = ApiConfig(
          id: 'legacy_${c.id}',
          name: '${c.name} 原有配置',
          provider: c.apiProvider,
          modelName: c.modelName,
          apiKey: c.apiKey,
          customBaseUrl: c.customBaseUrl,
        );
      }

      if (config == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('请选择 API 配置'),
              behavior: SnackBarBehavior.floating));
        }
        _isSaving = false;
        setState(() {});
        return;
      }

      final age = int.tryParse(_ageController.text) ?? 25;
      final hourlyLimit = int.tryParse(_hourlyLimitController.text) ?? 5;
      final personalityTags = _personalityController.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();

      final character = AICharacter(
        id: _existingCharacterId,
        name: _nameController.text.trim(),
        avatar: _avatarController.text.trim().isEmpty
            ? _nameController.text.trim()[0]
            : _avatarController.text.trim(),
        age: age,
        role: _roleController.text.trim(),
        personalityTags: personalityTags,
        systemPrompt: _systemPromptController.text.trim(),
        apiKey: config.apiKey,
        apiProvider: config.provider,
        modelName: config.modelName,
        customBaseUrl: config.customBaseUrl,
        hourlyReplyLimit: hourlyLimit,
        apiConfigId: config.id,
        createdAt: widget.character?.createdAt ?? DateTime.now(),
      );

      if (_isEditing) {
        await ref
            .read(aiCharactersProvider.notifier)
            .updateCharacter(character);
      } else {
        await ref.read(aiCharactersProvider.notifier).addCharacter(character);
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_isEditing ? '角色已更新' : '角色已创建'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('保存失败: $e'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
