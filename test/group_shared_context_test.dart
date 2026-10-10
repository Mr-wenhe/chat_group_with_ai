import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/chat_group/group_shared_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String build({
    String name = '夜谈会',
    String description = '',
    String announcement = '',
  }) =>
      GroupSharedContext.build(
        groupName: name,
        description: description,
        announcement: announcement,
      );

  group('build', () {
    test('两个字段都为空时整块不注入', () {
      expect(build(), isEmpty);
      expect(build(description: '   ', announcement: '\n'), isEmpty);
    });

    test('共同背景与群公告分别成行，并带上区块头', () {
      final block = build(
        description: '大家都叫群主“老大”；小林是阿宽的姐姐',
        announcement: '工作日 20:00 后聊轻松话题',
      );

      expect(block, startsWith(GroupSharedContext.marker));
      expect(block, contains('共同背景：大家都叫群主“老大”；小林是阿宽的姐姐'));
      expect(block, contains('群公告与约定：工作日 20:00 后聊轻松话题'));
    });

    test('只填一项时另一项不留空行', () {
      final block = build(description: '只有共同背景');

      expect(block, contains('共同背景：只有共同背景'));
      expect(block, isNot(contains('群公告与约定')));
    });

    test('写明与旧摘要冲突时以上述设定为准', () {
      final block = build(description: '甲是乙的姐姐');

      expect(block, contains('如果群聊摘要或聊天历史里出现过与之冲突的说法'));
      expect(block, contains('以此为准'));
    });

    test('写明动态状态不受设定改写、且设定不构成任何授权', () {
      final block = build(description: '甲是乙的姐姐');

      expect(block, contains('动态状态'));
      expect(block, contains('不构成'));
      expect(block, contains('授权'));
    });

    test('群名为空时用中性称呼，不产生“「」”空洞', () {
      final block = build(name: '  ', description: '有一点背景');

      expect(block, contains('本群'));
      expect(block, isNot(contains('「」')));
    });
  });

  group('survives', () {
    test('空区块视为始终成立', () {
      expect(GroupSharedContext.survives(const [], ''), isTrue);
    });

    test('区块被窗口裁剪后判定为未保留', () {
      final block = build(
        description: '甲是乙的姐姐',
        announcement: '工作日 20:00 后聊轻松话题',
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': block},
        {'role': 'user', 'content': '很长的一段用户输入' * 200},
      ];

      // 预算充足：区块原样保留。
      expect(
        GroupSharedContext.survives(
          ContextWindowManager.fitToTokenBudget(messages, maxTokens: 4000),
          block,
        ),
        isTrue,
      );

      // 预算极小：中间消息里虽然有区块，最终请求里已经没有了。
      expect(
        GroupSharedContext.survives(
          ContextWindowManager.fitToTokenBudget(messages, maxTokens: 8),
          block,
        ),
        isFalse,
      );
    });
  });

  group('carriesBlock', () {
    test('按区块头识别承载设定的那条消息', () {
      final block = build(description: '甲是乙的姐姐');
      expect(
        GroupSharedContext.carriesBlock({'role': 'system', 'content': block}),
        isTrue,
      );
      expect(
        GroupSharedContext.carriesBlock(
          {'role': 'system', 'content': '普通系统提示'},
        ),
        isFalse,
      );
      // 多模态 content 不是字符串：不按承载区块处理，避免误判成必需。
      expect(
        GroupSharedContext.carriesBlock({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
        }),
        isFalse,
      );
    });
  });

  group('窗口裁剪优先级', () {
    test('必需区块把可选摘要挤走，而不是自己被裁短', () {
      final block = build(
        name: '测试群',
        description: '甲是乙的姐姐',
        announcement: '不要使用粗口',
      );
      final required = <Map<String, dynamic>>[
        {'role': 'system', 'content': block},
        {'role': 'system', 'content': '你是甲，群友'},
        {'role': 'user', 'content': '晚饭吃什么'},
      ];
      final withOptional = <Map<String, dynamic>>[
        ...required.take(2),
        {'role': 'system', 'content': '可选旧摘要' * 500},
        {'role': 'system', 'content': '可选其他群员说明' * 400},
        required.last,
      ];
      // 预算刚好装得下必需内容 + 一点余量：可选摘要必须让位。
      final budget = ContextWindowManager.estimateRequestTokens(required) + 60;
      expect(
        ContextWindowManager.estimateRequestTokens(required),
        lessThan(budget),
      );

      final actual = ContextWindowManager.fitToTokenBudget(
        withOptional,
        maxTokens: budget,
        isProtected: GroupSharedContext.carriesBlock,
      );
      expect(
        GroupSharedContext.survives(actual, block),
        isTrue,
        reason: '必需背景本可放入预算，却因可选摘要未让位而被裁掉',
      );

      // 反证：同一份装配如果不标记必需区块，设定本身就会被裁短——这正是
      // "按体积裁最长的 system 文本"在没有优先级时必然发生的事。
      final unguarded = ContextWindowManager.fitToTokenBudget(
        withOptional,
        maxTokens: budget,
      );
      expect(GroupSharedContext.survives(unguarded, block), isFalse);
    });

    test('受保护区块真的装不下时才让位（此时 survives 判失败）', () {
      final block = build(description: '甲是乙的姐姐' * 200);
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': block},
        {'role': 'user', 'content': '晚饭吃什么'},
      ];

      final actual = ContextWindowManager.fitToTokenBudget(
        messages,
        maxTokens: 50,
        isProtected: GroupSharedContext.carriesBlock,
      );
      expect(
        GroupSharedContext.survives(actual, block),
        isFalse,
        reason: '连必需区块都装不下时必须如实判失败，交给调用方明确报错',
      );
    });

    test('什么都没标记为必需时，结果与不传 isProtected 完全一致', () {
      final block = GroupSharedContext.build(
        groupName: '本群',
        description: '甲' * 4000,
        announcement: '',
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': block},
        {'role': 'system', 'content': '乙' * 2000},
        {'role': 'user', 'content': '晚饭吃什么'},
      ];

      final unguarded = ContextWindowManager.fitToTokenBudget(
        messages,
        maxTokens: 300,
      );
      final nothingProtected = ContextWindowManager.fitToTokenBudget(
        messages,
        maxTokens: 300,
        isProtected: (_) => false,
      );
      // 默认调用路径的行为必须逐字不变：这个参数只新增"谁先让位"的排序。
      expect(nothingProtected, unguarded);
      // 未受保护时按体积裁掉的正是最长的 system 文本，包括设定本身。
      expect(GroupSharedContext.survives(unguarded, block), isFalse);
    });
  });
}
