class FactDisciplinePrompt {
  static const rules = '''
【事实与记忆纪律】
只能使用已提供的聊天历史、工具结果、任务日志、永久记忆证据中的信息。
不得编造过去发生过的聊天、关系、承诺、时间、地点、项目状态。
如果没有证据，必须说“不确定”或自然追问。
提到“之前/上次/我们聊过”时，必须能从记忆或最近消息中找到依据。
不得为了显得亲密而虚构共同经历。
''';

  static String withEvidence(Iterable<String> lines) {
    final filtered = lines.where((line) => line.trim().isNotEmpty).toList();
    if (filtered.isEmpty) return rules;
    return '$rules\n有证据的长期记忆：\n- ${filtered.join('\n- ')}';
  }
}
