import 'dart:convert';
import 'dart:io';

/// Synthetic model only; the app's search/read/download still access real public sources.
Future<void> main(List<String> args) async {
  if (args.contains('--self-check')) {
    assert(_networkReply('NETWORK_UI_ACCEPTANCE 用户已提供的公开来源编号', '').contains('web.search'));
    assert(_networkReply('NETWORK_UI_ACCEPTANCE 用户已提供的公开来源编号', 'web.search').contains('web.read'));
    assert(_networkReply('NETWORK_UI_ACCEPTANCE 用户已提供的公开来源编号', 'web.search web.read').contains('web.download'));
    assert(!_networkReply('NETWORK_UI_ACCEPTANCE', '').contains('agent_tool'));
    assert(jsonDecode(_workReply(''))['tool']['name'] == 'web.search');
    assert(jsonDecode(_workReply('{"tool":"web.search"}'))['tool']['name'] == 'web.read');
    assert(jsonDecode(_workReply('{"tool":"web.search"} {"tool":"web.read"}'))['tool']['name'] == 'web.download');
    assert(jsonDecode(_workReply('{"tool":"web.search"} {"tool":"web.read"} {"tool":"web.download"}'))['action'] == 'finish');
    stdout.writeln('UI mock self-check passed');
    return;
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4,
      int.tryParse(Platform.environment['UI_MOCK_PORT'] ?? '') ?? 0);
  stdout.writeln('UI_MOCK_URL=http://127.0.0.1:${server.port}/v1');
  await for (final request in server) {
    request.response.headers.contentType = ContentType.json;
    if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
      request.response.write(jsonEncode({'data': [{'id': 'network-ui-fixture'}]}));
      await request.response.close();
      continue;
    }
    if (request.method != 'POST' || !request.uri.path.endsWith('/chat/completions')) {
      request.response.statusCode = 404;
      await request.response.close();
      continue;
    }
    final raw = await utf8.decoder.bind(request).join();
    if (raw.length > 300000) { request.response.statusCode = 413; await request.response.close(); continue; }
    final body = jsonDecode(raw) as Map;
    final messages = body['messages'] as List? ?? [];
    final all = messages.map((value) => (value as Map)['content'].toString()).join('\n');
    final assistant = messages.where((value) => (value as Map)['role'] == 'assistant')
        .map((value) => (value as Map)['content'].toString()).join('\n');
    final content = all.contains('WORK_NETWORK_UI_ACCEPTANCE') &&
            all.contains('严格的 AgentDecision JSON object')
        ? _workReply(all)
        : _networkReply(all, assistant);
    if (body['stream'] == true) {
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('data: ${jsonEncode({'choices': [{'delta': {'content': content}}]})}\n\n');
      request.response.write('data: ${jsonEncode({'choices': [{'delta': {}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 40}})}\n\n');
      request.response.write('data: [DONE]\n\n');
    } else {
      request.response.write(jsonEncode({'choices': [{'message': {'content': content}}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 40}}));
    }
    await request.response.close();
    stdout.writeln('UI_MOCK_REQUEST stream=${body['stream'] == true} responseLength=${content.length}');
  }
}

String _workReply(String context) {
  bool completed(String name) => RegExp('"tool"\\s*:\\s*"web\\.$name"').hasMatch(context);
  final name = !completed('search')
      ? 'web.search'
      : !completed('read')
          ? 'web.read'
          : !completed('download')
              ? 'web.download'
              : null;
  return jsonEncode({
    'action': name == null ? 'finish' : 'tool',
    'public_update': name == null ? '联网动作结束，交付结果由应用核验。' : '正在调用 $name。',
    'tool': name == null ? null : {
      'name': name,
      'arguments': name == 'web.search'
          ? {'query': 'Flutter documentation'}
          : {'sourceId': 's1', if (name == 'web.download') 'fileName': 'README.md'},
    },
    'completion': name == null ? {
      'summary': 'WORK_NETWORK_UI_ACCEPTANCE：请核对下载的 README.md。',
      'evidence': ['实际工具回执供应用核验'],
    } : null,
  });
}

String _networkReply(String all, String assistant) {
  if (!all.contains('NETWORK_UI_ACCEPTANCE') ||
      !all.contains('公开来源编号')) {
    return '连接成功。';
  }
  String tool(String name, Map<String, dynamic> args) =>
      '```agent_tool\n${jsonEncode({'tool': name, 'args': args, 'reason': 'isolated UI acceptance'})}\n```';
  return !assistant.contains('web.search')
      ? tool('web.search', {'query': 'Flutter documentation'})
      : !assistant.contains('web.read')
          ? tool('web.read', {'sourceId': 's1'})
          : !assistant.contains('web.download')
              ? tool('web.download', {'sourceId': 's1', 'fileName': 'README.md'})
              : 'NETWORK_UI_ACCEPTANCE：已完成真实搜索、正文读取和文件下载，请查看来源与附件。[W1]';
}
