import 'local_agent_bridge_client.dart';

class BrowserContextSnapshot {
  final String url;
  final String title;
  final String selectedText;
  final String pageText;
  final DateTime capturedAt;

  const BrowserContextSnapshot({
    required this.url,
    required this.title,
    required this.selectedText,
    required this.pageText,
    required this.capturedAt,
  });

  String get safePageText =>
      pageText.length <= 12000 ? pageText : pageText.substring(0, 12000);
}

/// Browser context adapter owned by ordinary/compatibility agentic callers.
/// Production work mode does not route browser actions through this adapter.
class BrowserContextTool {
  final LocalAgentBridgeClient bridge;

  BrowserContextTool(this.bridge);

  Future<BrowserContextSnapshot> currentTab() async {
    final data = await bridge.postJson('/browser/current-tab', const {});
    return BrowserContextSnapshot(
      url: data['url'] as String? ?? '',
      title: data['title'] as String? ?? '',
      selectedText: data['selectedText'] as String? ?? '',
      pageText: data['pageText'] as String? ?? '',
      capturedAt: DateTime.tryParse(data['capturedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
