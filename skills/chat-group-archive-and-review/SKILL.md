---
name: chat-group-archive-and-review
description: This skill should be used when a Flutter/Hive chat project needs all conversations archived, sensitive fields excluded, repeated user feedback analyzed, or stable delivery practices converted into reusable skills and workflows.
---

# Chat Group Archive And Review

## Overview

建立可重复的“读取数据 → 脱敏归档 → 证据分析 → 提炼 Skill → 验证交付”流程。保留对话正文和时间线，用结构化统计识别重复请求、等待/卡顿、上下文遗忘、工具未执行和交付不可见等问题；将已验证的解决方案沉淀成可触发、可检查、可复用的工作流。

## Workflow Decision Tree

1. 确认对话来源：优先查找 Hive/SQLite/JSON 导出和现有导出服务；不要假设 UI 中看到的对话等于存储中的全量数据。
2. 识别敏感边界：单独列出 API key、供应商、模型、配置 ID、系统提示词、本机绝对路径和附件二进制；默认排除或脱敏。
3. 生成归档：使用项目已有脚本；本项目使用 `dart run tool/archive_conversations.dart`，输出 `docs/archive/conversations/README.md`、`archive.json` 和逐对话 Markdown。
4. 分析问题：先统计再下结论。至少检查精确重复、近似重复、用户催办、工具/文件交付、上下文记忆、时间/事实一致性、自动群聊刷屏和异常对话分叉。
5. 提炼资产：仅把跨任务稳定成立的做法写成 Skill；把一次性修复留在问题报告，不要把偶然对话风格误写成规则。
6. 验证交付：重新运行归档脚本，校验 JSON，检查文件数/消息数/时间范围，运行项目的 `flutter analyze` 和相关测试；报告未覆盖的生产数据或附件内容。

## 1. Archive Safely

执行前读取项目指导文件和数据模型，确认 debug/release 数据路径。对本项目：

- 读取 `data/messages.hive`、`data/chat_groups.hive`、`data/ai_characters.hive`。
- 不打开 `data/api_configs.hive` 和 `data/app_settings.hive`，除非用户明确要求恢复这些状态。
- 默认启用正文中的常见密钥模式脱敏；需要取证级原文时才使用 `--no-redact`，并在报告中标记为敏感。
- 附件只保留 `type`、`fileName`、`fileSize`、`mimeType`、`durationMs`，不写入 `localPath` 或二进制内容。
- 将群聊、`dm:{characterId}` 私聊和未归属消息分别标记，不能把私聊误合并到群聊。

## 2. Analyze Repetition and Failure

按以下顺序分析，避免只凭印象挑几条消息：

- 计算对话/消息/用户消息/AI 消息、时间范围、群聊与私聊分布。
- 用精确文本计数找重复请求；再按意图归并“同一目标的不同说法”。
- 标记反馈词：`卡`、`没回复`、`忘记`、`主动`、`还没`、`多久`、`进度`、`文件`、`工具`、`路径`、`看不到`、`AI`、`时间`。
- 区分根因：路由未触发、工具未执行、执行状态不可见、产物路径不清、历史上下文未注入、模型事实能力不足、自动回复策略过密、测试数据/用户反复施压。
- 为每个问题保留证据定位：对话名、消息数、代表性原句、相关代码/测试文件和复现命令。

## 3. Derive Reusable Skills

每个 Skill 必须包含：

- 触发条件：用户会怎样表达需求。
- 输入与边界：需要哪些路径、权限、数据和上下文。
- 顺序步骤：每一步的动作和停止条件。
- 安全门禁：写文件、运行命令、读取外部上下文、导出敏感数据前的批准规则。
- 验证证据：命令、测试、文件存在性、内容检查和未完成项。
- 失败恢复：超时、工具拒绝、旧 bridge、路径错误、生成内容未落盘时如何继续。

优先沉淀这些稳定模式：

1. 项目上下文盘点 Skill：先读指导文件、项目地图、数据模型和当前状态，再修改。
2. 真实文件交付 Skill：明确文件名和项目相对路径，真实调用写入工具，写后检查文件存在并报告验证。
3. 代码变更验证 Skill：小步修改，先跑针对性测试，再跑 `flutter analyze`/`flutter test`，不把“已计划”写成“已完成”。
4. 对话归档复盘 Skill：生成全量索引、脱敏 JSON、逐对话 Markdown，并从统计和证据提炼重复问题。

## 4. Delivery Checklist

- [ ] 归档统计与 Hive 数据实际一致。
- [ ] 群聊、私聊、未归属对话分类正确。
- [ ] JSON 可解析，逐对话 Markdown 链接有效。
- [ ] 结构化敏感字段已排除，本机路径和附件二进制未泄露。
- [ ] 重复问题有数量或代表性证据，而不是泛泛评价。
- [ ] 每条改进建议都有优先级、影响范围和验证方式。
- [ ] 对话质量问题与代码质量问题分开记录。
- [ ] 归档脚本可再次运行，且不会覆盖源 Hive 数据。

## Resources

- `references/archive_schema.md`：本项目归档字段、隐私边界和文件结构。
- `references/review_checklist.md`：对话复盘、问题分层和交付验收清单。
- `tool/archive_conversations.dart`：项目级归档执行器；Skill 负责调用和验证，不复制另一份实现。
