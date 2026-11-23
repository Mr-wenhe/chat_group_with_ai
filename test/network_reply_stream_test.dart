import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/web_search/application/search_context_formatter.dart';
import 'package:chat_group/features/web_search/desktop/network_reply_stream.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';

class FailedSearchService extends DesktopWebService {
  FailedSearchService(this.failure)
      : super(WebWorkerClient(executable: '/unused', entryPoint: '/unused'));
  final Object failure;
  int searchCalls = 0;
  @override
  Future<List<Map<String, String>>> search(String query,
      {Future<void>? cancellation}) async {
    searchCalls++;
    throw failure;
  }
}

class SuccessfulSearchService extends DesktopWebService {
  SuccessfulSearchService()
      : super(WebWorkerClient(executable: '/unused', entryPoint: '/unused'));

  int searchCalls = 0;

  @override
  Future<List<Map<String, String>>> search(String query,
      {Future<void>? cancellation}) async {
    searchCalls++;
    const url = 'https://docs.flutter.dev/release/archive';
    final sourceId = registerSource(url);
    return [
      {
        'source_id': sourceId,
        'title': 'Flutter release archive',
        'url': url,
        'snippet': 'Stable release notes and dates',
        'provider': 'test-public-search',
      },
    ];
  }
}

class FailedPublicSourceWorker extends WebWorkerClient {
  FailedPublicSourceWorker()
      : super(executable: '/unused', entryPoint: '/unused');

  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    yield {
      'status': 'error',
      'code': 'SOURCE_HTTP_ERROR',
      'sourceStatus': 429,
      'retryable': true,
    };
  }
}

