import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/memory/memory_conflict_resolver.dart';
import 'package:chat_group/features/settings/widgets/user_portrait_section.dart';
import 'package:chat_group/features/settings/widgets/user_profile_privacy_banner.dart';
import 'package:chat_group/providers/providers.dart';

/// 输入过滤常量。
const _kMaxAge = 150;
const _kMinAge = 1;

/// 我的人物信息卡页面。
class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});

  @override
  ConsumerState<UserProfilePage> createState() => UserProfilePageState();
}

/// Test-accessible state class (no underscore) so tests can invoke methods directly.
class UserProfilePageState extends ConsumerState<UserProfilePage> {
  // Test-accessible controllers (no underscore) so tests can invoke methods directly.
  final formKey = GlobalKey<FormState>();
  final displayNameController = TextEditingController();
  final preferredAddressController = TextEditingController();
  final avatarController = TextEditingController();
  final pronounsController = TextEditingController();
  final ageController = TextEditingController();
  final bioController = TextEditingController();
  final personalityController = TextEditingController();
  final interestsController = TextEditingController();
  final importantBackgroundController = TextEditingController();
  bool isSaving = false;

  /// IP 提示词用的性别。null = 未选择，提示词里整段省略性别。
  CharacterGender? selectedGender;

  /// 外观改写所用的聊天 `ApiConfig` id；'' = 不改写。
  String selectedRewriteConfigId = kUserPortraitNoRewriteConfigId;

  // 以下三项与 AI 角色表单同构：生成期间在内存里游走，保存时一并落库。
  String workingIpRelPath = '';
  bool avatarFromIpImage = false;
  String workingIpStyle = '';

  final portraitSectionKey = GlobalKey<UserPortraitSectionState>();

  @override
  void initState() {
    super.initState();
    // 无人物卡时使用安全默认值：显示名为「我」，避免空白状态。
    displayNameController.text = '我';
    // 同步加载已有资料，避免异步 post-frame 回调在测试中导致死循环。
    _loadExistingProfileSync();
  }

  /// 同步加载已有资料到表单。
  void _loadExistingProfileSync() {
    try {
      final db = ref.read(databaseServiceProvider);
      final profile = db.userProfileBox.get('me');
      if (profile == null) return;
      _applyProfileToForm(profile);
    } on Object {
      // Box not yet opened in some test environments.
    }
  }

  /// 把资料填进表单控件。两处加载入口共用一份字段清单，漏字段只可能漏在一处。
  void _applyProfileToForm(UserProfile profile) {
    displayNameController.text = profile.displayName;
    preferredAddressController.text = profile.preferredAddress;
    avatarController.text = profile.avatar;
    pronounsController.text = profile.pronouns;
    ageController.text = profile.age?.toString() ?? '';
    bioController.text = profile.bio;
    personalityController.text = profile.personality.join(', ');
    interestsController.text = profile.interests.join(', ');
    importantBackgroundController.text = profile.importantBackground.join(', ');
    selectedGender = profile.gender;
    selectedRewriteConfigId = profile.apiConfigId;
    workingIpRelPath = profile.ipImageRelPath;
    avatarFromIpImage = profile.avatarFromIpImage;
    workingIpStyle = profile.ipImageStyle;
  }

  @override
  void dispose() {
    displayNameController.dispose();
    preferredAddressController.dispose();
    avatarController.dispose();
    pronounsController.dispose();
    ageController.dispose();
    bioController.dispose();
    personalityController.dispose();
    interestsController.dispose();
    importantBackgroundController.dispose();
    super.dispose();
  }

