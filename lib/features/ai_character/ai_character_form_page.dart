import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_presets.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/widgets/character_skill_editor.dart';
import 'package:chat_group/features/ai_character/widgets/ip_portrait_panel.dart';
import 'package:chat_group/providers/providers.dart';
import 'providers/ai_character_providers.dart';
import '../settings/providers/api_config_providers.dart';
import '../settings/api_config_form_page.dart';

/// 哨兵值：无可用配置时占位下拉项的 value，确保不与任何真实 config.id 冲突。
/// （Hive 使用 UUID v4 生成 id，不可能是此字符串，故可安全作为唯一占位值。）
const String _kEmptyConfigValue = '__NO_CONFIG__';

/// 未保存返回确认框的两种「离页」选择。留在本页由遮罩 / 系统返回取消。
enum _UnsavedExitAction { discard, save }

/// 年龄输入框留空 / 填了非数字时的兜底值，与输入框提示一致。
const int _kDefaultAge = 25;

/// 「每小时回复上限」输入框留空 / 填了非数字时的兜底值。
///
/// 必须与 [AICharacter.hourlyReplyLimit] 的默认值（60）、输入框提示「默认 60 次/小时」
/// 和备份解码的 `?? 60` 保持一致：这个值就是用户清空输入框后静默落库的上限。
const int _kDefaultHourlyReplyLimit = 60;

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

  /// 进入页面即预分配 id：IP 形象落盘目录名含角色 id，新建时不能等到保存瞬间
  /// 才生成 uuid，否则生成阶段拿不到稳定 id。
  late final String _existingCharacterId;
  String _selectedApiConfigId = '';
  String _selectedVoiceId = '';
  CharacterGender? _selectedGender;
  bool _isSaving = false;
  bool _agenticEnabled = true;
  bool _webSearchEnabled = false;
  bool _proactiveChatEnabled = true;
  bool _zhipuSearchAnswerOnly = false;
  List<ToolPermission> _toolPermissions = const [];
  Set<String> _selectedSkillTemplateIds = const {};

  /// IP 形象草稿态（表单内存）；持久化由 [_save] 统一落库。
  String _workingIpRelPath = '';
  bool _avatarFromIpImage = false;
  String _workingIpStyle = '';
  final _ipPortraitPanelKey = GlobalKey<IpPortraitPanelState>();

  /// 进入页面时（initState 全部默认值填完之后）的表单快照，用于判断「是否有
  /// 未保存修改」。存储的是归一化后的值，不是控制器本身 —— 见 [_draftSignature]。
  late final List<Object?> _initialSignature;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.character != null;
    _existingCharacterId = widget.character?.id ?? const Uuid().v4();
    // A caller can keep an old character object after returning from this
    // page (for example, an inbox summary). Read the persisted record again
    // so the form never overwrites newer permissions with stale UI state.
    final c = _latestPersistedCharacter();
    _workingIpRelPath = c?.ipImageRelPath ?? '';
    _avatarFromIpImage = c?.avatarFromIpImage ?? false;
    _workingIpStyle = c?.ipImageStyle ?? '';

    _nameController = TextEditingController(text: c?.name ?? '');
    _avatarController = TextEditingController(text: c?.avatar ?? '');
    _ageController =
        TextEditingController(text: c != null ? c.age.toString() : '');
    _roleController = TextEditingController(text: c?.role ?? '');
    _systemPromptController =
        TextEditingController(text: c?.systemPrompt ?? '');
    _personalityController = TextEditingController(
        text: c == null ? '' : c.personalityTags.join(', '));
    _hourlyLimitController = TextEditingController(
        text: (c?.hourlyReplyLimit ?? _kDefaultHourlyReplyLimit).toString());

    _selectedApiConfigId = c?.apiConfigId ?? '';
    _selectedVoiceId = c?.voiceId ?? '';
    _selectedGender = c != null && c.hasKnownGender ? c.gender : null;
    _agenticEnabled = c?.agenticEnabled ?? true;
    _webSearchEnabled = c?.webSearchEnabled ?? false;
    _proactiveChatEnabled = c?.proactiveChatEnabled ?? true;
    _zhipuSearchAnswerOnly = c?.zhipuSearchAnswerOnly ?? false;
    _selectedSkillTemplateIds =
        Set<String>.from(c?.skillIds ?? const <String>[]);
    _toolPermissions = List<ToolPermission>.from(
      c?.toolPermissions ??
          CharacterSkillResolver.defaultsFor(_draftCharacter()).permissions,
    );

    // 新建角色时默认选中配置：自定义(custom)优先（全部默认使用自定义模型），
    // 否则讯飞星火(xfyun)，再否则选第一个可用配置；完全没有配置则保持空置。
    if (_selectedApiConfigId.isEmpty && _isEditing == false) {
      final configs = ref.read(apiConfigsProvider);
      final customConfig =
          configs.where((cfg) => cfg.provider == 'custom').firstOrNull;
      final xfyunConfig =
          configs.where((cfg) => cfg.provider == 'xfyun').firstOrNull;
      if (customConfig != null) {
        _selectedApiConfigId = customConfig.id;
      } else if (xfyunConfig != null) {
        _selectedApiConfigId = xfyunConfig.id;
      } else if (configs.isNotEmpty) {
        _selectedApiConfigId = configs.first.id;
      }
    }

    // 若从「预设快速创建」进入，直接用预设填充展示字段（仍要求后续选 ApiConfig）。
    if (widget.preset != null) _fillFromPreset(widget.preset!);
    if (!_isEditing && widget.preset == null) {
      final bundle = CharacterSkillResolver.defaultsFor(_draftCharacter());
      _agenticEnabled = true;
      _toolPermissions = bundle.permissions;
    }

    // 必须落在最后：上面的默认值（预选 ApiConfig、默认工具权限、预设填充）都是
    // 「用户没动过」的状态，基线取早了会一进页面就被判成已修改。
    _initialSignature = _draftSignature();
  }

  AICharacter? _latestPersistedCharacter() {
    final incoming = widget.character;
    if (incoming == null) return null;
    return ref
            .read(aiCharactersProvider.notifier)
            .getCharacterById(incoming.id) ??
        incoming;
  }

  /// 用预设填充表单控制器（仅展示字段，绝不写入 API Key / 配置）。
  void _fillFromPreset(CharacterPreset p) {
    _nameController.text = p.name;
    _avatarController.text = p.avatar;
    _ageController.text = p.age.toString();
    _roleController.text = p.role;
    _personalityController.text = p.personalityTags.join(', ');
    _systemPromptController.text = p.systemPrompt;
    _zhipuSearchAnswerOnly = p.zhipuSearchAnswerOnly;
    if (_zhipuSearchAnswerOnly) _webSearchEnabled = true;
    if (!_isEditing) {
      final bundle = CharacterSkillResolver.defaultsFor(_draftCharacter());
      _agenticEnabled = bundle.permissions.isNotEmpty;
      _toolPermissions = bundle.permissions;
    }
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
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
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
                        color: cs.primary.withValues(alpha: 0.12)),
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
    final hasKnownGender = widget.character?.hasKnownGender ?? true;

    return PopScope(
      // 恒定 false：判脏必须在「按返回」的瞬间现算，取 build 时缓存下来的值
      // 会因为某个字段忘了 setState 而静默漏判。代价是本页没有 iOS 侧滑返回。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: cs.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(onPressed: _handleBack),
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
                  style: TextStyle(
                      color: cs.primary, fontWeight: FontWeight.w600)),
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
                          onChanged: (_) => setState(() {}),
                          validator: (v) => v?.isEmpty ?? true ? '请输入名字' : null,
                        ),
                      ),
                      const SizedBox(width: 14),
                      _buildAvatarPreview(cs),
                    ],
                  ),
                  const SizedBox(height: 14),
                  IpPortraitPanel(
                    key: _ipPortraitPanelKey,
                    draftBuilder: _draftCharacter,
                    missingFields: _missingPortraitFields,
                    characterId: _existingCharacterId,
                    initialRelPath: _workingIpRelPath,
                    initialAvatarFromIp: _avatarFromIpImage,
                    initialStyle: _workingIpStyle,
                    onChanged: (relPath, avatarFromIp, style) => setState(() {
                      _workingIpRelPath = relPath;
                      _avatarFromIpImage = avatarFromIp;
                      _workingIpStyle = style;
                    }),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                        child: DropdownButtonFormField<CharacterGender>(
                          value: _selectedGender,
                          hint: _isEditing && !hasKnownGender
                              ? const Text('未知（迁移中）')
                              : null,
                          decoration: appInputDecoration(
                            '性别 *',
                            '请选择',
                            _isEditing
                                ? Icons.lock_outline_rounded
                                : Icons.wc_rounded,
                            cs,
                          ).copyWith(
                            helperText:
                                _isEditing ? '创建后不可修改' : '保存后不可修改，并会影响角色称谓与表达。',
                          ),
                          isExpanded: true,
                          items: CharacterGender.values
                              .map((gender) => DropdownMenuItem(
                                    value: gender,
                                    child: Text(gender.label),
                                  ))
                              .toList(growable: false),
                          onChanged: _isEditing
                              ? null
                              : (gender) =>
                                  setState(() => _selectedGender = gender),
                          validator: (gender) =>
                              gender == null && !_isEditing ? '请选择性别' : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _roleController,
                    decoration: appInputDecoration(
                        '角色 *', '游戏达人 / 心理咨询师', Icons.work_outline_rounded, cs),
                    onChanged: (_) => setState(() {}),
                    validator: (v) => v?.isEmpty ?? true ? '请输入角色' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _personalityController,
                    decoration: appInputDecoration('性格标签', '话痨, 温柔, 毒舌, 理性...',
                        Icons.psychology_outlined, cs),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  // 朗读音色：音色 id 来自 voice.md / VoicePreset；空 = 未指定，
                  // 播报时使用语音服务配置里的全局默认音色。
                  DropdownButtonFormField<String>(
                    value: _selectedVoiceId.isEmpty ? null : _selectedVoiceId,
                    hint: const Text('未指定（播报时用语音服务的默认音色）'),
                    decoration: appInputDecoration(
                        '朗读音色',
                        '在“设置 → 语音服务”配置 API Key 后，群聊开启语音播报会朗读',
                        Icons.record_voice_over_outlined,
                        cs),
                    isExpanded: true,
                    items: voicePresets
                        .map((preset) => DropdownMenuItem(
                              value: preset.id,
                              child: Text('${preset.name} · ${preset.id}',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14)),
                            ))
                        .toList(growable: false),
                    onChanged: (voiceId) =>
                        setState(() => _selectedVoiceId = voiceId ?? ''),
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
                  Row(
                    children: [
                      Expanded(
                        child: Consumer(
                          builder: (context, ref, child) {
                            final configs = ref.watch(apiConfigsProvider);

                            return DropdownButtonFormField<String>(
                              // value 映射：
                              // - 有真实选中值且该项仍在配置列表中 → 用选中的 id；
                              // - 关联配置已被删除（id 不在列表）→ 回退为 null，避免 value 不在 items 中触发断言；
                              // - 完全无配置 → 用哨兵值（仅作占位、不可选）；
                              // - 有配置但未选择 → null。
                              value: (configs.isNotEmpty &&
                                      _selectedApiConfigId.isNotEmpty)
                                  ? (configs.any(
                                          (c) => c.id == _selectedApiConfigId)
                                      ? _selectedApiConfigId
                                      : null)
                                  : (configs.isEmpty
                                      ? _kEmptyConfigValue
                                      : null),
                              decoration: appInputDecoration(
                                  'API 配置 *',
                                  '先在设置中创建 API 配置',
                                  Icons.settings_remote_outlined,
                                  cs),
                              isExpanded: true,
                              items: [
                                if (configs.isEmpty)
                                  const DropdownMenuItem(
                                      value: _kEmptyConfigValue,
                                      enabled: false,
                                      child: Text('暂无配置，请先在设置中创建',
                                          style: TextStyle(fontSize: 13))),
                                ...configs.map((c) => DropdownMenuItem(
                                      value: c.id,
                                      child: Text('${c.name} (${c.provider})',
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 14)),
                                    )),
                              ],
                              onChanged: configs.isEmpty
                                  ? null
                                  : (v) {
                                      // 过滤掉哨兵值与空值，确保只接受真实配置 id
                                      if (v != null &&
                                          v != _kEmptyConfigValue &&
                                          v.isNotEmpty) {
                                        setState(() {
                                          _selectedApiConfigId = v;
                                        });
                                      }
                                    },
                              validator: (v) => (v == null ||
                                      v == _kEmptyConfigValue ||
                                      v.isEmpty)
                                  ? '请选择 API 配置'
                                  : null,
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
                        '每小时回复上限', '默认 60 次/小时', Icons.speed_rounded, cs),
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
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              AppSectionHeader(
                  title: '行动能力', icon: Icons.construction_rounded, cs: cs),
              const SizedBox(height: 12),
              AppCard(
                cs: cs,
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _proactiveChatEnabled,
                    onChanged: (value) =>
                        setState(() => _proactiveChatEnabled = value),
                    title: const Text('允许主动聊天'),
                    subtitle: const Text(
                      '关闭后不会主动发起私信，但仍会回复你主动发送的消息',
                    ),
                    secondary:
                        Icon(Icons.mark_chat_unread_rounded, color: cs.primary),
                  ),
                  const Divider(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _webSearchEnabled,
                    onChanged: (value) =>
                        setState(() => _webSearchEnabled = value),
                    title: const Text('允许联网搜索'),
                    subtitle: const Text(
                      '回答时可使用全局搜索设置中的来源；启用“使用模型原生联网搜索”后，将只使用角色模型能力',
                    ),
                    secondary: Icon(Icons.public_rounded, color: cs.primary),
                  ),
                  const Divider(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _zhipuSearchAnswerOnly,
                    onChanged: (value) => setState(() {
                      _zhipuSearchAnswerOnly = value;
                      if (value) _webSearchEnabled = true;
                    }),
                    title: const Text('仅使用智谱搜索问答流程'),
                    subtitle: const Text(
                      '每个问题均先调用智谱网页搜索，再由角色依据编号结果回答；需要 glm-4-flash 配置',
                    ),
                    secondary: Icon(Icons.newspaper_rounded, color: cs.primary),
                  ),
                  const Divider(height: 8),
                  CharacterSkillEditor(
                    enabled: _agenticEnabled,
                    onEnabledChanged: (value) {
                      setState(() {
                        _agenticEnabled = value;
                        if (value && _toolPermissions.isEmpty) {
                          _toolPermissions = CharacterSkillResolver.defaultsFor(
                            _draftCharacter(),
                          ).permissions;
                        }
                      });
                    },
                    inferredSkills:
                        CharacterSkillResolver.defaultsFor(_draftCharacter())
                            .skills,
                    recommendedTemplates:
                        SkillDownloadService.recommendedTemplatesFor(
                      _draftCharacter(),
                    ),
                    selectedTemplateIds: _selectedSkillTemplateIds,
                    onTemplateToggle: (id) {
                      setState(() {
                        final next =
                            Set<String>.from(_selectedSkillTemplateIds);
                        if (next.contains(id)) {
                          next.remove(id);
                        } else {
                          next.add(id);
                        }
                        _selectedSkillTemplateIds = next;
                      });
                    },
                    selectedPermissions: _toolPermissions,
                    onPermissionToggle: (permission) {
                      setState(() {
                        final next =
                            List<ToolPermission>.from(_toolPermissions);
                        if (next.contains(permission)) {
                          next.remove(permission);
                        } else {
                          next.add(permission);
                        }
                        _toolPermissions = next;
                      });
                    },
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
      ),
    );
  }

  Widget _buildAvatarPreview(ColorScheme cs) {
    final displayAvatar = _avatarController.text.isEmpty
        ? (_nameController.text.isNotEmpty ? _nameController.text[0] : '?')
        : _avatarController.text;
    // 仅在「设为头像」开启时出图：这里是「当前生效头像」预览，不是 IP 形象预览。
    final image = _avatarFromIpImage
        ? ref
            .read(databaseServiceProvider)
            .characterAvatarImage(_draftCharacter())
        : null;
    return CharacterAvatar(
      fallbackText: displayAvatar,
      size: 52,
      image: image,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.primaryContainer,
        border:
            Border.all(color: cs.primary.withValues(alpha: 0.2), width: 1.5),
      ),
      textStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: cs.onPrimaryContainer,
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    _isSaving = true;
    setState(() {});

    try {
      ApiConfig? config;

      if (_selectedApiConfigId.isNotEmpty) {
        config =
            ref.read(apiConfigsProvider.notifier).getById(_selectedApiConfigId);
      }

      if (config == null) {
        if (mounted) {
          AppToast.show(context, '请选择 API 配置',
              icon: Icons.info_outline_rounded);
        }
        _isSaving = false;
        setState(() {});
        return;
      }
      if (_zhipuSearchAnswerOnly &&
          (config.provider != 'zhipu' ||
              config.modelName.trim().toLowerCase() != 'glm-4-flash')) {
        if (mounted) {
          AppToast.show(context, '新闻角色需要选择智谱 glm-4-flash API 配置',
              icon: Icons.info_outline_rounded);
        }
        _isSaving = false;
        setState(() {});
        return;
      }

      final age = _parseOrDefault(_ageController.text, _kDefaultAge);
      final hourlyLimit = _parseOrDefault(
          _hourlyLimitController.text, _kDefaultHourlyReplyLimit);
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
        apiKey: '',
        apiProvider: config.provider,
        modelName: config.modelName,
        customBaseUrl: config.customBaseUrl,
        hourlyReplyLimit: hourlyLimit,
        apiConfigId: config.id,
        agenticEnabled: _agenticEnabled,
        skillIds: _mergedSkillIds(),
        toolPermissions:
            _agenticEnabled ? _normalizedToolPermissions() : const [],
        webSearchEnabled: _webSearchEnabled,
        proactiveChatEnabled: _proactiveChatEnabled,
        zhipuSearchAnswerOnly: _zhipuSearchAnswerOnly,
        createdAt: widget.character?.createdAt ?? DateTime.now(),
        gender: _isEditing ? widget.character!.gender : _selectedGender!,
        voiceId: _selectedVoiceId,
        ipImageRelPath: _workingIpRelPath,
        avatarFromIpImage: _avatarFromIpImage,
        ipImageStyle: _workingIpStyle,
      );

      if (_isEditing) {
        await ref
            .read(aiCharactersProvider.notifier)
            .updateCharacter(character);
      } else {
        await ref.read(aiCharactersProvider.notifier).addCharacter(character);
      }

      // 持久化成功才把 IP 形象文件「认领」下来；否则面板 dispose 会按未保存草稿回收。
      _ipPortraitPanelKey.currentState?.markCommitted();

      if (mounted) {
        AppToast.show(context, _isEditing ? '角色已更新' : '角色已创建',
            icon: Icons.check_circle_outline_rounded);
        // Return the exact object that was persisted so an already-mounted
        // chat room can replace its stale in-memory character binding.
        Navigator.pop(context, character);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '保存失败: $e', icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 生成 IP 形象前的必填检查，返回缺失项的显示名（空列表 = 可以生成）。
  ///
  /// 只看与出图有关的三项。API 配置**不拦**：它服务的是聊天补全，生图走独立的
  /// 图像服务配置（面板自己查 `imageServiceConfig`）；为出图强制先配聊天是反
  /// 直觉的。年龄 / 性格标签 / 人设也不拦 —— [buildIpImagePrompt] 对三者都有
  /// 降级，缺了照样拼得出可用 prompt。
  ///
  /// 性别仅新建时拦：编辑态性别被锁死（下面的下拉 `onChanged` 为 null），且
  /// 遗留的未知性别角色本来就靠 `_selectedGender == null` 表达，那不是「没填」。
  List<String> _missingPortraitFields() => [
        if (_nameController.text.trim().isEmpty) '名字',
        if (!_isEditing && _selectedGender == null) '性别',
        if (_roleController.text.trim().isEmpty) '角色',
      ];

  /// 表单文本 → 落库整数值的唯一解析口径。
  ///
  /// [_save] 与 [_draftSignature] 必须共用它：分开写两份时，任何一边改了兜底值都会
  /// 让「是否已修改」的判定与真正写进 [AICharacter] 的值分叉 —— 要么每次返回都弹
  /// 确认框，要么改了却不提示。
  static int _parseOrDefault(String text, int fallback) =>
      int.tryParse(text) ?? fallback;

  /// 归一化后的表单快照，每一项都是 `String` / `int` / `bool`（可直接按值比较）。
  ///
  /// 字段清单必须与 [_save] 写进 [AICharacter] 的项一一对应：
  /// 漏一项就是「改了却不提示」的静默漏判；多带页面内的缓存态则会让用户
  /// 一进页面就被判成已修改。[_selectedSkillTemplateIds] 取原始勾选集合而非
  /// [_mergedSkillIds]：被保留的那些非模板技能 id 来自 `widget.character`，
  /// 本次会话内不会变，不参与「用户改了什么」。
  List<Object?> _draftSignature() {
    final tags = _personalityController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    tags.sort();
    final skills = _selectedSkillTemplateIds.toList()..sort();
    final permissions = _toolPermissions.map((p) => p.name).toList()..sort();
    return <Object?>[
      _nameController.text.trim(),
      _avatarController.text.trim(),
      // 与 [_save] 同一套解析口径（[_parseOrDefault]）：写进库的就是解析结果，
      // 不是输入框原文，因此「清空年龄」和「填 25」在编辑已有 25 岁角色时不算修改。
      _parseOrDefault(_ageController.text, _kDefaultAge),
      _roleController.text.trim(),
      _systemPromptController.text.trim(),
      _parseOrDefault(_hourlyLimitController.text, _kDefaultHourlyReplyLimit),
      tags.join(','),
      skills.join(','),
      permissions.join(','),
      _selectedApiConfigId,
      _selectedVoiceId,
      _selectedGender?.name ?? '',
      _agenticEnabled,
      _webSearchEnabled,
      _proactiveChatEnabled,
      _zhipuSearchAnswerOnly,
      _workingIpRelPath,
      _avatarFromIpImage,
      _workingIpStyle,
    ];
  }

  /// 单向比较：快照元素全是标量，逐项 `!=` 即精确相等（刻意不用哈希，
  /// 「有没有改过」不容许碰撞导致漏判）。
  static bool _signatureEquals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get _isDirty => !_signatureEquals(_initialSignature, _draftSignature());

  /// 返回：无改动直接退出，有改动先二次确认。确认框的两个按钮都指向「离页」，
  /// 留在本页靠点遮罩或系统返回。
  ///
  /// 保存进行中直接忽略返回：那次保存的续体会自己出栈，此处再 pop 一次会落到
  /// 表单下面那一页；弹确认框更糟 —— 保存成功后的 `Navigator.pop(context, character)`
  /// 会先命中栈顶的确认框，用它去 complete `_UnsavedExitAction?` 的 completer
  /// 会抛类型错误。
  Future<void> _handleBack() async {
    if (_isSaving) return;

    if (!_isDirty) {
      Navigator.pop(context);
      return;
    }
    final name = _nameController.text.trim();
    final action = await showDialog<_UnsavedExitAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('资料尚未保存'),
        content: Text(name.isEmpty
            ? '角色资料已修改但尚未保存，返回将丢弃这些修改。'
            : '「$name」的资料已修改但尚未保存，返回将丢弃这些修改。'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _UnsavedExitAction.discard),
            child: Text('放弃保存',
                style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error)),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _UnsavedExitAction.save),
            child: const Text('保存并返回'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == _UnsavedExitAction.discard) {
      Navigator.pop(context);
      return;
    }
    // 复用正式保存流程：校验/落盘失败时 [_save] 自身不会 pop，用户留在本页，
    // 这里不需要（也不应该）再补一次退出。
    await _save();
  }

  AICharacter _draftCharacter() {
    final tags = _personalityController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return AICharacter(
      id: _existingCharacterId,
      name: _nameController.text.trim().isEmpty
          ? '未命名角色'
          : _nameController.text.trim(),
      avatar: _avatarController.text.trim(),
      age: _parseOrDefault(_ageController.text, _kDefaultAge),
      role: _roleController.text.trim(),
      personalityTags: tags,
      systemPrompt: _systemPromptController.text.trim(),
      apiKey: '',
      apiProvider: 'deepseek',
      // 这两项以前漏带，后果是 IP 形象的 LLM 外观改写永远静默走本地模板
      // （[IpPortraitPanelState._describeVisual] 看到空 apiConfigId 就直接
      // return null），音色气质线索也永远不出现，出图不对却无从排查。草稿
      // 必须和 [_save] 一样带全字段 —— 凡是拿草稿拼 prompt 的逻辑都会踩
      // 同一个坑（同 `voiceId` / `withGender` 丢字段那一类事故）。
      apiConfigId: _selectedApiConfigId,
      voiceId: _selectedVoiceId,
      gender:
          _selectedGender ?? widget.character?.gender ?? CharacterGender.female,
      // 必须与 [gender] 同源：`_selectedGender` 为空正是「性别未知」——initState
      // 对 `hasKnownGender == false` 的角色特意把它置 null。漏带本字段会落到
      // 构造默认 `true`，于是未知性别角色被拼成 `a 25-year-old female`。保存
      // 路径由 provider 从库里回填所以看不出来，属「保存对、草稿错」的静默失效。
      hasKnownGender: _selectedGender != null,
      webSearchEnabled: _webSearchEnabled,
      proactiveChatEnabled: _proactiveChatEnabled,
      zhipuSearchAnswerOnly: _zhipuSearchAnswerOnly,
      ipImageRelPath: _workingIpRelPath,
      avatarFromIpImage: _avatarFromIpImage,
      ipImageStyle: _workingIpStyle,
    );
  }

  List<ToolPermission> _normalizedToolPermissions() {
    return List<ToolPermission>.from(_toolPermissions);
  }

  /// 合并保存时的技能 id：保留已有「非模板类」已安装技能（如聊天里下载的其它技能），
  /// 再加上本页勾选的推荐专家模板 id。模板 id 与聊天下载时实例化写入的 id 一致，
  /// 因此重复勾选不会重复计数。
  List<String> _mergedSkillIds() {
    final allTemplateIds =
        ExpertSkillCatalog.templates.map((t) => t.id).toSet();
    final preserved = (widget.character?.skillIds ?? const <String>[])
        .where((id) => !allTemplateIds.contains(id))
        .toList();
    return <String>{...preserved, ..._selectedSkillTemplateIds}.toList();
  }
}
