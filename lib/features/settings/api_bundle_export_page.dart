import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/settings/api_bundle_export_service.dart';
import 'package:chat_group/features/settings/widgets/api_bundle_notice_card.dart';
import 'package:chat_group/providers/providers.dart';

/// 把本机已配好的 API Key 打成一串授权码，便于在其它客户端导入。
///
/// 与导入页不同，这里没有「预览 → 确认」两步：导出不写任何东西，不存在改错了
/// 要撤回的问题。生成后直接展示清单与授权码，用户自己决定要不要用它。
class ApiBundleExportPage extends ConsumerStatefulWidget {
  const ApiBundleExportPage({super.key});

  /// 供入口行共用，避免多处各写一份文案。
  static const String title = '导出 API KEY';

  @override
  ConsumerState<ApiBundleExportPage> createState() =>
      _ApiBundleExportPageState();
}

class _ApiBundleExportPageState extends ConsumerState<ApiBundleExportPage> {
  ApiBundleExportResult? _result;
  String _error = '';
  bool _busy = false;
  bool _copied = false;

  ApiBundleExportService _service() =>
      ApiBundleExportService(db: ref.read(databaseServiceProvider));

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = '';
      _copied = false;
    });
    try {
      final result = await _service().export();
      if (!mounted) return;
      setState(() => _result = result);
    } on Object {
      // 不透传异常文本：导出路径上的异常可能携带载荷片段，那里面全是密钥。
      if (!mounted) return;
      setState(() => _error = '生成失败，请重试。若反复失败，请检查系统安全存储是否可用。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final code = _result?.code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) setState(() => _copied = true);
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
        title: const Text(ApiBundleExportPage.title),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
        children: [
          ApiBundleNoticeCard(cs: cs, message: apiBundleThreatModelNotice),
          const SizedBox(height: 16),
          _actionCard(cs),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 16),
            ApiBundleNoticeCard(
              cs: cs,
              message: _error,
              icon: Icons.error_outline_rounded,
              emphasized: true,
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            _resultSection(cs, _result!),
          ],
        ],
      ),
    );
  }

  Widget _actionCard(ColorScheme cs) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Text(
            '把本机已配置的 API Key 打成一串授权码，在其它客户端用「导入 API KEY」'
            '贴入即可。',
            style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurface),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy ? null : _generate,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: Text(_busy ? '生成中…' : '生成 API KEY'),
            ),
          ),
        ],
      );

  Widget _resultSection(ColorScheme cs, ApiBundleExportResult result) {
    if (!result.hasContent && result.omitted.isEmpty) {
      return AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Text(
            '本机还没有任何已配置的 API Key，没有可导出的内容。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.hasContent) ...[
          _summaryCard(cs, result),
          const SizedBox(height: 16),
          _codeCard(cs, result.code),
        ],
        if (result.omitted.isNotEmpty) ...[
          const SizedBox(height: 16),
          _omittedCard(cs, result.omitted),
        ],
      ],
    );
  }

  Widget _summaryCard(ColorScheme cs, ApiBundleExportResult result) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Text(
            '已包含 ${result.included.length} 项',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          for (final entry in result.included) _entryRow(cs, entry),
        ],
      );

  Widget _codeCard(ColorScheme cs, String code) => AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '授权码',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _copy,
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 16,
                ),
                label: Text(_copied ? '已复制' : '复制'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              // 可选可复制：用户可能想手动挑一段，而不只是整串复制。
              child: SelectableText(
                code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ApiBundleNoticeCard(
            cs: cs,
            message: '这串码解开后就是上面列出的全部密钥，等同于把这些 Key 直接交给对方。'
                '请只通过可信渠道传递，不要贴到公开群组、工单或截图里。',
            icon: Icons.warning_amber_rounded,
            emphasized: true,
          ),
        ],
      );

  Widget _omittedCard(ColorScheme cs, List<ApiBundleExportEntry> omitted) =>
      AppCard(
        cs: cs,
        margin: EdgeInsets.zero,
        children: [
          Text(
            '未能导出 ${omitted.length} 项',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.tertiary,
            ),
          ),
          const SizedBox(height: 12),
          for (final entry in omitted)
            _entryRow(cs, entry, accent: cs.tertiary),
        ],
      );

  Widget _entryRow(
    ColorScheme cs,
    ApiBundleExportEntry entry, {
    Color? accent,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              accent == null
                  ? Icons.check_circle_outline_rounded
                  : Icons.remove_circle_outline_rounded,
              size: 16,
              color: accent ?? cs.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.service.label} · ${entry.title}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  if (entry.detail.isNotEmpty)
                    Text(
                      entry.detail,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  if (entry.fingerprint.isNotEmpty)
                    Text(
                      '密钥指纹 ${entry.fingerprint}',
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}
