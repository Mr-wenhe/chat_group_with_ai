import 'dart:async';

import 'package:flutter/material.dart';

import '../visible_browser_service.dart';

/// A non-modal handoff panel. It only exposes public page text and safe
/// navigation metadata; browser controls remain in the native WebView window.
class VisibleBrowserPanel extends StatelessWidget {
  final List<VisibleBrowserSession> sessions;
  final String? selectedSessionId;
  final ValueChanged<String> onSelectSession;
  final FutureOr<void> Function(String sessionId) onContinue;
  final FutureOr<void> Function(String sessionId) onClose;
  final VoidCallback onClosePanel;
  final FutureOr<void> Function(String sessionId)? onBringToForeground;
  final FutureOr<void> Function()? onInstallRuntime;

  const VisibleBrowserPanel({
    super.key,
    required this.sessions,
    required this.selectedSessionId,
    required this.onSelectSession,
    required this.onContinue,
    required this.onClose,
    required this.onClosePanel,
    this.onBringToForeground,
    this.onInstallRuntime,
  });

  @override
  Widget build(BuildContext context) {
    final session = _selectedSession;
    return Material(
      key: const Key('visible-browser-panel'),
      elevation: 12,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surface,
      child: session == null
          ? const Center(child: Text('暂无可见浏览器会话'))
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(context, session),
                  if (sessions.length > 1) _sessionTabs(context),
                  const SizedBox(height: 8),
                  Expanded(child: _details(context, session)),
                ],
              ),
            ),
    );
  }

  VisibleBrowserSession? get _selectedSession {
    if (sessions.isEmpty) return null;
    for (final session in sessions) {
      if (session.id == selectedSessionId) return session;
    }
    return sessions.last;
  }

  Widget _header(BuildContext context, VisibleBrowserSession session) {
    return Row(
      children: <Widget>[
        const Icon(Icons.public_rounded, size: 20),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            '可见浏览器接管',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          key: const Key('visible-browser-close'),
          tooltip: '关闭可见浏览器接管窗口（任务继续）',
          onPressed: session.status == VisibleBrowserStatus.closed
              ? null
              : () => onClose(session.id),
          icon: const Icon(Icons.close_rounded),
        ),
        IconButton(
          key: const Key('visible-browser-panel-close'),
          tooltip: '关闭可见浏览器接管面板',
          onPressed: onClosePanel,
          icon: const Icon(Icons.close_fullscreen_rounded),
        ),
      ],
    );
  }

  Widget _sessionTabs(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: sessions
            .map(
              (session) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  key: Key('visible-browser-tab-${session.id}'),
                  label: Text(session.host),
                  selected: session.id == selectedSessionId,
                  onSelected: (_) => onSelectSession(session.id),
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Widget _details(BuildContext context, VisibleBrowserSession session) {
    final theme = Theme.of(context);
    final showContinue = session.status == VisibleBrowserStatus.paused ||
        session.status == VisibleBrowserStatus.closed;
    return ListView(
      children: <Widget>[
        Text(
          '域名：${session.host}',
          key: const Key('visible-browser-domain'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text('状态：${_statusLabel(session.status)}'),
        if (session.title.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(session.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        if (session.message.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(session.message),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          '导航记录',
          key: const Key('visible-browser-navigation'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        ...session.navigation.map(
          (entry) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.arrow_outward_rounded, size: 16),
            title: Text(entry.host),
            subtitle: Text(
              entry.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (session.status == VisibleBrowserStatus.ready &&
            session.pageText.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('公开页面正文', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(session.pageText),
        ],
        if (showContinue) ...<Widget>[
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('visible-browser-continue'),
            onPressed: () => onContinue(session.id),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              session.status == VisibleBrowserStatus.closed
                  ? '重新打开并继续'
                  : '完成网页操作后继续',
            ),
          ),
        ],
        if (session.runtimeUnavailable && onInstallRuntime != null) ...<Widget>[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('visible-browser-install-runtime'),
            onPressed: onInstallRuntime,
            icon: const Icon(Icons.download_outlined),
            label: const Text('打开官方安装流程'),
          ),
        ],
        if (onBringToForeground != null && session.isOpen) ...<Widget>[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('visible-browser-focus'),
            onPressed: () => onBringToForeground!(session.id),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('显示浏览器窗口'),
          ),
        ],
      ],
    );
  }

  String _statusLabel(VisibleBrowserStatus status) => switch (status) {
        VisibleBrowserStatus.opening => '加载中',
        VisibleBrowserStatus.ready => '可读取公开内容',
        VisibleBrowserStatus.paused => '等待人工处理',
        VisibleBrowserStatus.closed => '窗口已关闭（任务继续）',
        VisibleBrowserStatus.failed => '读取失败',
      };
}
