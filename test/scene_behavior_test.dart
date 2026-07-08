import 'package:chat_group/features/chat_group/scene_behavior.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SceneBehavior', () {
    test('resolves known scene themes', () {
      expect(SceneBehavior.resolve('相亲群').kind, SceneKind.dating);
      expect(SceneBehavior.resolve('产品辩论').kind, SceneKind.debate);
      expect(SceneBehavior.resolve('吐槽大会').kind, SceneKind.roast);
      expect(SceneBehavior.resolve('周会 meeting').kind, SceneKind.meeting);
      expect(SceneBehavior.resolve('职场办公').kind, SceneKind.workplace);
      expect(SceneBehavior.resolve('随便聊聊').kind, SceneKind.general);
    });

    test('meeting behavior provides concrete human interaction rules', () {
      final behavior = SceneBehavior.resolve('项目会议');
      final lines = behavior.intentInstructions('小林', true).join('\n');
      final room = behavior.roomContextPrompt('小林，27岁，程序员');

      expect(behavior.activelyTargetsMembers, isTrue);
      expect(behavior.targetReason, 'meeting-handoff');
      expect(lines, contains('优先接 小林 的话'));
      expect(lines, contains('风险、问题、依赖或下一步'));
      expect(room, contains('不要所有人都说'));
    });
  });
}
