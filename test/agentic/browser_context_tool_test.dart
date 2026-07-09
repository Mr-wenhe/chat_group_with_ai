import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser snapshot trims huge page text', () {
    final snapshot = BrowserContextSnapshot(
      url: 'https://example.com/doc',
      title: 'Doc',
      selectedText: '',
      pageText: 'a' * 20000,
      capturedAt: DateTime(2026, 7, 9),
    );

    expect(snapshot.safePageText.length, 12000);
  });
}
