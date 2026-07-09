import 'package:chat_group/core/models/ai_character.dart';

class AutonomousRoleAssignment {
  final AICharacter planner;
  final AICharacter executor;
  final AICharacter verifier;

  const AutonomousRoleAssignment({
    required this.planner,
    required this.executor,
    required this.verifier,
  });
}

class AutonomousRoleResolver {
  const AutonomousRoleResolver();

  AutonomousRoleAssignment resolve(List<AICharacter> characters) {
    if (characters.isEmpty) {
      throw ArgumentError('Autonomous tasks require at least one character.');
    }
    final active = characters.where((c) => c.isActive).toList();
    final pool = active.isEmpty ? characters : active;
    final planner = _firstByKeywords(pool, const [
          '产品',
          'pm',
          '需求',
          '策划',
          '经理',
          '分析',
        ]) ??
        pool.first;
    final executor = _firstByKeywords(pool, const [
          '开发',
          '工程师',
          '程序',
          '代码',
          'c++',
          'cpp',
          '系统',
          '文档',
          '设计',
        ]) ??
        pool.first;
    final verifier = _firstByKeywords(pool, const [
          '测试',
          'qa',
          '验收',
          '审查',
          'review',
        ]) ??
        executor;
    return AutonomousRoleAssignment(
      planner: planner,
      executor: executor,
      verifier: verifier,
    );
  }

  AICharacter? _firstByKeywords(
      List<AICharacter> characters, List<String> keys) {
    for (final character in characters) {
      final haystack = [
        character.name,
        character.role,
        character.systemPrompt,
        ...character.personalityTags,
      ].join(' ').toLowerCase();
      if (keys.any(haystack.contains)) return character;
    }
    return null;
  }
}
