import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/media_attachment.dart';

class AgentPromptBuilder {
  static String buildToolPlanningPrompt({
    required String characterName,
    required List<CharacterSkill> skills,
    required String userRequest,
    List<MediaAttachment>? media,
  }) {
    final skillText = skills.map((s) {
      final steps = s.instructions.map((i) => '- $i').join('\n');
      return 'Skill: ${s.name}\n'
          'Domain: ${s.domain}\n'
          'Description: ${s.description}\n'
          'Steps:\n$steps';
    }).join('\n\n');

    return '''
你是$characterName。你不是只能聊天的人设，你有可复用技能，并且要像真实专家一样工作。

用户请求：
$userRequest${mediaHint(media)}

你的技能：
$skillText

当你需要工具时，只输出一个工具请求块：
```agent_tool
{"tool":"workspace.read","reason":"为什么需要这个工具","args":{"path":"lib/main.dart"}}
```

可用工具名：
- workspace.list
- workspace.read
- workspace.patch
- command.run
- browser.context
- skill.create
- skill.download

创建新文件时 workspace.patch 的 patch 示例：
```diff
diff --git a/docs/example.md b/docs/example.md
new file mode 100644
--- /dev/null
+++ b/docs/example.md
@@ -0,0 +1,2 @@
+# 标题
+正文
```

规则：
- 读文件、浏览器上下文、运行命令、写补丁之前说明原因。
- 当现有技能不够贴合角色职业时，用 skill.download 安装职业专家 skill；没有合适模板时再用 skill.create 创建。
- 如果用户要求生成文件、写 Markdown、改代码、读取路径或运行测试，不能只回复“正在做”或承诺稍后完成；必须输出工具请求，或明确说明缺少的权限、路径、bridge 服务或确认信息。
- 写入文件前必须等待用户批准。
- 如果信息不足且执行会有风险，先问一个具体问题。
- 完成后用自然角色口吻总结做了什么、证据是什么、还有什么风险。
''';
  }

  static String buildToolResultPrompt({
    required String characterName,
    required String userRequest,
    required String toolName,
    required Map<String, dynamic> toolResult,
  }) {
    return '''
你是$characterName。用户请求是：
$userRequest

工具 $toolName 返回：
$toolResult

如果还需要另一个工具才能真正完成用户请求，只输出一个新的 agent_tool 代码块。
如果已经完成，请用你的角色口吻给出最终答复，说明证据、已完成动作和剩余风险。
''';
  }

  static String mediaHint(List<MediaAttachment>? media) {
    if (media == null || media.isEmpty) return '';
    final parts = <String>[];
    final images = media.where((m) => m.type == 'image').length;
    final videos = media.where((m) => m.type == 'video').length;
    final files =
        media.where((m) => m.type != 'image' && m.type != 'video').toList();
    if (images > 0) parts.add('[$images 张图片]');
    if (videos > 0) parts.add('[$videos 段视频]');
    if (files.isNotEmpty) {
      final names = files.take(3).map((f) => f.fileName ?? '文件').join('、');
      parts.add('[${files.length} 个文件：$names]');
    }
    if (parts.isEmpty) return '';
    return '\n（用户发送了附件：${parts.join('，')}）';
  }
}
