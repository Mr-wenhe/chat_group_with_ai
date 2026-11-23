import 'dart:io';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/network_reply_context.dart';
import 'package:chat_group/features/web_search/desktop/network_reply_stream.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReadService extends DesktopWebService {
  _ReadService(this.body)
      : super(WebWorkerClient(executable: '/unused', entryPoint: '/unused')) {
    registerSource('https://example.com/first');
  }
  final String body;
  int reads = 0;
  final readSections = <int>[];
  @override
  Future<Map<String, dynamic>> read(String sourceId,
      {int startSection = 0, Future<void>? cancellation}) async {
    reads++;
    readSections.add(startSection);
    registerSource('https://example.com/discovered');
    return {'source_id': sourceId, 'text': body};
  }
}

void main() {
  test('quoted integer page indices read the requested sections', () async {
    final service = _ReadService('source text');
    var calls = 0;
    final events = await networkReplyStream(
      messages: [],
      generate: (_) => Stream.value(ChatStreamEvent(
        type: ChatStreamEventType.done,
        content: switch (calls++) {
          0 => '```agent_tool {"tool":"web.read","args":{"sourceId":"s1","startSection":"0"}} ```',
          1 => '```agent_tool {"tool":"web.read","args":{"sourceId":"s1","startSection":"2"}} ```',
          _ => '已读取。',
        },
      )),
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('不应下载'),
    ).toList();
    expect(service.readSections, [0, 2]);
    expect(events.last.content, '已读取。');
  });

  test('invalid page indices fail before another model request', () async {
    for (final index in ['-1', '1.5', 'true', '"bad"']) {
      final service = _ReadService('source text');
      var calls = 0;
      final events = await networkReplyStream(
        messages: [],
        generate: (_) {
          calls++;
          return Stream.value(ChatStreamEvent(
            type: ChatStreamEventType.done,
            content: '```agent_tool {"tool":"web.read","args":{"sourceId":"s1","startSection":$index}} ```',
          ));
        },
        service: service,
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('不应下载'),
      ).toList();
      expect(service.reads, 0);
      expect(calls, 1);
      expect(events.single.type, ChatStreamEventType.error);
    }
  });

  test('model retry keeps completed tool context and never replays the read',
      () async {
    final service = _ReadService('real evidence');
    var calls = 0;
    var retries = 0;
    final events = await networkReplyStream(
      messages: const [
        {'role': 'user', 'content': '读取来源'}
      ],
      generate: (_) => Stream.fromIterable(calls++ == 0
          ? [
              const ChatStreamEvent(
                  type: ChatStreamEventType.done,
                  content:
                      '```agent_tool {"tool":"web.read","args":{"sourceId":"s1"}} ```',
                  promptTokens: 10,
                  completionTokens: 3),
            ]
          : [
              const ChatStreamEvent(
                  type: ChatStreamEventType.token,
                  delta: '```agent_tool {"tool":"web.download'),
              const ChatStreamEvent(
                  type: ChatStreamEventType.error,
                  message: '网络连接失败',
                  promptTokens: 10,
                  completionTokens: 3),
            ]),
      retryGenerate: (messages) {
        retries++;
        expect(messages.map((message) => message['content']).join('\n'),
            contains('real evidence'));
        return Stream.value(const ChatStreamEvent(
            type: ChatStreamEventType.done,
            content: '已读完。',
            promptTokens: 10,
            completionTokens: 3));
      },
      service: service,
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('不应下载'),
      inputTokenBudget: 700,
    ).toList();
    expect(calls, 2);
    expect(retries, 1);
    expect(service.reads, 1);
    expect(events.last.content, '已读完。');
    expect(events.last.promptTokens, 30);
    expect(events.last.completionTokens, 9);
    expect(events.where((event) => event.type == ChatStreamEventType.error),
        isEmpty);
  });

  test('caller retry policy prevents a second request after governance denial',
      () async {
    final events = await networkReplyStream(
      messages: const [],
      generate: (_) => Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.error, message: 'governance denied')),
      retryGenerate: (_) => throw StateError('不应重试'),
      shouldRetry: (_) => false,
      service: _ReadService(''),
      downloadDirectory: () async => Directory('/unused'),
      isActive: () => true,
      onDownload: (_) => fail('不应下载'),
    ).toList();
    expect(events.single.message, 'governance denied');
  });
  test('a second model failure ends the retry without another tool call', () async {
    var requests = 0;
    Stream<ChatStreamEvent> failed(List<Map<String, dynamic>> _) {
      requests++;
      return Stream.value(const ChatStreamEvent(
          type: ChatStreamEventType.error, message: '网络连接失败'));
    }
    final service = _ReadService('');
    final events = await networkReplyStream(
      messages: const [], generate: failed, retryGenerate: failed,
      service: service, downloadDirectory: () async => Directory('/unused'),
      isActive: () => true, onDownload: (_) => fail('不应下载'),
    ).toList();
    expect(requests, 2);
    expect(service.reads, 0);
    expect(events.single.type, ChatStreamEventType.error);
  });

  for (final large in [false, true]) {
    test('each continuation fits and refreshes sources; large=$large',
        () async {
      final service = _ReadService(large ? '正文' * 6000 : '公开正文');
      var calls = 0;
      final requests = <List<Map<String, dynamic>>>[];
      final events = await networkReplyStream(
        messages: const [
          {'role': 'user', 'content': '读取提供的来源'}
        ],
        generate: (messages) {
          requests.add(messages);
          return Stream.value(ChatStreamEvent(
            type: ChatStreamEventType.done,
            content: calls++ == 0
                ? '```agent_tool {"tool":"web.read","args":{"sourceId":"s1"}} ```'
                : '已读取来源。',
          ));
        },
        service: service,
        downloadDirectory: () async => Directory('/unused'),
        isActive: () => true,
        onDownload: (_) => fail('不应下载'),
        inputTokenBudget: 700,
      ).toList();
      final visibleEvents = events
          .where((event) =>
              event.type != ChatStreamEventType.token ||
              (event.delta?.isNotEmpty ?? false))
          .toList();
      expect(calls, large ? 1 : 2);
      expect(
          requests.every((messages) =>
              ContextWindowManager.estimateRequestTokens(messages) <= 700),
          isTrue);
      if (large) {
        expect(visibleEvents, hasLength(1));
        expect(visibleEvents.single.type, ChatStreamEventType.error);
        expect(visibleEvents.single.message, contains('放不进模型窗口'));
      } else {
        expect(visibleEvents.last.content, '已读取来源。');
        expect(requests.last.last['content'],
            contains('"s2":"https://example.com/discovered"'));
      }
    });
  }
  test(
      'optional history yields while identity, user input and evidence survive',
      () {
    final required = [
      {'role': 'system', 'content': '角色身份与共同设定'},
      {'role': 'user', 'content': '本轮原始要求'},
      {'role': 'assistant', 'content': '真实工具请求'},
      {'role': 'user', 'content': '真实正文与来源编号'},
    ];
    final result = fitNetworkReplyContext([
      required.first,
      {'role': 'user', 'content': '过时历史' * 1000},
      ...required.skip(1),
    ], requiredMessages: required, inputTokenBudget: 100);
    expect(result, isNotNull);
    expect(result, containsAll(required));
    expect(ContextWindowManager.estimateRequestTokens(result!),
        lessThanOrEqualTo(100));
  });

  test('oversized required evidence fails instead of silently clipping it', () {
    final required = [
      {'role': 'system', 'content': '必须保留的角色设定'},
      {'role': 'user', 'content': '必须完整保留的正文' * 1000},
    ];
    expect(
        fitNetworkReplyContext(required,
            requiredMessages: required, inputTokenBudget: 100),
        isNull);
  });
}
