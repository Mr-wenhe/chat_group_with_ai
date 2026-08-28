import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_policy.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _v1RequirementCoverage = <String, String>{
  'FR-01': '全局文件夹授权：后续 Stage 02 覆盖。',
  'FR-02': '文件读取与分析：后续 Stage 02/04 覆盖。',
  'FR-03': '文件变更：后续 Stage 02 覆盖。',
  'FR-04': '终端命令：后续 Stage 03 覆盖。',
  'FR-05': '调度、并发与冲突：后续 Stage 01/02 覆盖。',
  'FR-06': '上下文与持久化：后续 Stage 01/03 覆盖。',
  'FR-07': '搜索与浏览：后续 Stage 04 覆盖。',
  'FR-08': '设置：后续 Stage 02 覆盖。',
  'FR-09': '普通聊天隔离：本文件冻结基线。',
};

AICharacter _agenticCharacter() => AICharacter(
      id: 'baseline-agent',
      name: '基线角色',
      avatar: '基',
      age: 20,
      role: '测试角色',
      personalityTags: const ['测试'],
      systemPrompt: '你是一个用于工作模式基线测试的角色。',
      apiKey: 'test-key',
      apiProvider: 'custom',
      apiConfigId: 'test-config',
    );

void main() {
  test('tracks FR-01 through FR-09 before their implementation stages', () {
    expect(
      _v1RequirementCoverage.keys,
      containsAll(<String>[
        'FR-01',
        'FR-02',
        'FR-03',
        'FR-04',
        'FR-05',
        'FR-06',
        'FR-07',
        'FR-08',
        'FR-09',
      ]),
    );
    expect(_v1RequirementCoverage, hasLength(9));
  });

  test('ordinary chat does not route a user request into the tool runtime', () {
    expect(
      WorkModePolicy.shouldRun(
        enabled: false,
        character: _agenticCharacter(),
        userRequest: '请整理一下项目目录',
      ),
      isFalse,
    );
  });

  test('auto chat is paused while work mode is enabled', () {
    expect(
      ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: true,
        autoChatEnabled: true,
        hasCharacters: true,
        hasApiConfig: true,
      ),
      isFalse,
    );
  });

  test('auto chat resumes when work mode is disabled', () {
    expect(
      ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: false,
        autoChatEnabled: true,
        hasCharacters: true,
        hasApiConfig: true,
      ),
      isTrue,
    );
  });

  test('direct-chat policy keeps private conversation identity isolated', () {
    expect(DirectChatSession.isDirectConversationId('dm:character-a'), isTrue);
    expect(DirectChatSession.isDirectConversationId('group-a'), isFalse);

    final candidate = DirectChatProactivePolicy.selectCandidate(
      directSummaries: const [],
      groupCandidates: const [],
      idleCharacters: <AICharacter>[_agenticCharacter()],
      lastProactiveAtByCharacter: const {},
      now: DateTime.utc(2026, 8, 28),
    );
    expect(candidate?.source, DirectChatSource.direct);
    expect(candidate?.sourceGroupId, isNull);
  });
}
