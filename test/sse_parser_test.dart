import 'dart:async';

import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/streaming/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SseParser', () {
    test('有界 SSE 行转换器拒绝无换行超长帧', () async {
      final source = Stream<List<int>>.value(List<int>.filled(65, 0x61));

      await expectLater(
        const BoundedSseLineTransformer(maxLineBytes: 64, maxWireBytes: 1024)
            .bind(source)
            .toList(),
        throwsA(isA<SseInputLimitException>()),
      );
    });

    test('有界 SSE 行转换器拒绝累计线缆字节超过上限', () async {
      final source = Stream<List<int>>.fromIterable([
        List<int>.filled(40, 0x61),
        List<int>.filled(40, 0x62),
      ]);

      await expectLater(
        const BoundedSseLineTransformer(maxLineBytes: 1024, maxWireBytes: 64)
            .bind(source)
            .toList(),
        throwsA(isA<SseInputLimitException>()),
      );
    });

    test('有界 SSE 行转换器支持 LF、CRLF 和跨块 CR 换行', () async {
      final source = Stream<List<int>>.fromIterable([
        'first\r\nsecond\r'.codeUnits,
        '\nthird\rfourth'.codeUnits,
      ]);

      final lines = await const BoundedSseLineTransformer(
        maxLineBytes: 1024,
        maxWireBytes: 1024,
      ).bind(source).toList();

      expect(lines.map(String.fromCharCodes),
          ['first', 'second', 'third', 'fourth']);
    });

    test('解析完整 data 行，产出 token 并累计内容', () {
      final p = SseParser();
      final events =
          p.ingest('data: {"choices":[{"delta":{"content":"你好"}}]}\n');
      expect(events, hasLength(1));
      expect(events.first.type, ChatStreamEventType.token);
      expect(events.first.delta, '你好');
      expect(p.doneEvent().content, '你好');
    });

    test('多行一次喂入，按序产出多个 token', () {
      final p = SseParser();
      const chunk = 'data: {"choices":[{"delta":{"content":"A"}}]}\n'
          'data: {"choices":[{"delta":{"content":"B"}}]}\n';
      final events = p.ingest(chunk);
      expect(events.map((e) => e.delta), ['A', 'B']);
      expect(p.doneEvent().content, 'AB');
    });

    test('跨 chunk 的不完整行被正确拼接（JSON 被切断）', () {
      final p = SseParser();
      // JSON 被拆成两半，跨网络边界
      p.ingest('data: {"choices":[{"delta":{"content":"Hel');
      p.ingest('lo"}}]}\n');
      expect(p.doneEvent().content, 'Hello');
    });

    test('data: [DONE] 被忽略，不产出事件', () {
      final p = SseParser();
      final events = p.ingest('data: [DONE]\n');
      expect(events, isEmpty);
    });

    test('LineSplitter 输出的无换行 data 行可直接解析', () {
      final p = SseParser();
      final event =
          p.ingestLine('data: {"choices":[{"delta":{"content":"真实回复"}}]}');
      expect(event, isNotNull);
      expect(event!.type, ChatStreamEventType.token);
      expect(event.delta, '真实回复');
      expect(p.doneEvent().content, '真实回复');
    });

    test('注释行 / 空行 / 非 data 行被忽略，只保留有效 token', () {
      final p = SseParser();
      const chunk = ': keep-alive\n\n'
          'event: message\n'
          'data: {"choices":[{"delta":{"content":"X"}}]}\n';
      final events = p.ingest(chunk);
      expect(events.map((e) => e.delta), ['X']);
    });

    test('空增量内容（仅 role）被忽略，不计为错误', () {
      final p = SseParser();
      const chunk = 'data: {"choices":[{"delta":{"role":"assistant"}}]}\n';
      final events = p.ingest(chunk);
      expect(events, isEmpty);
    });

    test('标准 content 为空时使用 reasoning_content，标准 content 优先', () {
      final reasoningOnly = SseParser();
      expect(
        reasoningOnly.ingest(
          'data: {"choices":[{"delta":{"reasoning_content":"兼容结果"}}]}\n',
        ),
        isEmpty,
      );
      expect(reasoningOnly.doneEvent().content, '兼容结果');

      final mixed = SseParser();
      mixed.ingest(
        'data: {"choices":[{"delta":{"reasoning_content":"内部片段"}}]}\n',
      );
      mixed.ingest(
        'data: {"choices":[{"delta":{"content":"标准结果"}}]}\n',
      );
      expect(mixed.doneEvent().content, '标准结果');
    });

    test('非法 JSON 的 data 行产出 error 事件且已解析内容保留', () {
      final p = SseParser();
      p.ingest('data: {"choices":[{"delta":{"content":"OK"}}]}\n');
      final bad = p.ingest('data: not-a-json\n');
      expect(bad, hasLength(1));
      expect(bad.first.type, ChatStreamEventType.error);
      expect(p.doneEvent().content, 'OK');
    });

    test('非法 SSE 不会把原始正文写入日志', () {
      const secretMarker = 'runtime-security-secret-marker';
      final logs = <String>[];

      runZoned(
        () => SseParser().ingest('data: $secretMarker\n'),
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, message) => logs.add(message),
        ),
      );

      expect(logs.join('\n'), isNot(contains(secretMarker)));
    });

    test('reset 清空缓冲与累计内容', () {
      final p = SseParser();
      p.ingest('data: {"choices":[{"delta":{"content":"A"}}]}\n');
      p.reset();
      expect(p.doneEvent().content, '');
      expect(
        p.ingest('data: {"choices":[{"delta":{"content":"B"}}]}\n').first.delta,
        'B',
      );
    });

    test('CRLF(\\r\\n) 换行被正确解析，残留 \\r 被剔除', () {
      final p = SseParser();
      final events =
          p.ingest('data: {"choices":[{"delta":{"content":"Hi"}}]}\r\n');
      expect(events.map((e) => e.delta), ['Hi']);
      expect(p.doneEvent().content, 'Hi');
    });

    test('跨 3 个 chunk 的 JSON 被切断也能正确拼接', () {
      final p = SseParser();
      // JSON 被网络切成三段，跨越多个 chunk 边界
      p.ingest('data: {"cho');
      p.ingest('ices":[{"delta":{"con');
      p.ingest('tent":"Yo"}}]}\n');
      expect(p.doneEvent().content, 'Yo');
    });

    test('多 chunk 含 [DONE] 与注释行后仍能产出自完整内容', () {
      final p = SseParser();
      p.ingest(': keep-alive\n\n');
      p.ingest('data: {"choices":[{"delta":{"content":"Hel');
      p.ingest('lo"}}]}\n');
      p.ingest('data: [DONE]\n');
      expect(p.doneEvent().content, 'Hello');
    });

    test('finish_reason=error 且空 delta 产出 error 事件', () {
      final p = SseParser();
      final events = p.ingest(
          'data: {"choices":[{"delta":{},"finish_reason":"error","error":{"message":"content filter"}}]}\n');
      expect(events, hasLength(1));
      expect(events.first.type, ChatStreamEventType.error);
      expect(events.first.message, contains('content filter'));
    });

    test('provider error JSON (error + null choices) 产出 error 事件', () {
      final p = SseParser();
      final events =
          p.ingest('data: {"error":{"message":"Invalid API key"}}\n');
      expect(events, hasLength(1));
      expect(events.first.type, ChatStreamEventType.error);
      expect(events.first.message, contains('Invalid API key'));
    });

    test('usage 中的 cached token 会进入 done 事件', () {
      final p = SseParser();
      p.ingest(
          'data: {"choices":[{"delta":{"content":"OK"}}],"usage":{"prompt_tokens":100,"completion_tokens":12,"prompt_tokens_details":{"cached_tokens":40}}}\n');

      final done = p.doneEvent();
      expect(done.promptTokens, 100);
      expect(done.completionTokens, 12);
      expect(done.cachedTokens, 40);
    });

    test('解析器终止后 [DONE] 不产生 done 事件', () {
      // 模拟：解析器先遇到 provider error 终止，然后服务端仍发送 [DONE]
      final p = SseParser();
      final events =
          p.ingest('data: {"error":{"message":"rate limit"}}\ndata: [DONE]\n');
      // error 事件已产出
      expect(events, hasLength(1));
      expect(events.first.type, ChatStreamEventType.error);
      // 解析器已终止
      expect(p.terminated, isTrue);
    });
  });
}
