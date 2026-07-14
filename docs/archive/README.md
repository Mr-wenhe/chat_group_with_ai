# 项目对话与工作流归档

本目录记录 2026-07-14 对项目开发数据、对话质量和可复用工作方式的整理结果。

## 内容索引

- [`conversations/README.md`](conversations/README.md)：全量对话索引。
- [`conversations/archive.json`](conversations/archive.json)：结构化脱敏归档。
- [`conversation_review.md`](conversation_review.md)：重复问题、做得不好的地方和改进优先级。
- [`reusable_workflows.md`](reusable_workflows.md)：可复用工作流。
- [`reusable_skills.md`](reusable_skills.md)：可复用 Skill 清单。
- [`skills/chat-group-archive-and-review.zip`](skills/chat-group-archive-and-review.zip)：已通过校验的可分发 Skill 包。
- [`../../tool/archive_conversations.dart`](../../tool/archive_conversations.dart)：可重复运行的 Hive 归档脚本。
- [`../../skills/chat-group-archive-and-review/SKILL.md`](../../skills/chat-group-archive-and-review/SKILL.md)：已初始化并可打包的项目级 Skill。

## 这次归档的覆盖范围

- 来源：`data/messages.hive`、`data/chat_groups.hive`、`data/ai_characters.hive`。
- 已归档：74 个角色、8 个群组、783 条消息、35 个对话（8 群聊 + 27 私聊）。
- 时间范围：2026-07-07 至 2026-07-09。
- 未读取：`api_configs.hive`、`app_settings.hive`。
- 未导出：API key、供应商/模型/配置 ID、系统提示词、本机附件绝对路径和附件二进制。

消息正文保留用于质量复盘；默认脚本会遮盖常见内联密钥模式，因此归档仍应按敏感数据处理。
