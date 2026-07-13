import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _port = 18080;

Future<HttpServer> startMockOpenAiServer({int port = _port}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('Mock OpenAI server: http://127.0.0.1:${server.port}/v1');
  return server;
}

Future<void> serveMockOpenAiRequests(HttpServer server) async {
  await for (final request in server) {
    if (request.method != 'POST' ||
        !request.uri.path.endsWith('/chat/completions')) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('not found');
      await request.response.close();
      continue;
    }
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    final messages = (body['messages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final prompt =
        messages.map((m) => m['content']?.toString() ?? '').join('\n');
    final last =
        messages.isEmpty ? '' : messages.last['content']?.toString() ?? '';
    final content = _reply(prompt, last);
    stdout.writeln(
      'POST ${request.uri.path} stream=${body['stream'] == true} '
      'messages=${messages.length} reply=${content.length}',
    );
    if (body['stream'] == true) {
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set('Cache-Control', 'no-cache');
      for (final chunk in _chunks(content, 80)) {
        request.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': chunk}
                }
              ]
            })}\n\n');
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }
      request.response.write('data: ${jsonEncode({
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'}
            ],
            'usage': {
              'prompt_tokens': 120,
              'completion_tokens': content.length ~/ 3,
            }
          })}\n\n');
      request.response.write('data: [DONE]\n\n');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'model': 'codex-local-test',
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content}
          }
        ],
        'usage': {
          'prompt_tokens': 120,
          'completion_tokens': content.length ~/ 3,
        }
      }));
    }
    await request.response.close();
  }
}

Future<void> main() async {
  final server = await startMockOpenAiServer();
  await serveMockOpenAiRequests(server);
}

String _reply(String prompt, String last) {
  if (_looksLikeToolResult(last)) {
    return '任务已完成。我已检查工具执行结果，目标文件已成功写入，并确认内容完整可用。';
  }
  final requested = _requestedArtifact(prompt);
  if (requested != null && _looksAgentic(prompt)) {
    return '```agent_tool\n${jsonEncode({
          'tool': 'workspace.patch',
          'reason': '按中文任务要求生成完整且可验证的技能文件',
          'args': {'path': requested.$1, 'content': requested.$2}
        })}\n```';
  }
  if (prompt.contains('测试') && prompt.contains('API')) {
    return '连接成功';
  }
  return '收到。我会先确认需求，再执行任务，并在关键阶段持续汇报进度。';
}

bool _looksLikeToolResult(String value) {
  final lower = value.toLowerCase();
  return lower.contains('工具执行结果') ||
      lower.contains('tool result') ||
      lower.contains('readbackcontent') ||
      (lower.contains('workspace.patch') && lower.contains('success'));
}

bool _looksAgentic(String prompt) {
  final lower = prompt.toLowerCase();
  return lower.contains('agent_tool') ||
      lower.contains('workspace.patch') ||
      lower.contains('工具调用');
}

(String, String)? _requestedArtifact(String prompt) {
  if (prompt.contains('陈思远') || prompt.contains('sales_analysis.py')) {
    return (
      'sales_analysis.py',
      """import csv
from collections import defaultdict

def summarize_sales(path: str) -> dict[str, float]:
    totals: dict[str, float] = defaultdict(float)
    with open(path, newline='', encoding='utf-8') as source:
        for row in csv.DictReader(source):
            totals[row['产品']] += float(row['销售额'])
    return dict(sorted(totals.items(), key=lambda item: item[1], reverse=True))

if __name__ == '__main__':
    print(summarize_sales('sales.csv'))
"""
    );
  }
  if (prompt.contains('林雅雯') || prompt.contains('product_requirement.md')) {
    return (
      'product_requirement.md',
      """# AI 团队任务看板 PRD

## 目标
让用户清晰查看角色任务、实时进度、文件产物和失败恢复入口。

## 核心用户故事
- 作为群主，我可以使用 @ 指派单个角色。
- 作为用户，我可以看到规划、执行、校验、完成四个阶段。
- 作为用户，我可以直接打开 AI 生成的文件附件。

## 验收标准
1. 任务开始后 1 秒内出现进度卡片。
2. 每次工具执行后更新阶段、步骤数和文件名。
3. 失败时保留已完成文件并提供继续执行入口。
"""
    );
  }
  if (prompt.contains('周启明') || prompt.contains('dashboard.html')) {
    return (
      'dashboard.html',
      """<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>AI 团队看板</title>
<style>body{font-family:system-ui;background:#0f172a;color:#e2e8f0;margin:0;padding:32px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.card{background:#1e293b;padding:20px;border-radius:16px}.ok{color:#4ade80}</style></head>
<body><h1>AI 团队任务看板</h1><div class="grid"><section class="card"><h2>进行中</h2><p>3 个任务</p></section><section class="card"><h2>已完成</h2><p class="ok">12 个文件</p></section><section class="card"><h2>成功率</h2><p>98%</p></section></div></body>
</html>
"""
    );
  }
  if (prompt.contains('赵文博') || prompt.contains('test_plan.md')) {
    return (
      'test_plan.md',
      """# AI 文件任务测试计划

## 范围
私聊文件生成、群聊 @ 路由、进度更新、附件打开、任务恢复。

## 用例
1. 私聊要求生成 Python 文件，校验文件名与关键函数。
2. 群聊 @ 指定角色，确保只有被点名角色执行。
3. 工具执行期间验证规划、执行、校验、完成阶段可见。
4. 模拟写入失败，验证错误提示与继续执行入口。

## 通过条件
所有关键路径通过，生成文件可读取且内容不为空。
"""
    );
  }
  if (prompt.contains('唐若溪') || prompt.contains('security_checklist.md')) {
    return (
      'security_checklist.md',
      """# AI 工作区安全检查清单

- [ ] 路径必须是工作区内的安全相对路径
- [ ] 禁止在聊天、日志或导出中泄露 API Key
- [ ] 写文件前展示目标路径与权限原因
- [ ] 群聊仅响应明确 @ 的高权限任务
- [ ] 工具失败保留审计记录并支持恢复
- [ ] 附件内容与实际落盘内容一致
"""
    );
  }
  return null;
}

Iterable<String> _chunks(String value, int size) sync* {
  for (var i = 0; i < value.length; i += size) {
    yield value.substring(i, i + size > value.length ? value.length : i + size);
  }
}
