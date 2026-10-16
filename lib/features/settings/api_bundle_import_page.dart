import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/features/settings/api_bundle_import_models.dart';
import 'package:chat_group/features/settings/api_bundle_import_service.dart';
import 'package:chat_group/features/settings/widgets/api_bundle_notice_card.dart';
import 'package:chat_group/providers/providers.dart';

/// 用一串授权码一次性配置四类服务。
///
/// 分四步走一条直线：粘贴 → 解析并预览 → 确认 → 结果。做成独立页面而不是对话框，
/// 是因为授权码是几千字符，需要多行输入框；而且「先看清要改什么」本身就需要一块
/// 能放下若干行的版面。
class ApiBundleImportPage extends ConsumerStatefulWidget {
  const ApiBundleImportPage({super.key});

  /// 供入口行共用，避免多处各写一份文案。
  static const String title = '导入 API KEY';

  @override
  ConsumerState<ApiBundleImportPage> createState() =>
      _ApiBundleImportPageState();
}

class _ApiBundleImportPageState extends ConsumerState<ApiBundleImportPage> {
  final TextEditingController _controller = TextEditingController();

  ApiBundle? _bundle;
  BundleImportPlan? _plan;
  BundleImportResult? _result;
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    // 输入框里是本机上唯一的授权码副本。离开页面即销毁，不留残余。
    _controller.dispose();
    super.dispose();
  }

  ApiBundleImportService _service() =>
      ApiBundleImportService(db: ref.read(databaseServiceProvider));

  Future<void> _decodeAndPlan() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = '';
      _result = null;
      _plan = null;
      _bundle = null;
    });
    try {
      final bundle = ApiBundle.parse(ApiBundleCodec.open(_controller.text));
      final service = _service();
      // 先问环境能不能写凭据。不能写就现在拦下，而不是让用户确认一堆变更之后
      // 才逐条失败。
      service.ensureSupported();
      final plan = service.plan(bundle);
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _plan = plan;
        // 解析成功后立刻清空输入框：授权码已经解出来了，没必要再留一份在内存与
        // 输入法缓冲里。
        _controller.clear();
      });
    } on ApiBundleFormatError catch (error) {
      _fail(error.message);
    } on ApiBundleAuthError catch (error) {
      _fail(error.message);
    } on BundleImportRejected catch (error) {
      _fail(error.message);
    } finally {
      // 成功路径也必须复位：漏掉它会让「确认导入」永远停在「写入中…」且不可点，
      // 用户看到的是一张渲染正确、却怎么点都没反应的预览页。
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final bundle = _bundle;
    if (bundle == null) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final result = await _service().apply(bundle);
      if (!mounted) return;
      // 导入是直接写 `apiConfigBox` 的，绕过了这个 notifier 自己的写方法。不补这
      // 一下，返回「API KEY 设置」页时看到的仍是导入前的列表：配置其实已经落盘
      // 并被角色用上，界面却显示「尚未配置」。角色表单的「API 配置」下拉框同理。
      ref.read(apiConfigsProvider.notifier).reload();
      setState(() {
        _result = result;
        _plan = null;
        _bundle = null;
      });
    } on BundleImportRejected catch (error) {
      _fail(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 错误文案一律来自具名异常，**绝不回显输入内容**——授权码本身是凭据，
  /// 贴进错误提示里就等于写进截图和日志。
  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _busy = false;
    });
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
        title: const Text(ApiBundleImportPage.title),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
        children: [
          ApiBundleNoticeCard(cs: cs, message: apiBundleThreatModelNotice),
          const SizedBox(height: 16),
          if (_result != null)
            _resultCard(cs, _result!)
          else ...[
            _inputCard(cs),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              _errorCard(cs, _error),
            ],
            if (_plan != null) ...[
              const SizedBox(height: 16),
              _previewCard(cs, _plan!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _inputCard(ColorScheme cs) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Text(
            '粘贴授权码',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '可以整段粘贴，也可以带换行。解析后会先列出将要发生的改动。',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 6,
            minLines: 4,
            // 授权码不是自然语言：关掉自动纠正与首字母大写，否则移动端输入法会
            // 悄悄改掉字符，用户只会看到「校验失败」。
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'BBK1.…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy ? null : _decodeAndPlan,
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(_busy ? '解析中…' : '解析并预览'),
            ),
          ),
        ],
      );

  Widget _errorCard(ColorScheme cs, String message) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: cs.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(fontSize: 13, color: cs.error, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      );

  Widget _previewCard(ColorScheme cs, BundleImportPlan plan) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          if (plan.label.isNotEmpty) ...[
            Text(
              plan.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            '将新增 ${plan.createCount} 条、覆盖 ${plan.overwriteCount} 条、'
            '跳过 ${plan.skipCount} 条',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          for (final change in plan.changes) _changeRow(cs, change),
          const SizedBox(height: 16),
          _rollbackNote(cs),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: (_busy || !plan.hasWork) ? null : _confirm,
              icon: const Icon(Icons.download_done_rounded, size: 18),
              label: Text(_busy ? '写入中…' : '确认导入'),
            ),
          ),
        ],
      );

  Widget _changeRow(ColorScheme cs, BundleChange change) {
    final color = switch (change.action) {
      BundleChangeAction.create => cs.primary,
      BundleChangeAction.overwrite => cs.tertiary,
      BundleChangeAction.skip => cs.onSurfaceVariant,
    };
    final icon = switch (change.action) {
      BundleChangeAction.create => Icons.add_circle_outline_rounded,
      BundleChangeAction.overwrite => Icons.sync_rounded,
      BundleChangeAction.skip => Icons.remove_circle_outline_rounded,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${change.action.label} · ${change.service.label} · '
                  '${change.title}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                if (change.detail.isNotEmpty)
                  Text(
                    change.detail,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                if (change.keyFingerprint.isNotEmpty)
                  Text(
                    // 只给指纹不给密钥：用户能拿它和生成工具打印的同一指纹对照，
                    // 但看不到密钥的任何字符。
                    '密钥指纹 ${change.keyFingerprint}',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rollbackNote(ColorScheme cs) => Text(
        '导入按条进行，不做整体回滚：已经写好的条目不会因为后面某条失败而撤销，'
        '失败的那条会在结果里单独说明。',
        style: TextStyle(fontSize: 12, height: 1.4, color: cs.onSurfaceVariant),
      );

  Widget _resultCard(ColorScheme cs, BundleImportResult result) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Row(
            children: [
              Icon(
                result.hasFailure
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded,
                size: 18,
                color: result.hasFailure ? cs.tertiary : cs.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '成功 ${result.successCount} 条，失败 ${result.failureCount} 条',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final outcome in result.outcomes) _outcomeRow(cs, outcome),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() {
                _result = null;
                _error = '';
              }),
              child: const Text('再导入一串'),
            ),
          ),
        ],
      );

  Widget _outcomeRow(ColorScheme cs, BundleImportOutcome outcome) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              outcome.succeeded
                  ? Icons.check_rounded
                  : Icons.close_rounded,
              size: 16,
              color: outcome.succeeded ? cs.primary : cs.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${outcome.service.label} · ${outcome.title}',
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                  if (!outcome.succeeded)
                    Text(
                      outcome.reason,
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}