void main() {
  test('默认联网工具额度为 6 次', () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    var finalTurnContents = const <String>[];
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': '检索公开 Flutter 资料'}
      ],
      generate: (messages) {
        final index = calls++;
        if (index >= 7) {
          finalTurnContents =
              messages.map((m) => m['content']?.toString() ?? '').toList();
          return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.done,
            content: '根据已有资料作答。',
          ));
        }
        return Stream.value(ChatStreamEvent(
          type: ChatStreamEventType.done,
          content:
              '```agent_tool {"tool":"web.search","args":{"query":"Flutter docs $index"}} ```',
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) {},
    ).toList();

    expect(service.searchCalls, networkReplyToolCallLimit);
    expect(calls, networkReplyToolCallLimit + 2,
        reason: '六次工具 + 一次被拒 + 一次最终作答');
    expect(finalTurnContents.any((c) => c.contains('上限')), isTrue);
    expect(events.last.content, '根据已有资料作答。');
  });

  test('expired tool budget allows only one final model request', () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: [],
      toolBudget: Duration.zero,
      generate: (messages) {
        final index = calls++;
        if (index == 1) {
          expect(messages.last['content'], contains('请直接用已获得的资料回答'));
        }
        return Stream.value(ChatStreamEvent(
          type: ChatStreamEventType.done,
          content:
              '```agent_tool {"tool":"web.search","args":{"query":"Flutter $index"}}```',
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(service.searchCalls, 0);
    expect(calls, 2);
    expect(events.last.message, networkReplyLimitError);
  });

  test('an explicitly labeled JSONC tool configuration stays visible', () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    const sample = '```jsonc\n{"tool":"formatter","enabled":true}\n```';
    final events = await networkReplyStream(
      messages: [],
      generate: (_) => Stream.value(ChatStreamEvent.done(sample)),
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(service.searchCalls, 0);
    expect(events.last.content, sample);
  });

  test('模型正文为空的流式完成会重试后再执行联网工具', () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': '查 RFC 9110 的官方资料'},
      ],
      generate: (_) {
        calls++;
        if (calls == 1) {
          return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.error,
            message: '模型返回了空内容',
            sanitized: true,
          ));
        }
        return Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: '根据 RFC 9110 官方资料作答。',
        ));
      },
      retryGenerate: (_) => Stream.value(const ChatStreamEvent(
        type: ChatStreamEventType.done,
        content:
            '```agent_tool {"tool":"web.search","args":{"query":"RFC 9110 IETF"}} ```',
      )),
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(calls, 2, reason: '空流完成只重试一次，然后生成最终答复');
    expect(service.searchCalls, 1, reason: '重试产生工具请求后才执行搜索');
    expect(events.last.type, ChatStreamEventType.done);
    expect(events.last.content, '根据 RFC 9110 官方资料作答。');
  });

  test('工具调用达到上限后要求模型直接用已有资料作答', () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    var finalTurnContents = const <String>[];
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': '查一下巴厘岛一月的天气'}
      ],
      generate: (messages) {
        final index = calls++;
        if (index >= 3) {
          finalTurnContents =
              messages.map((m) => m['content']?.toString() ?? '').toList();
          return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.done,
            content: '根据已有资料，一月巴厘岛约 26-30°C。',
          ));
        }
        return Stream.value(ChatStreamEvent(
          type: ChatStreamEventType.done,
          content:
              '```agent_tool {"tool":"web.search","args":{"query":"bali january climate $index"}} ```',
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) {},
      maxToolCalls: 2,
    ).toList();

    expect(service.searchCalls, 2, reason: '工具最多执行 2 次');
    expect(calls, 4, reason: '两次工具 + 一次被拒 + 一次最终作答');
    expect(finalTurnContents.any((c) => c.contains('上限')), isTrue,
        reason: '超过工具上限后必须把结论交回模型');
    expect(events.last.content, contains('26-30'));
  });

  test(
      'one malformed tool reply can be corrected without executing its payload',
      () async {
    final service = FailedSearchService(StateError('SOURCE_HTTP_ERROR'));
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': 'Search official docs'}
      ],
      generate: (messages) {
        final index = calls++;
        if (index == 1) {
          expect(messages.last['content'], contains('未执行'));
          expect(messages.first['content'], 'Search official docs');
        }
        return Stream.value(ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: switch (index) {
            0 => '```agent_tool {invalid',
            1 =>
              '```agent_tool {"tool":"web.search","args":{"query":"official docs"}} ```',
            _ => '查询失败，未取得证据。',
          },
          promptTokens: 10,
          completionTokens: 5,
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();
    expect(calls, 3);
    expect(events.last.type, ChatStreamEventType.done);
    expect(events.last.promptTokens, 30);
    expect(events.where((e) => e.delta?.contains('invalid') == true), isEmpty);
  });

  test('a second malformed tool reply fails as protocol after one correction',
      () async {
    final service = FailedSearchService(StateError('tool must not run'));
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': 'Search official docs'}
      ],
      generate: (messages) {
        if (calls++ == 1) {
          expect(messages.last['content'], contains('上一条联网请求格式无效'));
        }
        return Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: '```agent_tool {invalid',
          promptTokens: 10,
          completionTokens: 5,
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(calls, 2);
    expect(service.searchCalls, 0);
    expect(events.last.type, ChatStreamEventType.error);
    expect(events.last.message, networkReplyFormatError);
    expect(events.where((event) => event.delta != null), isEmpty);
  });

  for (final known in [true, false]) {
    test('tool errors expose only safe codes known=$known', () async {
      final service = FailedSearchService(StateError(known
          ? '联网请求失败：SOURCE_HTTP_ERROR'
          : 'unexpected password=private-test-value'));
      addTearDown(service.worker.close);
      var calls = 0;
      await networkReplyStream(
        messages: [],
        generate: (messages) {
          if (calls++ == 0) {
            return Stream.value(const ChatStreamEvent(
                type: ChatStreamEventType.done,
                content:
                    '```agent_tool {"tool":"web.search","args":{"query":"official"}} ```'));
          }
          expect(messages.last['content'],
              contains(known ? 'SOURCE_HTTP_ERROR' : 'NETWORK_TOOL_FAILED'));
          expect(
              messages.last['content'], isNot(contains('private-test-value')));
          return Stream.value(const ChatStreamEvent(
              type: ChatStreamEventType.done, content: '查询失败。'));
        },
        service: service,
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download expected'),
      ).toList();
    });
  }

  for (final tool in ['web.read', 'web.download']) {
    test('$tool preserves safe public source status metadata', () async {
      final root = await Directory.systemTemp.createTemp('web_tool_error_');
      addTearDown(() => root.delete(recursive: true));
      final worker = FailedPublicSourceWorker();
      addTearDown(worker.close);
      final service = DesktopWebService(worker);
      final sourceId = service.registerSource('https://example.com/README.md');
      var calls = 0;
      String? resultEnvelope;

      final events = await networkReplyStream(
        messages: const [
          {'role': 'user', 'content': 'Read or download the registered file.'}
        ],
        generate: (messages) {
          if (calls++ == 0) {
            final args = tool == 'web.read'
                ? {'sourceId': sourceId, 'startSection': 0}
                : {'sourceId': sourceId, 'fileName': 'README.md'};
            return Stream.value(ChatStreamEvent(
              type: ChatStreamEventType.done,
              content: '```agent_tool ${jsonEncode({
                    'tool': tool,
                    'args': args
                  })} ```',
            ));
          }
          resultEnvelope = messages
              .map((message) => message['content'])
              .whereType<String>()
              .firstWhere(
                (content) => content.startsWith('【工具返回的不可信外部资料'),
              );
          return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.done,
            content: '来源返回 HTTP 429，未取得文件内容。',
          ));
        },
        service: service,
        downloadDirectory: () async => root,
        isActive: () => true,
        onDownload: (_) =>
            fail('A failed download cannot create an attachment'),
      ).toList();

      expect(calls, 2);
      expect(events.last.content, '来源返回 HTTP 429，未取得文件内容。');
      expect(resultEnvelope, contains('"code":"SOURCE_HTTP_ERROR"'));
      expect(resultEnvelope, contains('"sourceStatus":429'));
      expect(resultEnvelope, contains('"retryable":true'));
      expect(resultEnvelope, contains('HTTP 429'));
      expect(await root.list().toList(), isEmpty);
    });
  }

  test(
      'an unregistered source returns recovery instructions without guessing HTTP status',
      () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    var calls = 0;
    await networkReplyStream(
      messages: [],
      generate: (messages) {
        if (calls++ == 0) {
          return Stream.value(const ChatStreamEvent(
              type: ChatStreamEventType.done,
              content:
                  '```agent_tool {"tool":"web.read","args":{"sourceId":"S1"}} ```'));
        }
        expect(messages.last['content'], contains('SOURCE_NOT_REGISTERED'));
        expect(messages.last['content'], contains('web.search'));
        expect(messages.last['content'], isNot(contains('503')));
        return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.done, content: '需要重新查找来源。'));
      },
      service: DesktopWebService(worker),
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();
    expect(calls, 2);
  });
  test('normal reply streams without invoking networking', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(type: ChatStreamEventType.token, delta: 'Hello'),
              ChatStreamEvent(type: ChatStreamEventType.done, content: 'Hello'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No downloads expected')).toList();
    expect(events.first.delta, 'Hello');
    expect(events.last.content, 'Hello');
  });

  test('normal chat exposes public web tools while Work mode is off', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': 'Search and download public documentation.'}
      ],
      generate: (context) {
        final protocol = context
            .where((message) => message['role'] == 'system')
            .map((message) => message['content']?.toString() ?? '')
            .join('\n');
        expect(protocol, contains('不需要开启工作模式'));
        expect(protocol, contains('工作模式关闭不影响公开网络搜索'));
        expect(protocol, contains('用户明确要求搜索、读取或下载公开来源时，必须按本协议实际调用工具'));
        expect(protocol, contains('不要声称当前会话没有工具通道'));
        return Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: '收到。',
        ));
      },
      service: DesktopWebService(worker),
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('本测试不执行下载'),
    ).toList();

    expect(events.last.content, '收到。');
  });

  test(
      'network stream can search after the ordinary reply gets a Zhipu failure',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    final zhipuFailurePrompt = const SearchContextFormatter()
        .format(
          WebSearchSnapshot(
            searchedAt: DateTime.utc(2026, 11, 17),
            provider: 'zhipu-native',
            results: const [],
            failure: const SearchFailure(
              type: SearchFailureType.rateLimited,
              safeMessage: '请求受限',
              statusCode: 429,
              retryable: true,
            ),
          ),
        )
        .prompt;
    final messages = [
      {'role': 'system', 'content': zhipuFailurePrompt},
      {'role': 'user', 'content': '查询 Flutter 稳定版的最新发布日期'},
    ];
    var calls = 0;
    final events = await networkReplyStream(
      messages: messages,
      generate: (context) {
        if (calls++ == 0) {
          expect(
            context.map((message) => message['content']).join('\n'),
            contains('本次搜索失败'),
          );
          return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.done,
            content:
                '```agent_tool {"tool":"web.search","args":{"query":"Flutter stable release notes"}} ```',
          ));
        }
        expect(
          context.map((message) => message['content']).join('\n'),
          contains('Flutter release archive'),
        );
        return Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: '自主搜索已返回 Flutter 官方发布档案。',
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('此搜索回归不应下载'),
    ).toList();

    expect(calls, 2);
    expect(service.searchCalls, 1);
    expect(events.last.content, '自主搜索已返回 Flutter 官方发布档案。');
  });

  test('tool continuations add reported usage without leaking protocol',
      () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    var calls = 0;
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable([
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: calls++ == 0
                      ? '```agent_tool {"tool":"workspace.list","args":{}} ```'
                      : 'Finished',
                  promptTokens: 10,
                  completionTokens: 3,
                  cachedTokens: 2),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No downloads expected')).toList();
    expect(calls, 2);
    expect(events.last.content, 'Finished');
    expect(events.last.promptTokens, 20);
    expect(events.last.completionTokens, 6);
    expect(events.last.cachedTokens, 4);
    expect(events.last.cacheWriteTokens, isNull);
    expect(events.where((event) => event.delta?.contains('agent_tool') == true),
        isEmpty);
  });
  test('invalid tool envelope is hidden and never executed', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: '```agent_tool {invalid')
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();
    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.sanitized, isTrue);
  });

  test('a ```json fence carrying a tool request is executed, not printed',
      () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    var calls = 0;
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable([
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: calls++ == 0
                      ? '```json\n'
                          '{"tool":"web.search","args":{"query":"github 前端 skill"},"reason":"查仓库"}\n'
                          '```'
                      : '搜到了。'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No downloads expected')).toList();

    expect(calls, 2);
    expect(events.last.content, '搜到了。');
    expect(
      events.where((event) => (event.delta ?? '').contains('"tool"')),
      isEmpty,
      reason: '围栏里的 JSON 不能出现在聊天里',
    );
  });

  test('a standalone streamed tool JSON request executes, not prints',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    const payload =
        '{"tool":"web.search","args":{"query":"Flutter official repository"},"reason":"find the official repository"}';
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': 'Search the official Flutter repository.'}
      ],
      generate: (_) {
        if (calls++ == 0) {
          return Stream.fromIterable([
            const ChatStreamEvent(
                type: ChatStreamEventType.token, delta: '{"tool":"web.'),
            const ChatStreamEvent(
                type: ChatStreamEventType.token,
                delta:
                    'search","args":{"query":"Flutter official repository"},"reason":"find the official repository"}'),
            const ChatStreamEvent(type: ChatStreamEventType.done),
          ]);
        }
        return Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: 'The official repository search returned a result.',
        ));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(calls, 2);
    expect(service.searchCalls, 1);
    expect(events.last.content,
        'The official repository search returned a result.');
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, isNot(contains(payload)));
    expect(visible, isNot(contains('"tool"')));
    final receipts = service.evidenceSnapshot()['toolReceipts'] as List;
    expect(receipts, hasLength(1));
    expect(receipts.single, containsPair('tool', 'web.search'));
    expect(receipts.single, containsPair('status', 'success'));
  });

  test('a standalone JSON data sample without a tool key stays visible',
      () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    const sample = '{"status":"example","count":2}';
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': 'Show a small JSON example.'}
      ],
      generate: (_) => Stream.value(const ChatStreamEvent(
        type: ChatStreamEventType.done,
        content: sample,
      )),
      service: DesktopWebService(worker),
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(events.last.content, sample);
    expect(events.map((event) => event.delta ?? '').join(), sample);
  });

  test('protocol repair preserves the final answer turn at the tool limit',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: [],
      maxToolCalls: 1,
      generate: (_) {
        final content = switch (calls++) {
          0 =>
            '```agent_tool {"tool":"web.search","args":{"query":"first"}}```',
          1 => '{"tool":"web.search","args":{"query":',
          2 =>
            '```agent_tool {"tool":"web.search","args":{"query":"second"}}```',
          _ => 'final answer',
        };
        return Stream.value(
            ChatStreamEvent(type: ChatStreamEventType.done, content: content));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();
    expect(calls, 4);
    expect(service.searchCalls, 1);
    expect(events.last.content, 'final answer');
  });

  test('a malformed standalone tool JSON gets only one format correction',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': 'Search the official Flutter repository.'}
      ],
      generate: (messages) {
        switch (calls++) {
          case 0:
            return Stream.value(const ChatStreamEvent(
              type: ChatStreamEventType.done,
              content: '{"tool":"web.search","args":{"query":',
            ));
          case 1:
            expect(messages[messages.length - 2]['role'], 'assistant');
            expect(messages[messages.length - 2]['content'],
                '{"tool":"web.search","args":{"query":');
            expect(messages.last['content'], contains('未执行'));
            return Stream.value(const ChatStreamEvent(
              type: ChatStreamEventType.done,
              content:
                  '```agent_tool {"tool":"web.search","args":{"query":"Flutter official repository"}} ```',
            ));
          default:
            return Stream.value(const ChatStreamEvent(
              type: ChatStreamEventType.done,
              content: 'The corrected request returned a result.',
            ));
        }
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(calls, 3, reason: 'one repair, one tool call, then final answer');
    expect(service.searchCalls, 1);
    expect(events.last.content, 'The corrected request returned a result.');
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, isNot(contains('"tool"')));
    expect(visible, isNot(contains('```')));
  });

  test('a preamble before the fence stays visible while the fence executes',
      () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    var calls = 0;
    const reply = '好嘞，我先搜搜。\n\n'
        '```json\n'
        '{"tool":"web.search","args":{"query":"github high star frontend"},"reason":"查仓库"}\n'
        '```';
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable([
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: calls++ == 0 ? reply : '确认了两点。'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No downloads expected')).toList();

    final visible = events.map((event) => event.delta ?? '').join();
    expect(calls, 2);
    expect(visible, contains('好嘞，我先搜搜。'));
    expect(visible, isNot(contains('"tool"')));
    expect(visible, isNot(contains('```')));
    expect(events.last.content, '确认了两点。');
  });

  test('duplicate recovery preserves the final answer turn at the limit',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    const first =
        '```agent_tool {"tool":"web.search","args":{"query":"first"}}```';
    const second =
        '```agent_tool {"tool":"web.search","args":{"query":"second"}}```';
    final events = await networkReplyStream(
      messages: [],
      maxToolCalls: 1,
      generate: (_) {
        final content =
            switch (calls++) { 0 || 1 => first, 2 => second, _ => 'answer' };
        return Stream.value(
            ChatStreamEvent(type: ChatStreamEventType.done, content: content));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download'),
    ).toList();
    expect(service.searchCalls, 1);
    expect(calls, 4);
    expect(events.last.content, 'answer');
  });

  test('a repeated request gets one final-answer recovery before hard stop',
      () async {
    var calls = 0;
    final service = FailedSearchService(StateError('SOURCE_HTTP_ERROR'));
    addTearDown(service.worker.close);
    const fence = '```agent_tool '
        '{"tool":"web.search","args":{"query":"same query"},"reason":"查"}'
        ' ```';
    final events = await networkReplyStream(
        messages: [],
        generate: (_) {
          calls++;
          return Stream.fromIterable([
            const ChatStreamEvent(
                type: ChatStreamEventType.done, content: fence),
          ]);
        },
        service: service,
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    // Two identical requests are handed back once for recovery. The third
    // identical request is stopped without calling the search service again.
    expect(calls, 3);
    expect(service.searchCalls, 1);
    // 心跳是空 delta 的 token（用来重置正文停滞看门狗），断言只看向用户可见的事件。
    final meaningful = events
        .where((e) =>
            e.type != ChatStreamEventType.token || (e.delta ?? '').isNotEmpty)
        .toList();
    expect(meaningful.single.type, ChatStreamEventType.error);
    expect(meaningful.single.message, contains('重复请求'));
  });

  test('a repeated successful search can use its first result for an answer',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    final seenFinalContext = <String>[];
    const fence = '```agent_tool '
        '{"tool":"web.search","args":{"query":"same query"},"reason":"search"}'
        ' ```';
    final events = await networkReplyStream(
      messages: const [
        {
          'role': 'user',
          'content': 'Find and use public Flutter documentation.'
        }
      ],
      generate: (messages) {
        switch (calls++) {
          case 0:
            return Stream.value(const ChatStreamEvent(
                type: ChatStreamEventType.done, content: fence));
          case 1:
            expect(
                messages
                    .map((message) => message['content']?.toString() ?? '')
                    .join('\n'),
                contains('Flutter release archive'));
            return Stream.value(const ChatStreamEvent(
                type: ChatStreamEventType.done, content: fence));
          default:
            seenFinalContext.addAll(messages
                .map((message) => message['content']?.toString() ?? ''));
            return Stream.value(const ChatStreamEvent(
              type: ChatStreamEventType.done,
              content: 'The search returned the Flutter release archive.',
            ));
        }
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download expected'),
    ).toList();

    expect(service.searchCalls, 1);
    expect(calls, 3);
    expect(seenFinalContext.join('\n'), contains('不同且更具体的查询'));
    expect(events.last.content, contains('Flutter release archive'));
    expect(events.where((event) => event.type == ChatStreamEventType.error),
        isEmpty);
    final receipts = service.evidenceSnapshot()['toolReceipts'] as List;
    expect(receipts, hasLength(2));
    expect(receipts.first, containsPair('tool', 'web.search'));
    expect(receipts.first, containsPair('status', 'success'));
    expect(receipts.last, containsPair('status', 'duplicate_skipped'));
  });

  test('a real code block still renders as text', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: '示例：\n```dart\nvoid main() {}\n```\n就这样。'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, contains('void main() {}'));
    expect(visible, contains('就这样。'));
  });

  test('unlabeled code beginning with tool remains visible', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    const sample = '```\ntool = createTool();\n```';
    final events = await networkReplyStream(
      messages: [],
      generate: (_) => Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.done, content: sample)),
      service: DesktopWebService(worker),
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download'),
    ).toList();
    expect(events.last.content, sample);
    expect(events.map((event) => event.delta ?? '').join(), sample);
  });

  test('a reply made only of a code block is not a protocol failure', () async {
    // 回归：纯 ```dart 代码块（前后没有任何正文）曾因为"以围栏开头"被判成
    // "只含协议噪音"，整段被替换成 networkReplyFormatError —— 用户看到代码块
    // 凭空消失，只剩一句联网格式错误。判据必须看块内容的分类，不看开头字符。
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: '```dart\nvoid main() {\n  print(1);\n}\n```'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    expect(events.where((event) => event.type == ChatStreamEventType.error),
        isEmpty);
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, contains('print(1);'));
    expect(visible, isNot(contains(networkReplyFormatError)));
  });

  test('protocol label variants are parsed consistently in streaming',
      () async {
    final service = SuccessfulSearchService();
    addTearDown(service.worker.close);
    var calls = 0;
    final events = await networkReplyStream(
      messages: [],
      generate: (_) => Stream.value(ChatStreamEvent(
        type: ChatStreamEventType.done,
        content: calls++ == 0
            ? '```tool_calls\n{"tool":"web.search","args":{"query":"x"}}\n```'
            : 'answer',
      )),
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('No download'),
    ).toList();
    expect(service.searchCalls, 1);
    expect(events.last.content, 'answer');
    expect(events.map((event) => event.delta ?? '').join(),
        isNot(contains('web.search')));
  });

  test('a drifting tool name in a ```json fence is still executed', () async {
    // 现场原文：```json {"tool":"web_search","query":"…"}```
    // 工具名写成下划线、参数也没包 args —— 旧逻辑解析失败后把整段 JSON
    // 当代码块贴到聊天里。
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    var calls = 0;
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable([
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: calls++ == 0
                      ? '```json\n'
                          '{"tool":"web_search","query":"github high star frontend UI skill repository awesome"}\n'
                          '```'
                      : '搜索完成。'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No downloads expected')).toList();

    expect(calls, 2, reason: '应识别为联网请求并继续下一轮，而不是当正文');
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, isNot(contains('web_search')));
    expect(visible, isNot(contains('"query"')));
    expect(events.last.content, '搜索完成。');
  });

  test('a ```function_call fence is executed instead of printed', () async {
    // 判据统一前：提交层清洗认 `function_call` 是工具调用、会隐藏，流式扫描器
    // 不认，于是同一段内容在流式通道里被当代码块贴进聊天。
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    var calls = 0;
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable([
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: calls++ == 0
                      ? '```function_call\n'
                          '{"name":"web_search","arguments":{"query":"flutter macos"}}\n'
                          '```'
                      : '搜索完成。'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No downloads expected')).toList();

    expect(calls, 2, reason: 'OpenAI 形态的 function_call 也应识别为联网请求');
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, isNot(contains('web_search')));
    expect(visible, isNot(contains('flutter macos')));
    expect(events.last.content, '搜索完成。');
  });

  test('an unusable tool fence is reported, never printed', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: '```json\n{"tool":"web_search"}\n```'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.sanitized, isTrue);
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, isEmpty, reason: '缺 query 的请求不能当正文显示');
  });

  test('a readable answer survives a trailing broken fence', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content:
                      '结论：可以。\n```json\n{"tool":"nope.tool","args":{}}\n```',
                  promptTokens: 5,
                  completionTokens: 2),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, contains('结论：可以。'), reason: '正文不能被协议垃圾连坐');
    expect(visible, isNot(contains('nope.tool')));
    expect(events.last.type, ChatStreamEventType.done);
    // done.content 会被 StreamingReplySession 覆盖正文，不能带着围栏回去。
    expect(events.last.content, isNot(contains('nope.tool')));
  });

  test('a fence cut off mid-stream never reaches the bubble', () async {
    // 用户点停止 / 超时：done 里只有半截围栏，不能当正文吐出去。
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content:
                      '好的，我查一下\n```json\n{"tool":"web_search","query":"ab'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, contains('好的，我查一下'));
    expect(visible, isNot(contains('web_search')));
    expect(visible, isNot(contains('```')));
    expect(events.last.content, isNot(contains('web_search')));
  });

  test('a ```json data sample without a tool key stays visible', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final events = await networkReplyStream(
        messages: [],
        generate: (_) => Stream.fromIterable(const [
              ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content: '配置示例：\n```json\n{"name":"demo","port":8080}\n```'),
            ]),
        service: DesktopWebService(worker),
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('No download')).toList();

    expect(events.last.type, ChatStreamEventType.done);
    final visible = events.map((event) => event.delta ?? '').join();
    expect(visible, contains('"port":8080'));
  });
}
