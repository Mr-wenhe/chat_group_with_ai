import 'package:chat_group/features/autonomous/autonomous_trigger_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AutonomousTriggerDetector', () {
    const detector = AutonomousTriggerDetector();

    test('keeps ordinary chat out of autonomous execution', () {
      final result = detector.detect(
        text: '今天晚上吃什么？',
        autonomyEnabled: true,
        sourceAuthorized: true,
      );

      expect(result.kind, AutonomousTriggerKind.none);
      expect(result.taskType, 'chat');
    });

    test('starts document work in conversation directory', () {
      final result = detector.detect(
        text: '帮我创建一份会议纪要 Markdown 文档',
        autonomyEnabled: true,
        sourceAuthorized: false,
      );

      expect(result.kind, AutonomousTriggerKind.startInConversationDir);
      expect(result.taskType, 'docs');
    });

    test('requires project authorization for code work', () {
      final result = detector.detect(
        text: '帮我写一个 C++ 文件检测系统 CPU 和内存',
        autonomyEnabled: true,
        sourceAuthorized: false,
      );

      expect(result.kind, AutonomousTriggerKind.needsProjectAuthorization);
      expect(result.taskType, 'code');
    });
  });
}
