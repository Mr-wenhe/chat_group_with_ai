# S3 实施记录：真实多角色讨论、主动汇总和理解进度

日期：2026-09-11
范围：仅实施 `03-implementation-plan.md` 的 S3；未进入 S4，没有自动提交。

## 已完成

1. 在现有 `WorkTaskCoordinator` 内增加可选的讨论能力。生产 provider 注入 `WorkDiscussionRunner`；测试和旧兼容调用没有注入时仍保持 S2 的“等待门禁”行为。讨论使用同一个 `AgentTask`、同一个 `updateDiscussionState` 和现有消息/Hive/事件流，不建立第二任务引擎。
2. 首轮按当前群成员顺序逐一调用各自的 API 配置和 `characterId`，后续根据参与记录、未决问题和协调人继续邀请成员；普通随机 1–2 人回合、空闲自动聊天和执行工具循环不会被复用。模型等待期间只写事件状态，不伪造 AI 气泡。
3. 执行人已存在时由执行人主持汇总；没有执行人时只建立临时协调人，最终候选必须通过 S1 `WorkRoleRouter` 的职业/Skill 校验并依据公开推荐产生。指定执行人不可用时公开阻塞，不能静默改派；没有合格角色时公开 `@群主` 等待补角色。
4. 讨论回合设置集中超时、凭据解析超时、最大调用次数、复杂度轮数（简单 2、中等 4、复杂 6）和连续两轮无实质进展收敛规则。角色停用、凭据缺失、凭据/模型超时、协议无效和异常均落公开记录或任务事件。
5. 结构化回复在本地解析 `public_update`、理解百分比、依据、未决问题、阻塞、执行人建议和产物合同补充；公开消息只保留结论/理由/建议。模型声称 100% 时仍由本地合同、执行人、问题/阻塞、依据、最低轮数和 S2 门禁复核，关键项未清除时最高为 99%。成员建议不能覆盖用户已确定的 DOCX/位置/执行人合同；明确执行人凭据失效时保留其 owner 检查点，不自动换备用角色。
   成员提交的合同字段先作为公开建议提供给协调人/执行人，只有汇总者的取舍才会合并进最新合同。
6. 协调人/执行人每轮以 `[理解进度 N%]` 公开汇总，并把当前百分比、轮次和未决项写入任务面板；进度不会被陈旧摘要回退，未选执行人时摘要标记 `[暂定协调]`。达到 `ready` 后直接经 S2 唯一入口排队执行，不增加二次方案确认。讨论调用明确 `requiresTools: false`。
7. 讨论取消、应用数据清除和协调器释放会取消并等待讨论回合；恢复时只对带有效讨论标记且仍在等待讨论的群任务重新启动，已阻塞的任务必须由用户补充或显式重试，迟到回调不能复活已停止任务。

## 测试与验证

- 新增 `test/work_mode/work_discussion_runner_test.dart`：16 项可控网关测试覆盖真实 `characterId` 调用顺序、全员首轮机会、成员二次发言与未决项定向、公开执行人汇总/百分比、复杂度轮数、连续无进展退出、模型虚报 100%、超时、取消、显式 owner 不自动换人、陈旧摘要不回退进度和无效结构化回复保护。
- `flutter test --no-pub test/work_mode/work_discussion_runner_test.dart`：16 项通过；单调进度回归在联合集前后均复跑通过。
- 联合执行 `flutter test --no-pub test/work_mode/work_discussion_state_test.dart test/work_mode/work_discussion_runner_test.dart test/work_mode/work_task_coordinator_test.dart test/work_mode/work_mode_chat_ui_integration_test.dart test/work_mode/work_task_panel_test.dart test/work_mode/work_role_router_test.dart test/mention_parsing_test.dart`：175 项通过；S2 唯一执行门禁、面板（含理解百分比/未决问题）、路由和 UI 集成保持通过。
- `flutter analyze --no-pub`：无问题；`git diff --check`：通过。
- 全量 `flutter test --no-pub`：最终重跑 2177 项全部通过。

## 尚未覆盖与风险

- 真实供应商模型的发言质量、是否能长期遵守结构化协议、复杂任务的语义收敛仍需 S8 真实模型验收；本阶段只验证可控网关下的身份、顺序、状态和门禁。
- 用户补充信息进入同一讨论任务的完整追问/合并体验属于计划中的后续阶段；S3 会公开 `@群主` 问题并持久阻塞，不会擅自把补充内容当授权。路由失败、无成员和明确 owner 凭据失效也会保留任务检查点，不静默丢弃。
- Word/DOCX 生成、插件安装和目录授权继续由 S2 后的执行阶段处理；讨论回合不触发这些副作用。
