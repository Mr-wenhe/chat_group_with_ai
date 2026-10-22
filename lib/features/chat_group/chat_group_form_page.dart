import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/text/pinyin_search.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/required_fields_banner.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';

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
  late TextEditingController _announcementController;
  late TextEditingController _searchController;

  Set<String> _selectedCharacterIds = {};
  bool _isEditing = false;
  bool _isSaving = false;

  /// 点过「创建 / 更新」且当时没通过校验才置位，只控制顶栏汇总提示条是否出现。
  /// 缺项清单每次 build 现算，因此补齐后提示自动消失。
  bool _requiredFieldsRejected = false;
  String? _existingGroupId;
  double _replyIntervalSeconds = 12;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.group != null;
    _existingGroupId = widget.group?.id;
    final g = widget.group;

    _nameController = TextEditingController(text: g?.name ?? '');
    _themeController = TextEditingController(text: g?.theme ?? '');
    _descriptionController = TextEditingController(text: g?.description ?? '');
    _announcementController =
        TextEditingController(text: g?.announcement ?? '');
    _searchController = TextEditingController();
    _selectedCharacterIds = g?.aiCharacterIds.toSet() ?? {};
    _replyIntervalSeconds =
        (g?.replyIntervalSeconds ?? 12).clamp(5, 60).toDouble();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _themeController.dispose();
    _descriptionController.dispose();
    _announcementController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 只在用户点过「创建 / 更新」且当时没通过之后才出提示：一进页面就报"缺名字"
    // 是把尚未开始的填写当成错误。之后每次 build 现算，补齐即消失。
    final missingRequiredFields =
        _requiredFieldsRejected ? _missingRequiredFields() : const <String>[];
    final allCharacters = ref.watch(userManagedAICharactersProvider);
    final query = _searchController.text.trim();
    final filtered = query.isEmpty
        ? allCharacters
        : PinyinSearch.exactFirst(
            allCharacters
                .where((c) => PinyinSearch.matchesFields(
                      c.searchFields,
                      query,
                      mode: PinyinMatchMode.name,
                    ))
                .toList(),
            (c) => PinyinSearch.matchesLiterally(c.searchFields, query),
          );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_isEditing ? '编辑群聊' : '创建群聊',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 18,
                color: cs.onSurface)),
        actions: [
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
        bottom: RequiredFieldsBanner.appBarBottom(
          context: context,
          missingFields: missingRequiredFields,
          cs: cs,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AppSectionHeader(
                title: '群聊信息', icon: Icons.info_outline_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: appInputDecoration('群聊名称 *', '给你的群聊起个名字',
                      Icons.chat_bubble_outline_rounded, cs),
                  onChanged: (_) => _onRequiredFieldChanged(),
                  validator: (v) => _isBlank(v) ? '请输入群聊名称' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _themeController,
                  decoration: appInputDecoration(
                      '主题 *', '例如：职场吐槽大会', Icons.palette_outlined, cs),
                  onChanged: (_) => _onRequiredFieldChanged(),
                  validator: (v) => _isBlank(v) ? '请输入群聊主题' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _descriptionController,
                  decoration: appInputDecoration('共同背景',
                      '例如：我们都叫群主“老大”；小林是阿宽的姐姐', Icons.description_outlined, cs),
                  maxLines: 3,
                ),
                _sharedSettingHint(
                  '每次群聊都会把这段设定告诉本群所有角色：称呼、固定人物关系、'
                  '共同约定都可以写在这里。它由你填写、AI 不会自动改动，'
                  '也不会变成聊天记忆或人物信息卡。',
                  cs,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _announcementController,
                  decoration: appInputDecoration('群公告与约定',
                      '例如：本周冲刺目标、协作规则或禁忌话题', Icons.campaign_outlined, cs),
                  maxLines: 3,
                ),
                _sharedSettingHint(
                  '同样每次群聊都生效，适合放“群内约定”这类所有角色都要遵守的内容。'
                  '内容过长可能放不进模型窗口，届时会明确提示你缩短。',
                  cs,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.speed_rounded, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'AI 回复速率',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface),
                      ),
                    ),
                    Text('${_replyIntervalSeconds.round()} 秒',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: cs.primary)),
                  ],
                ),
                Slider(
                  value: _replyIntervalSeconds,
                  min: 5,
                  max: 60,
                  divisions: 11,
                  label: '${_replyIntervalSeconds.round()} 秒',
                  onChanged: (value) =>
                      setState(() => _replyIntervalSeconds = value),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AppSectionHeader(
                title: '选择角色 *', icon: Icons.person_add_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索角色名称或角色，支持拼音',
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 18, color: cs.onSurfaceVariant),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outlineVariant)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outlineVariant)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.primary, width: 1.5)),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (allCharacters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('还没有角色，请先创建',
                        style: TextStyle(
                            fontSize: 14, color: cs.onSurfaceVariant)),
                  )
                else if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('未找到匹配的角色',
                        style: TextStyle(
                            fontSize: 14, color: cs.onSurfaceVariant)),
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
                      title: Text(c.name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurface)),
                      subtitle: Text('${c.role} · ${c.age}岁',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      activeColor: cs.primary,
                    );
                  }),
              ],
            ),
            const SizedBox(height: 32),
            AppPrimaryButton(
              onPressed: _isSaving ? null : _save,
              icon: _isEditing ? Icons.check_rounded : Icons.add_rounded,
              label: _isEditing ? '更新群聊' : '创建群聊',
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// 固定共同设定两个字段下方的小字说明。
  ///
  /// 单独一行而不是塞进 `hintText`：提示语在用户开始输入后会消失，而"这段设定
  /// 每次群聊都生效、AI 不会改动它"正是填写时最需要知道的事。
  Widget _sharedSettingHint(String text, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, height: 1.4, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 名字 / 主题「填没填」的判据，字段级 `validator` 与顶栏缺项清单**共用**。
  ///
  /// 两边各写一份时边界会分叉：validator 判 `isEmpty`、清单判 `trim().isEmpty`
  /// 的那一版，名称填成全空格就变成"顶栏报缺、字段却没红字"；而保存时统一
  /// `trim()`，空格名称会被静默落库成空串。
  static bool _isBlank(String? value) => (value ?? '').trim().isEmpty;

  /// 点「创建 / 更新」时判定"还缺哪些必填项"的**唯一**判据。
  ///
  /// 「选择角色」不在 `Form` 里，它只有这一处判据。
  List<String> _missingRequiredFields() => [
        if (_isBlank(_nameController.text)) '群聊名称',
        if (_isBlank(_themeController.text)) '主题',
        if (_selectedCharacterIds.isEmpty) '选择角色',
      ];

  /// 顶栏提示条出现之后，输入变化才需要重算缺项清单。
  ///
  /// 无条件 `setState` 会让每次按键都整页 rebuild，连带重跑成员列表的拼音过滤
  /// （`build` 里的 `PinyinSearch.matchesFields`）——CLAUDE.md 的「避免列表内不
  /// 必要的 setState / rebuild」说的就是这种。
  void _onRequiredFieldChanged() {
    if (!_requiredFieldsRejected) return;
    setState(() {});
  }

  Future<void> _save() async {
    if (_isSaving) return;
    // `validate()` 让字段级红字亮起来，必填清单让顶栏把缺项一次说全。
    final formValid = _formKey.currentState!.validate();
    final missingFields = _missingRequiredFields();
    if (!formValid || missingFields.isNotEmpty) {
      setState(() => _requiredFieldsRejected = true);
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
        announcement: _announcementController.text.trim(),
        replyIntervalSeconds: _replyIntervalSeconds.round(),
        aiCharacterIds: _selectedCharacterIds.toList(),
        createdAt: widget.group?.createdAt ?? DateTime.now(),
        ownerName: widget.group?.ownerName,
      );

      if (_isEditing) {
        await ref.read(chatGroupsProvider.notifier).updateGroup(group);
      } else {
        await ref.read(chatGroupsProvider.notifier).addGroup(group);
      }

      if (mounted) {
        AppToast.show(context, _isEditing ? '群聊已更新' : '群聊已创建',
            icon: Icons.check_circle_outline_rounded);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '保存失败: $e', icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
