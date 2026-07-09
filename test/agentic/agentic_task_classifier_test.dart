import 'package:chat_group/features/agentic/agentic_task_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects coding work as agentic', () {
    expect(
      AgenticTaskClassifier.requiresAgenticWork('帮我修改 lib/main.dart'),
      isTrue,
    );
    expect(AgenticTaskClassifier.requiresAgenticWork('review 这段代码'), isTrue);
    expect(AgenticTaskClassifier.requiresAgenticWork('修复这个 bug'), isTrue);
  });

  test('detects browser context requests as agentic', () {
    expect(AgenticTaskClassifier.requiresAgenticWork('帮我看当前浏览器页面'), isTrue);
    expect(AgenticTaskClassifier.requiresAgenticWork('总结我选中的网页内容'), isTrue);
  });

  test('keeps ordinary chat non-agentic', () {
    expect(AgenticTaskClassifier.requiresAgenticWork('今天心情一般，陪我聊聊'), isFalse);
  });
}
