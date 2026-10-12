import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/ai_character/widgets/ip_portrait_panel.dart';
import 'package:chat_group/features/ai_character/widgets/ip_portrait_source.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';

/// 「留空则不改写」的下拉值。用空串而不是 null：[DropdownButtonFormField]
/// 的 `value` 为 null 时会掉进 hint 分支，选中态显示不出来。
const String kUserPortraitNoRewriteConfigId = '';

/// 「我的资料」页的「IP 形象」组：外观改写模型下拉 + 生成面板。
///
/// 从 `user_profile_page.dart` 拆出来：主表单页在加入性别下拉与本组后会越过
/// 500 行红线，而「形象怎么生成」自成一块，与资料录入的关注点不同。
class UserPortraitSection extends ConsumerStatefulWidget {
  const UserPortraitSection({
    super.key,
    required this.draftProfile,
    required this.missingFields,
    required this.apiConfigId,
    required this.onApiConfigIdChanged,
    required this.initialRelPath,
    required this.initialAvatarFromIp,
    required this.initialStyle,
    required this.onChanged,
  });

  /// 取表单**当前草稿**（姓名/性别/简介/标签/兴趣/背景都还在内存里）。
  final UserProfile Function() draftProfile;

  /// 返回「缺失的必填项」的显示名；空列表才允许生成。
  final List<String> Function() missingFields;

  /// 外观改写所用的聊天 `ApiConfig` id；'' = 不改写。
  final String apiConfigId;
  final void Function(String configId) onApiConfigIdChanged;

  /// 以下三项**仅在 initState 读取一次**，此后变更经 [onChanged] 单向上报。
  final String initialRelPath;
  final bool initialAvatarFromIp;
  final String initialStyle;

  final void Function(String relPath, bool avatarFromIp, String style) onChanged;

  @override
  ConsumerState<UserPortraitSection> createState() => UserPortraitSectionState();
}

class UserPortraitSectionState extends ConsumerState<UserPortraitSection> {
  /// 面板自身的 GlobalObjectKey：面板在本 State 的 build 里创建，用父级传入的
  /// GlobalKey 会撞上「同一个 key 出现在两处」（页面与本 State 各持一份）。
  final _panelKey = GlobalKey<IpPortraitPanelState>();

  /// 表单持久化成功后点名调用，把草稿回收从「放弃」改判为「现在」。
  ///
  /// 与 [IpPortraitPanelState.markCommitted] 同名同义，只是多一跳转发 ——
  /// 让页面只需要认识本 State，不必再去摸面板的 key。
  void markCommitted() => _panelKey.currentState?.markCommitted();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeader(title: 'IP 形象', cs: cs),
        const SizedBox(height: 12),
        AppCard(
          cs: cs,
          children: [
            _buildRewriteConfigDropdown(cs),
            const SizedBox(height: 14),
            IpPortraitPanel(
              key: _panelKey,
              draftBuilder: () =>
                  IpPortraitSource.fromUserProfile(widget.draftProfile()),
              missingFields: widget.missingFields,
              initialRelPath: widget.initialRelPath,
              initialAvatarFromIp: widget.initialAvatarFromIp,
              initialStyle: widget.initialStyle,
              onChanged: widget.onChanged,
            ),
          ],
        ),
      ],
    );
  }

  /// 外观改写所用的聊天模型。留空 = 不改写，直接用本地模板拼 prompt。
  ///
  /// 必须能选「不改写」：改写要额外调一次 LLM（25s 超时、按 token 计费），
  /// 不是人人都想为一张头像多花这一次调用。
  Widget _buildRewriteConfigDropdown(ColorScheme cs) {
    final configs = ref.watch(apiConfigsProvider);
    return DropdownButtonFormField<String>(
      key: const ValueKey('user-portrait-rewrite-config'),
      value: configs.any((config) => config.id == widget.apiConfigId)
          ? widget.apiConfigId
          : kUserPortraitNoRewriteConfigId,
      isExpanded: true,
      decoration: appInputDecoration(
        '外观改写所用聊天模型',
        '留空则用本地模板',
        Icons.auto_fix_high_outlined,
        cs,
      ),
      items: [
        const DropdownMenuItem<String>(
          value: kUserPortraitNoRewriteConfigId,
          child: Text('不改写（本地模板）', overflow: TextOverflow.ellipsis),
        ),
        for (final config in configs)
          DropdownMenuItem<String>(
            value: config.id,
            child: Text(config.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) =>
          widget.onApiConfigIdChanged(value ?? kUserPortraitNoRewriteConfigId),
    );
  }
}