  Future<void> loadExistingProfile() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final profile = db.userProfileBox.get('me');
      if (!mounted || profile == null) return;
      _applyProfileToForm(profile);
      // No setState needed — TextEditingController.text changes trigger
      // their own widget rebuilds.
    } on Object {
      // Box not yet opened in test environments.
    }
  }

  /// 用户触发的保存入口：校验 → 持久化 → Toast → 关闭页面。
  Future<void> save() async {
    final result = await doSave();
    if (result == null || !mounted) return;
    AppToast.dismiss();
    AppToast.show(context, '人物信息卡已保存', icon: Icons.check_circle_outlined);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// 纯保存逻辑：返回 null 表示未保存（校验失败或已空），
  /// 返回 true 表示已持久化。[skipToast] 仅在测试环境使用。
  Future<bool?> doSave({bool skipToast = false}) async {
    if (!formKey.currentState!.validate() || isSaving) return null;

    final trimmedName = displayNameController.text.trim();
    if (trimmedName.isEmpty) return null;

    isSaving = true;
    setState(() {});

    try {
      final db = ref.read(databaseServiceProvider);
      final now = DateTime.now();
      final existing = db.userProfileBox.get('me');
      // 字数与字段清单都交给 `_draftProfile`：保存与草稿必须同源，见其注释。
      final profile = _draftProfile(
        updatedAt: now,
        createdAt: existing?.createdAt ?? now,
      );
      await db.userProfileBox.put('me', profile);
      await MemoryConflictResolver(db)
          .invalidateConflictingProfileMemories(profile);
      // 持久化成功才回收草稿；失败则交给面板 dispose 按「放弃」处理。
      // 必须早于 dispose，否则本次生成的图会被当成未保存草稿删掉。
      portraitSectionKey.currentState?.markCommitted();
      return true;
    } on Object catch (e) {
      if (!skipToast && mounted) {
        AppToast.show(context, '保存失败：$e', icon: Icons.error_outline_rounded);
      }
      return null;
    } finally {
      isSaving = false;
      if (mounted) setState(() {});
    }
  }

  /// Split a comma-separated string into a deduplicated, trimmed list.
  static List<String> splitList(String raw) {
    final seen = <String>{};
    final result = <String>[];
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) result.add(trimmed);
    }
    return result;
  }

  String? _validateDisplayName(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return '请输入名字';
    return null;
  }

  String? _validateAge(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) return '请输入数字';
    if (n < _kMinAge || n > _kMaxAge) return '请输入 $_kMinAge–$_kMaxAge 之间的整数';
    return null;
  }

  /// 生成 IP 形象前必须填齐的字段。
  ///
  /// 只拦名字与性别：年龄/简介/标签/兴趣/背景都能整段省略、优雅降级，拦它们
  /// 只会逼用户编内容。性别必填是因为下拉本身就是二选一，「不选」没有意义。
  List<String> _missingPortraitFields() => [
        if (displayNameController.text.trim().isEmpty) '名字',
        if (selectedGender == null) '性别',
      ];

  /// 取表单**当前草稿**（不落库）。
  ///
  /// 面板拼 prompt / 喂改写模型时调用；[doSave] 也必须经它组装。**字段清单只此
  /// 一份** —— 曾经保存与草稿各列一遍，而 `UserProfile` 没有 `copyWith`、保存是
  /// 全量重建，加字段漏改一处就会「保存静默丢字段」或「生成用旧值」
  /// （角色表单的 `_draftCharacter` 就踩过这个坑）。
  ///
  /// [updatedAt] / [createdAt] 只在保存时传：面板用不到时间戳，传 null 时由
  /// 构造函数兜成当前时刻。
  UserProfile _draftProfile({DateTime? updatedAt, DateTime? createdAt}) {
    final ageText = ageController.text.trim();
    final parsedAge = ageText.isEmpty ? null : int.tryParse(ageText);
    return UserProfile(
      id: 'me',
      displayName: displayNameController.text.trim(),
      preferredAddress: preferredAddressController.text.trim(),
      avatar: avatarController.text.trim(),
      pronouns: pronounsController.text.trim(),
      age: (parsedAge != null && parsedAge >= _kMinAge && parsedAge <= _kMaxAge)
          ? parsedAge
          : null,
      bio: bioController.text.trim(),
      personality: splitList(personalityController.text),
      interests: splitList(interestsController.text),
      importantBackground: splitList(importantBackgroundController.text),
      gender: selectedGender,
      ipImageRelPath: workingIpRelPath,
      avatarFromIpImage: avatarFromIpImage,
      ipImageStyle: workingIpStyle,
      apiConfigId: selectedRewriteConfigId,
      updatedAt: updatedAt,
      createdAt: createdAt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displayAvatar = avatarController.text.trim().isEmpty
        ? (displayNameController.text.trim().isNotEmpty
            ? displayNameController.text.trim()[0]
            : '?')
        : avatarController.text.trim();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          '我的资料',
          style: TextStyle(
              fontWeight: FontWeight.w700, fontSize: 20, color: cs.onSurface),
        ),
        actions: [
          TextButton.icon(
            onPressed: isSaving ? null : save,
            icon: Icon(
                isSaving ? Icons.hourglass_empty_rounded : Icons.check_rounded,
                size: 18),
            label: Text(isSaving ? '保存中...' : '保存'),
          ),
        ],
      ),
      body: Form(
        key: formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 隐私提示 ─────────────────────────────────────────────────────────
              UserProfilePrivacyBanner(cs: cs),
              const SizedBox(height: 20),

              // ── 基本信息 ────────────────────────────────────────────────────────
              AppSectionHeader(title: '基本信息', cs: cs),
              const SizedBox(height: 12),
              AppCard(
                cs: cs,
                children: [
                  Row(
                    children: [
                      // 「当前生效头像」预览：仅在「设为头像」开启时出图，
                      // 未开启/未生成时回落 emoji 或名字首字。
                      CharacterAvatar(
                        key: const ValueKey('user-avatar-preview'),
                        fallbackText: displayAvatar,
                        size: 52,
                        image: ref
                            .read(databaseServiceProvider)
                            .userAvatarImage(_draftProfile()),
                        // 走 `decoration` 而不是 `background`：描边是原来那个
                        // `_AvatarPreview` 的样式，换 widget 时漏掉会让预览比
                        // 页面其它头像少一圈边。
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: cs.primaryContainer,
                          border: Border.all(
                            color: cs.primary.withValues(alpha: 0.2),
                            width: 1.5,
                          ),
                        ),
                        textStyle: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextFormField(
                          controller: displayNameController,
                          decoration: appInputDecoration('名字 *',
                              '你在 AI 面前的显示名称', Icons.badge_outlined, cs),
                          // IP 形象的生成门禁看名字是否为空，输入时要刷新提示行。
                          onChanged: (_) => setState(() {}),
                          validator: _validateDisplayName,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: preferredAddressController,
                    decoration: appInputDecoration('称呼', 'AI 默认如何称呼你（留空则用名字）',
                        Icons.record_voice_over_outlined, cs),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: avatarController,
                    decoration: appInputDecoration('头像', '单个 emoji 或头像标识',
                        Icons.emoji_emotions_outlined, cs),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── 个人详情 ────────────────────────────────────────────────────────
              AppSectionHeader(title: '个人详情', cs: cs),
              const SizedBox(height: 12),
              AppCard(
                cs: cs,
                children: [
                  TextFormField(
                    controller: pronounsController,
                    decoration: appInputDecoration(
                        '称谓 / 代词', '如：他/她/TA', Icons.transgender_rounded, cs),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: ageController,
                          decoration: appInputDecoration('年龄',
                              '$_kMinAge–$_kMaxAge，可留空', Icons.cake_outlined, cs),
                          keyboardType: TextInputType.number,
                          validator: _validateAge,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: DropdownButtonFormField<CharacterGender>(
                          value: selectedGender,
                          decoration: appInputDecoration(
                            '性别',
                            '用于 IP 形象',
                            Icons.wc_rounded,
                            cs,
                          ).copyWith(
                            helperText: '只喂 IP 形象提示词；称谓/代词仍用上面那栏',
                          ),
                          isExpanded: true,
                          items: CharacterGender.values
                              .map((gender) => DropdownMenuItem(
                                    value: gender,
                                    child: Text(gender.label),
                                  ))
                              .toList(growable: false),
                          onChanged: (value) =>
                              setState(() => selectedGender = value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: bioController,
                    decoration: appInputDecoration(
                        '个人简介', '用一段话描述自己', Icons.description_outlined, cs),
                    maxLines: 3,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── 性格与兴趣 ────────────────────────────────────────────────────────
              AppSectionHeader(title: '性格与兴趣', cs: cs),
              const SizedBox(height: 12),
              AppCard(
                cs: cs,
                children: [
                  TextFormField(
                    controller: personalityController,
                    decoration: appInputDecoration('性格标签', '用逗号分隔，如：温柔、理性、幽默',
                        Icons.psychology_outlined, cs),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: interestsController,
                    decoration: appInputDecoration(
                        '兴趣', '用逗号分隔，如：画画、爬山、爵士乐', Icons.favorite_outlined, cs),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── 重要背景 ──────────────────────────────────────────────────────────
              AppSectionHeader(title: '重要背景', cs: cs),
              const SizedBox(height: 12),
              AppCard(
                cs: cs,
                children: [
                  TextFormField(
                    controller: importantBackgroundController,
                    decoration: appInputDecoration('重要背景 / 明确事实',
                        '用逗号分隔，如：住在上海、有一只猫', Icons.public_outlined, cs),
                    maxLines: 3,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── IP 形象 ────────────────────────────────────────────────────────
              UserPortraitSection(
                key: portraitSectionKey,
                draftProfile: _draftProfile,
                missingFields: _missingPortraitFields,
                apiConfigId: selectedRewriteConfigId,
                onApiConfigIdChanged: (value) =>
                    setState(() => selectedRewriteConfigId = value),
                initialRelPath: workingIpRelPath,
                initialAvatarFromIp: avatarFromIpImage,
                initialStyle: workingIpStyle,
                onChanged: (relPath, avatarFromIp, style) => setState(() {
                  workingIpRelPath = relPath;
                  avatarFromIpImage = avatarFromIp;
                  workingIpStyle = style;
                }),
              ),
              const SizedBox(height: 28),

              // ── 底部保存按钮 ──────────────────────────────────────────────────────
              TextButton(
                onPressed: isSaving ? null : save,
                child: Text(isSaving ? '保存中...' : '保存人物信息卡'),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
