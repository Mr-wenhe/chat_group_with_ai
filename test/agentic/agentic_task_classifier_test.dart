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
    expect(
      AgenticTaskClassifier.requiresAgenticWork('那你帮我实现一个 流星雨的特效给我 使用html'),
      isTrue,
    );
    expect(AgenticTaskClassifier.requiresAgenticWork('帮我写一个检查项目的脚本'), isTrue);
  });

  test('detects browser context requests as agentic', () {
    expect(AgenticTaskClassifier.requiresAgenticWork('帮我看当前浏览器页面'), isTrue);
    expect(AgenticTaskClassifier.requiresAgenticWork('总结我选中的网页内容'), isTrue);
  });

  test('keeps ordinary chat non-agentic', () {
    expect(AgenticTaskClassifier.requiresAgenticWork('今天心情一般，陪我聊聊'), isFalse);
  });

  test('detects page/site generation requests as agentic (泛生成类关键词)', () {
    // 写作泛词 + 页面类
    expect(
      AgenticTaskClassifier.requiresAgenticWork('帮我写一个个人主页'),
      isTrue,
    );
    // 生成 + 页面
    expect(
      AgenticTaskClassifier.requiresAgenticWork('生成一个HTML页面'),
      isTrue,
    );
    // 做 + 网站
    expect(
      AgenticTaskClassifier.requiresAgenticWork('帮我做个网站'),
      isTrue,
    );
    // 做一个 + app
    expect(
      AgenticTaskClassifier.requiresAgenticWork('做一个计算器app'),
      isTrue,
    );
    // 生成 + 网站
    expect(
      AgenticTaskClassifier.requiresAgenticWork('生成一个网站'),
      isTrue,
    );
    // 小程序（命中「程序」）
    expect(
      AgenticTaskClassifier.requiresAgenticWork('做个小程序'),
      isTrue,
    );
    // 帮我做 + 落地页
    expect(
      AgenticTaskClassifier.requiresAgenticWork('帮我做一个产品落地页'),
      isTrue,
    );
  });

  test('用户原消息（欣欣个人主页）命中 agentic', () {
    // 私聊原始诉求：「你帮我写一个 欣欣的个人主页」——必须命中 agentic，
    // 否则会走普通 LLM 聊天路径，把规划文本当聊天消息贴出、工具不执行。
    expect(
      AgenticTaskClassifier.requiresAgenticWork('你帮我写一个 欣欣的个人主页'),
      isTrue,
    );
  });

  test('does not over-match ordinary chat after keyword expansion', () {
    // 扩充后仍需保证普通闲聊不会被误判为 agentic 任务。
    expect(
      AgenticTaskClassifier.requiresAgenticWork('今天天气怎么样'),
      isFalse,
    );
    expect(
      AgenticTaskClassifier.requiresAgenticWork('你吃饭了吗，最近在忙什么'),
      isFalse,
    );
    expect(
      AgenticTaskClassifier.requiresAgenticWork('哈哈这个笑话真好笑'),
      isFalse,
    );
    expect(
      AgenticTaskClassifier.requiresAgenticWork('这个页面真好看，你觉得呢'),
      isFalse,
    );
    expect(
      AgenticTaskClassifier.requiresAgenticWork('你平时喜欢用哪个 app'),
      isFalse,
    );
    expect(
      AgenticTaskClassifier.requiresAgenticWork('程序员的工作是不是很辛苦'),
      isFalse,
    );
    expect(
      AgenticTaskClassifier.requiresAgenticWork('这个文件是什么内容'),
      isFalse,
    );
  });
}
