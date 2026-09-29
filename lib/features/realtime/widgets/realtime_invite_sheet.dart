import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/realtime/realtime_protocol.dart';

/// 主人端的「邀请客人」面板。
///
/// 打开时先跑 [onEnsureInviteCode]：没注册过的群在这一步拿到邀请码，已注册的
/// 群直接复用原码。把这段等待放进面板而不是放在打开之前，是为了让失败可以就地
/// 重试——否则一次网络抖动就要用户重新走一遍菜单。
class InviteGuestsSheet extends StatefulWidget {
  /// 群名，用于拼分享文案。
  final String groupName;

  /// 确保群已在服务端注册，返回当前有效的邀请码。抛出的异常会展示在面板里。
  ///
  /// 已注册的群必须复用原邀请码，否则每次点开都会凭空多出一个房间；但如果
  /// 服务端已经把原码弄丢了（重启），这里返回的是一个新码，此时调用方负责
  /// 提醒主人旧码作废——面板只管显示拿到的东西。
  final Future<String> Function() onEnsureInviteCode;

  /// 主人此刻是否连着实时服务。只取快照：面板存活时间很短，
  /// 断线时客人照样能进群，但主人收不到消息，必须提前说清楚。
  final bool online;

  const InviteGuestsSheet({
    super.key,
    required this.groupName,
    required this.onEnsureInviteCode,
    required this.online,
  });

  @override
  State<InviteGuestsSheet> createState() => _InviteGuestsSheetState();
}

class _InviteGuestsSheetState extends State<InviteGuestsSheet> {
  late Future<String> _inviteCode;

  @override
  void initState() {
    super.initState();
    _inviteCode = widget.onEnsureInviteCode();
  }

  void _retry() => setState(() => _inviteCode = widget.onEnsureInviteCode());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _inviteCode,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SheetFrame(child: _PreparingView());
        }
        final error = snapshot.error;
        if (error != null) {
          return _SheetFrame(
            child: _PrepareFailedView(
              // RealtimeGroupException.toString() 已经是中文原因。
              message: error is Exception ? error.toString() : '创建邀请失败',
              onRetry: _retry,
            ),
          );
        }
        return _SheetFrame(
          child: _InviteCodeView(
            groupName: widget.groupName,
            inviteCode: snapshot.data!,
            online: widget.online,
          ),
        );
      },
    );
  }
}

/// 面板外壳：统一的圆角、拖拽条与左右留白，三种状态共用。
class _SheetFrame extends StatelessWidget {
  final Widget child;

  const _SheetFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _InviteCodeView extends StatelessWidget {
  final String groupName;
  final String inviteCode;
  final bool online;

  const _InviteCodeView({
    required this.groupName,
    required this.inviteCode,
    required this.online,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle('邀请客人加入', cs: cs),
        const SizedBox(height: 6),
        Text(
          '把这个邀请码发给客人，让 TA 在「群聊 → 加入群聊」里输入即可。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        _InviteCodeBox(code: inviteCode, cs: cs),
        if (!online) ...[
          const SizedBox(height: 14),
          _OfflineHint(cs: cs),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('复制邀请码'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('分享'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '客人可以看到并参与聊天，但只有你这台设备会调用 AI 生成回复，'
          '所以群里的角色接话取决于你是否在线。',
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: cs.onSurfaceVariant.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: inviteCode));
    if (!context.mounted) return;
    AppToast.show(context, '邀请码已复制', icon: Icons.check_circle_outline_rounded);
  }

  Future<void> _share() async {
    await Share.share(
      '邀请你加入 AI 群聊「$groupName」\n'
      '邀请码：$inviteCode\n'
      '打开 App 的「群聊 → 加入群聊」输入这串码即可。',
      subject: 'AI 群聊邀请',
    );
  }
}

class _PreparingView extends StatelessWidget {
  const _PreparingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 16),
          Text('正在创建邀请码…',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _PrepareFailedView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _PrepareFailedView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle('暂时无法创建邀请', cs: cs),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, height: 1.5, color: cs.error),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('重试'),
        ),
      ],
    );
  }
}

class _SheetTitle extends StatelessWidget {
  final String text;
  final ColorScheme cs;

  const _SheetTitle(this.text, {required this.cs});

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
        ),
      );
}

/// 邀请码的视觉主体：字距拉开、等宽，方便照着念或抄写。
class _InviteCodeBox extends StatelessWidget {
  final String code;
  final ColorScheme cs;

  const _InviteCodeBox({required this.code, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.28)),
      ),
      child: SelectableText(
        code,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          letterSpacing: 8,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: cs.primary,
        ),
      ),
    );
  }
}

class _OfflineHint extends StatelessWidget {
  final ColorScheme cs;

  const _OfflineHint({required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.cloud_off_rounded, size: 16, color: cs.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '你当前未连接实时服务，客人进来后看不到你的发言，AI 也不会接话。',
            style: TextStyle(fontSize: 12, color: cs.error),
          ),
        ),
      ],
    );
  }
}

/// 客人端的「加入群聊」对话框。
///
/// 只做输入与提交，[onSubmit] 抛出的 [Object] 会被当成用户可读的原因直接展示，
/// 因此校验、网络与错误文案全部留在调用方的服务层，对话框不重复实现一套。
class JoinGroupDialog extends StatefulWidget {
  final Future<RealtimeGroupRegistration> Function(String inviteCode) onSubmit;

  const JoinGroupDialog({super.key, required this.onSubmit});

  @override
  State<JoinGroupDialog> createState() => _JoinGroupDialogState();
}

class _JoinGroupDialogState extends State<JoinGroupDialog> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请输入邀请码');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final registration = await widget.onSubmit(code);
      if (!mounted) return;
      Navigator.pop(context, registration);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // RealtimeGroupException.toString() 已经是中文原因；其他异常兜底成通用文案。
        _error = error is Exception ? error.toString() : '加入失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('加入群聊'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '输入主人给你的邀请码。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_submitting,
            textCapitalization: TextCapitalization.characters,
            maxLength: maxRealtimeInviteCodeLength,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '邀请码',
              hintText: '例如 7K2M9P',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _error,
              counterText: '',
            ),
          ),
          if (_submitting) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text('正在查找群聊…',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: const Text('加入'),
        ),
      ],
    );
  }
}
