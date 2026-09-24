import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:flutter_test/flutter_test.dart';

/// [agent_progress_meta] 存活导出（进度前缀常量与耗时格式化）的单元测试。
///
/// 该文件剩余的导出全部服务于 `ProgressLogBubble`——它按行前缀匹配解析
/// 历史 `agent-progress:` 消息，因此前缀常量与耗时格式属于渲染契约。
void main() {
  group('formatElapsed formats total elapsed', () {
    test('under 60s → "Ns"', () {
      expect(formatElapsed(0), '0s');
      expect(formatElapsed(1), '1s');
      expect(formatElapsed(42), '42s');
      expect(formatElapsed(59), '59s');
    });

    test('exactly 60s → "1分00秒" (seconds zero-padded)', () {
      expect(formatElapsed(60), '1分00秒');
    });

    test('over 60s → "Nm分ss秒" with zero-padded seconds', () {
      expect(formatElapsed(65), '1分05秒');
      expect(formatElapsed(125), '2分05秒');
      expect(formatElapsed(600), '10分00秒');
      expect(formatElapsed(3599), '59分59秒');
    });
  });
}
