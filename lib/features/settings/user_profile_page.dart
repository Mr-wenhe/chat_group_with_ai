import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/memory/memory_conflict_resolver.dart';
import 'package:chat_group/providers/providers.dart';

/// 输入过滤常量。
const _kMaxAge = 150;
const _kMinAge = 1;

/// 隐私提示文案。
const _kPrivacyNotice = '这些资料可能随聊天上下文发送给你配置的第三方 LLM 服务。';

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
      displayNameController.text = profile.displayName;
      preferredAddressController.text = profile.preferredAddress;
      avatarController.text = profile.avatar;
      pronounsController.text = profile.pronouns;
      ageController.text = profile.age?.toString() ?? '';
      bioController.text = profile.bio;
      personalityController.text = profile.personality.join(', ');
      interestsController.text = profile.interests.join(', ');
      importantBackgroundController.text =
          profile.importantBackground.join(', ');
    } on Object {
      // Box not yet opened in some test environments.
    }
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
      displayNameController.text = profile.displayName;
      preferredAddressController.text = profile.preferredAddress;
      avatarController.text = profile.avatar;
      pronounsController.text = profile.pronouns;
      ageController.text = profile.age?.toString() ?? '';
      bioController.text = profile.bio;
      personalityController.text = profile.personality.join(', ');
      interestsController.text = profile.interests.join(', ');
      importantBackgroundController.text =
          profile.importantBackground.join(', ');
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
      final ageText = ageController.text.trim();
      final int? parsedAge = ageText.isEmpty ? null : int.tryParse(ageText);

      final now = DateTime.now();
      final existing = db.userProfileBox.get('me');
      final profile = UserProfile(
        id: 'me',
        displayName: trimmedName,
        preferredAddress: preferredAddressController.text.trim(),
        avatar: avatarController.text.trim(),
        pronouns: pronounsController.text.trim(),
        age: (parsedAge != null &&
                parsedAge >= _kMinAge &&
                parsedAge <= _kMaxAge)
            ? parsedAge
            : null,
        bio: bioController.text.trim(),
        personality: splitList(personalityController.text),
        interests: splitList(interestsController.text),
        importantBackground: splitList(importantBackgroundController.text),
        updatedAt: now,
        createdAt: existing?.createdAt ?? now,
      );
      await db.userProfileBox.put('me', profile);
      await MemoryConflictResolver(db)
          .invalidateConflictingProfileMemories(profile);
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
              _PrivacyBanner(cs: cs),
              const SizedBox(height: 20),

              // ── 基本信息 ────────────────────────────────────────────────────────
              AppSectionHeader(title: '基本信息', cs: cs),
              const SizedBox(height: 12),
              AppCard(
                cs: cs,
                children: [
                  Row(
                    children: [
                      _AvatarPreview(displayAvatar: displayAvatar, cs: cs),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextFormField(
                          controller: displayNameController,
                          decoration: appInputDecoration('名字 *',
                              '你在 AI 面前的显示名称', Icons.badge_outlined, cs),
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
                  TextFormField(
                    controller: ageController,
                    decoration: appInputDecoration('年龄',
                        '$_kMinAge–$_kMaxAge，可留空', Icons.cake_outlined, cs),
                    keyboardType: TextInputType.number,
                    validator: _validateAge,
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

/// 隐私提示横幅。
class _PrivacyBanner extends StatelessWidget {
  final ColorScheme cs;
  const _PrivacyBanner({required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.tertiary.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 18, color: cs.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _kPrivacyNotice,
              style: TextStyle(
                fontSize: 13,
                color: cs.onTertiaryContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 头像预览圆标。
class _AvatarPreview extends StatelessWidget {
  final String displayAvatar;
  final ColorScheme cs;

  const _AvatarPreview({
    required this.displayAvatar,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.primaryContainer,
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.2),
          width: 1.5,
        ),
      ),
      child: Center(
        child: Text(
          displayAvatar,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: cs.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
