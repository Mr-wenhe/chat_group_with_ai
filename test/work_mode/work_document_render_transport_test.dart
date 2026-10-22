import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_agent_loop.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each request sends only the newest rendered page as a native image',
      () {
    const pageOne = 'data:image/png;base64,cGFnZTE=';
    const pageTwo = 'data:image/png;base64,cGFnZTI=';
    final parts = workDocumentImageParts(
      {
        'recentToolResults': [
          _renderedPage(1, pageOne),
          _renderedPage(2, pageTwo),
        ],
      },
      sanitizeText: (value) => value,
    );

    expect(parts, hasLength(2));
    expect(parts!.first['text'], 'plan.docx 第 2 页');
    expect((parts.last['image_url'] as Map)['url'], pageTwo);
  });

  test('browser screenshots reach the tester as native images only on success',
      () {
    const screenshot = 'data:image/png;base64,c2NyZWVuc2hvdA==';
    final parts = workDocumentImageParts(
      {
        'recentToolResults': [
          _browserPage(screenshot, status: 'failed'),
          _browserPage(screenshot),
        ],
      },
      sanitizeText: (value) => value,
    );

    expect(parts, hasLength(2));
    expect(parts!.first['text'], '当前冻结 HTML 页面');
    expect((parts.last['image_url'] as Map)['url'], screenshot);
  });
}

Map<String, dynamic> _renderedPage(int page, String url) => {
      'tool': AgentToolName.workspaceDocument.wireName,
      'status': WorkToolResultStatus.success.name,
      'data': {
        'content': [
          {'type': 'text', 'text': 'plan.docx 第 $page 页'},
          {
            'type': 'image_url',
            'image_url': {'url': url}
          },
        ],
      },
    };

Map<String, dynamic> _browserPage(String url, {String status = 'success'}) => {
      'tool': AgentToolName.browserContext.wireName,
      'status': status,
      'data': {
        'content': [
          {'type': 'text', 'text': '当前冻结 HTML 页面'},
          {
            'type': 'image_url',
            'image_url': {'url': url}
          },
        ],
      },
    };
