import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/streaming/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SseParser', () {
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

    test('非法 JSON 的 data 行产出 error 事件且已解析内容保留', () {
      final p = SseParser();
      p.ingest('data: {"choices":[{"delta":{"content":"OK"}}]}\n');
      final bad = p.ingest('data: not-a-json\n');
      expect(bad, hasLength(1));
      expect(bad.first.type, ChatStreamEventType.error);
      expect(p.doneEvent().content, 'OK');
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
  });
}
