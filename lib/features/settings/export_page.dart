import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_export_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 对话导出 / 分享页：选群组 → 选格式(MD/JSON) → 预览 → 导出并落盘 / 分享。
///
/// 安全：导出前弹「不含 API Key」提示；导出内容由 [ConversationExportService]
/// 保证只含展示字段（见该类的红线说明）。
class ExportPage extends ConsumerStatefulWidget {
  /// 可选：从聊天室「导出本群对话」入口进入时预选的群组。
  final String? initialGroupId;

  const ExportPage({super.key, this.initialGroupId});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  String? _selectedGroupId;
  bool _asMarkdown = true;
  bool _isExporting = false;
  String? _preview;

  @override
  void initState() {
    super.initState();
    _selectedGroupId = widget.initialGroupId;
    // 若从聊天室带入群组，首帧后生成预览
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildPreview());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = ref.watch(chatGroupsProvider);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('导出对话',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: cs.onSurface)),
      ),
      body: groups.isEmpty
          ? _buildEmptyState(cs)
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                AppSectionHeader(
                    title: '选择群组', icon: Icons.group_rounded, cs: cs),
                const SizedBox(height: 12),
                AppCard(
                  cs: cs,
                  children: [
                    DropdownButtonFormField<String>(
                      value: _selectedGroupId,
                      decoration: appInputDecoration(
                          '群组', '选择要导出的群聊', Icons.forum_rounded, cs),
                      items: groups
                          .map((g) => DropdownMenuItem(
                              value: g.id, child: Text(g.name)))
                          .toList(),
                      onChanged: (v) {
                        setState(() => _selectedGroupId = v);
                        _rebuildPreview();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                AppSectionHeader(
                    title: '导出格式', icon: Icons.file_present_rounded, cs: cs),
                const SizedBox(height: 12),
                AppCard(
                  cs: cs,
                  children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                            value: true,
                            label: Text('Markdown'),
                            icon: Icon(Icons.description_rounded)),
                        ButtonSegment(
                            value: false,
                            label: Text('JSON'),
                            icon: Icon(Icons.data_object_rounded)),
                      ],
                      selected: {_asMarkdown},
                      onSelectionChanged: (s) {
                        setState(() => _asMarkdown = s.first);
                        _rebuildPreview();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                AppSectionHeader(
                    title: '预览', icon: Icons.visibility_rounded, cs: cs),
                const SizedBox(height: 12),
                AppCard(
                  cs: cs,
                  children: [
                    Container(
                      constraints: const BoxConstraints(maxHeight: 320),
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _preview ?? '选择群组后显示预览',
                          style: TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: cs.onSurface),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                AppPrimaryButton(
                  onPressed:
                      _isExporting || _selectedGroupId == null ? null : _export,
                  icon: Icons.upload_rounded,
                  label: _isExporting ? '导出中...' : '导出并保存',
                ),
                const SizedBox(height: 12),
              ],
            ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.forum_outlined,
              size: 64, color: cs.primary.withOpacity(0.3)),
          const SizedBox(height: 24),
          Text('还没有群组',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('先去创建一个群聊再导出',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// 根据当前选择重新生成预览文本。
  void _rebuildPreview() {
    if (_selectedGroupId == null) {
      setState(() => _preview = null);
      return;
    }
    final db = ref.read(databaseServiceProvider);
    final group = db.chatGroupBox.get(_selectedGroupId!);
    if (group == null) {
      setState(() => _preview = null);
      return;
    }
    final messages = db.messageBox.values
        .where((m) => m.groupId == _selectedGroupId)
        .toList();
    final characters = db.aiCharacterBox.values.toList();
    final charById = {for (final c in characters) c.id: c};
    final service = ConversationExportService();
    final content = _asMarkdown
        ? service.toMarkdown(group, messages, charById)
        : const JsonEncoder.withIndent('  ')
            .convert(service.toJson(group, messages, charById));
    if (mounted) setState(() => _preview = content);
  }

  /// 导出并保存到本机（导出前弹安全提示）。
  Future<void> _export() async {
    if (_selectedGroupId == null) return;
    final confirmed = await _showSafetyDialog();
    if (!confirmed) return;

    setState(() => _isExporting = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final group = db.chatGroupBox.get(_selectedGroupId!);
      if (group == null) {
        _snack('群组不存在');
        return;
      }
      final messages = db.messageBox.values
          .where((m) => m.groupId == _selectedGroupId)
          .toList();
      final characters = db.aiCharacterBox.values.toList();
      final charById = {for (final c in characters) c.id: c};
      final service = ConversationExportService();
      final content = _asMarkdown
          ? service.toMarkdown(group, messages, charById)
          : const JsonEncoder.withIndent('  ')
              .convert(service.toJson(group, messages, charById));

      final ext = _asMarkdown ? 'md' : 'json';
      final fileName = '${_safeFileName(group.name)}_${_timestamp()}.$ext';
      final file = await service.saveToFile(content, fileName);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已保存到：${file.path}'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(label: '分享', onPressed: () => _share(file)),
        ));
      }
    } catch (e) {
      if (mounted) _snack('导出失败: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// 调用系统分享面板分享已导出的文件。
  Future<void> _share(File file) async {
    try {
      await ConversationExportService().share(file);
    } catch (e) {
      if (mounted) _snack('分享失败: $e');
    }
  }

  /// 导出前的安全提示：明文存本机、不含 Key，但仍需妥善保管。
  Future<bool> _showSafetyDialog() async {
    final cs = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.security_rounded, color: cs.primary, size: 28),
        title: const Text('导出前的安全提示'),
        content: const Text(
          '导出的文件为明文文本，保存在本机存储中，仅供你本人查看与备份。\n\n'
          '文件不含任何 API Key 或密钥配置，但仍请妥善保管，避免泄露对话内容。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我知道了，导出')),
        ],
      ),
    );
    return result == true;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  /// 文件名时间戳：`YYYYMMDD_HHMM`。
  String _timestamp() {
    final dt = DateTime.now();
    return '${dt.year}${_pad(dt.month)}${_pad(dt.day)}_${_pad(dt.hour)}${_pad(dt.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  /// 过滤文件名中的非法字符（Windows / 通用）。
  String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'chat_group' : cleaned;
  }
}
