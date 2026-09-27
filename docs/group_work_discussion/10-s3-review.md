# S3 校验复审记录

日期：2026-09-11
范围：`03-implementation-plan.md` 的 S3——群成员真实讨论、主动汇总、职业资格选人、理解进度、收敛和进入 S2 执行门禁。S4 的补充合并与新旧任务分流、S5 的操作提醒、S6 的 DOCX 交付、S7 的恢复闭环和 S8 的真实验收不计入本次放行。

## 结论

S3 已完成两轮“发现 → 修复 → 再复审”。本次范围内没有遗留 P1/P2 问题，**可以进入 S4**。S3 只把讨论结果安全地送到现有协调器门禁；它没有提前实现补充回答、安装转换工具、目录授权或真实 Word 生成。

## 复审方法

沿完整调用链检查了：群聊输入 → `WorkRoleRouter` → 任务创建/持久讨论状态 → `WorkTaskCoordinator` 串行调度 → 每个角色的模型请求 → 公开消息与事件 → 结构化回复合并 → `ready` 门禁 → 现有 `DefaultWorkTaskRunner`/`WorkAgentLoop`。同时检查了私聊隔离、取消、恢复、上下文压缩、任务面板、凭据解析和旧任务兼容。

复审按仓库要求覆盖需求符合性、正确性与边界、失败路径、测试有效性、可读性、架构、安全、性能、新老兼容和代码质量；先完整收集问题，再统一修复，并用专项和全量测试复核。讨论代码按 Ponytail full 执行：复用现有协调器、消息、事件、网关和凭据解析，不增加 Hive 类型或第二任务引擎。

## 第一轮发现与修复

| 级别 | 发现、证据与影响 | 修复与复审证据 |
| --- | --- | --- |
| P1 | 候选执行人路由的临时 `routePending` 标记曾会跟随正常候选选择进入状态。即使群内已推举出合格角色，受保护阻塞也可能永远不能清除，导致“讨论完成但不能执行”。证据：`chat_room_agentic_input_support.dart:519-531`、`work_discussion_runner.dart:1683-1690`。 | 只在真正需要用户处理的路由失败上保留 `routePending`；正常 `needsExecutorSelection` 进入可收敛讨论。新增候选选择和路由失败回归，确认合格执行人可从讨论结果进入 `ready`。 |
| P1 | 用户明确指定的角色因停用、职业不匹配或凭据失效时，失败路由可能丢失指定身份，后续重试会把空执行人当成可重新选人的任务，违反“不能自作主张换人”。证据：`chat_room_agentic_input_support.dart:506-515,540-555`。 | 持久检查点保留合同中的 `explicitExecutorId`，即使当前 `route.characterId` 为空也不清空执行人；runner 先阻塞并 `@` 用户，不自动选备用角色。测试 `does not auto-elect a backup when the named executor is unavailable` 通过。 |
| P1 | 群内没有可用成员或路由失败时，输入只写一条文本就返回，任务没有可恢复记录；私聊的预检失败也会静默丢失。证据：`chat_room_agentic_input_support.dart:248-280,583-623`。 | 群任务统一建立带请求、合同、附件和阻塞原因的持久讨论任务；无成员时由 runner 记录 `missingQualifiedRole` 并 `@` 用户。私聊仍不建虚拟群，但会显示预检失败原因。 |
| P1 | 成员建议中的 `format`、`location`、`contentScope` 或执行人字段可能覆盖用户已确定的交付合同，存在把 DOCX 改成 Markdown、换目录或换执行人的风险。证据：`work_discussion_runner.dart:1618-1673`。 | 成员回复仅作为公开建议；只有协调/执行人汇总才可合并，且 `_contractFieldIsAuthoritative` 保护用户合同和显式执行人，`_safeDiscussionContractPatch` 只接受当前本地合格执行人。Word 合同回归通过。 |
| P1 | 讨论回合取消、用户补充或协调器释放时，旧异步回调可能覆盖新请求版本，或在停止后重新启动旧讨论。证据：`work_task_coordinator.dart:581-617,1511-1625`。 | 采用同一串行协调器、讨论 cancellation、请求版本单调检查和完成后再启动新 revision；外部更新在 runner 活跃时拒绝。取消、续订、旧 run 迟到回调和恢复测试全部通过。 |
| P1 | 无效的结构化成员回复可能被执行人摘要的 `resolved_blockers` 清掉，随后错误地显示为可执行。证据：`work_discussion_runner.dart:334-358,620-655,1683-1711`。 | `structuredResponseInvalid:<characterId>` 属于受保护阻塞，摘要不能移除；没有有效公开回复的成员不计入进度，也不伪造气泡。 |
| P2 | 自动路由只按 `ApiConfig.hasCredential` 或首位成员判断，会把没有真实凭据的角色送进候选，或让非前端职业执行 HTML。证据：`chat_room_agentic_input_support.dart:193-202,314-328`、`work_role_router_planner.dart` 的阶段资格函数。 | 自动候选先并行解析真实凭据；最终执行人在 router、coordinator 和 runner 三处再次检查群成员、启用状态、Agentic 能力、角色/Skill 资格和凭据。HTML 的第一执行阶段只接受前端能力。 |
| P2 | 讨论中的模型回复、提示上下文和公开消息没有统一边界，可能因为过长或兼容字段导致协议失控。 | `work_discussion_protocol.dart` 采用字段白名单、整数/列表/文本边界和公开内容清洗；`work_discussion_runner.dart:1218-1240,1295-1315` 限制提示、消息和响应字节；工具调用明确 `requiresTools: false`。 |
| P2 | 任务面板仍可能给待讨论任务显示通用“继续”，用户容易误以为能跳过讨论。 | `work_task_panel.dart:1707-1750` 将待讨论状态变成明确等待说明，展示执行人/暂定推举、理解百分比、第几轮和未决问题；继续动作不会绕过讨论门禁。 |
| P2（构建） | 接入讨论状态后，聊天页缺少 `WorkTaskCoordinator` 导入，静态分析会在任务路由编译阶段失败。 | 在 `chat_room_page.dart:92` 补上导入；最终 `flutter analyze --no-pub` 无问题。 |

## 第二轮复审与追加修复

第二轮反向检查所有状态写入口、模型摘要和消息顺序，发现两项问题并修复：

1. 执行人摘要的模型百分比低于此前轮次时，公开消息可能回退显示较低百分比。`work_discussion_runner.dart:607-613,694-710` 现在以当前轮累计进度为准，并在公开前再次经过安全门槛；回归测试确认 `[80%, 80%, 100%]` 单调递增。
2. 该回归测试直接依赖 Hive 的 key 遍历顺序，第一次联合运行出现 `[80%, 100%, 80%]` 的假失败，单测重跑逻辑本身已通过。测试已改为按消息时间排序（`test/work_mode/work_discussion_runner_test.dart:650-665`），随后单测、专项集和全量集均稳定通过。这个测试有效性问题也已纳入本次复审记录。

## 业务行为核对

- 首轮邀请当前群内所有可用成员分别发言，后续按未决问题和贡献次数定向邀请；停用、无凭据、超时和协议无效都有公开记录。
- 没有明确执行人时，临时协调人只负责收集和汇总，消息标为 `[暂定协调]`；只有通过职业/Skill 资格的角色能被公开推举为最终执行人。
- 有明确执行人时，成员建议不会换人，执行人必须主动汇总并报告理解百分比；缺少用户信息、角色或凭据时持久阻塞并 `@` 用户。
- 只有讨论状态为 `ready`、合同完整、执行人资格有效且现有审批/目录门禁允许时，才进入原执行器；讨论阶段不写文件、不运行命令、不安装工具。
- 私聊不创建群讨论；普通聊天和自动闲聊仍沿原路径，旧任务未携带讨论标记时按兼容规则恢复，不伪装成已讨论。

## 验证结果

最终执行的检查如下：

| 命令 | 结果 |
| --- | --- |
| `dart format lib/features/work_mode/work_discussion_runner.dart test/work_mode/work_discussion_runner_test.dart` | 通过，无格式变更 |
| `git diff --check && flutter analyze --no-pub` | 通过，`No issues found!` |
| `flutter test --no-pub test/work_mode/work_discussion_state_test.dart test/work_mode/work_discussion_runner_test.dart test/work_mode/work_task_coordinator_test.dart test/work_mode/work_mode_chat_ui_integration_test.dart test/work_mode/work_task_panel_test.dart test/work_mode/work_role_router_test.dart test/mention_parsing_test.dart` | `+175`，全部通过 |
| `flutter test --no-pub test/work_mode/work_discussion_runner_test.dart --plain-name 'does not publish a lower percentage from a stale coordinator summary'` | 通过 |
| `flutter test --no-pub test/work_mode/work_discussion_runner_test.dart` | `+16`，全部通过；在联合集前后均复跑通过 |
| `flutter test --no-pub` | `+2177`，全部通过 |

本次没有修改 Hive 字段或生成文件，因此没有运行 `build_runner`。工作区既有未提交修改均保留，没有提交或推送。

## 未检查项与阶段边界

- 没有调用真实供应商模型、真实角色凭据或真实大群，因此模型是否长期遵守 JSON 协议、语义是否真正收敛和实际延迟仍属于 S8 验收。
- S4 的追问回答、补充合并、明确新任务重新路由，以及“执行中修改同一文件”的增量讨论尚未实现。
- S5 的消息到任务面板操作绑定、S6 的 Markdown→真实 DOCX/桌面路径验证、S7 的重启与旧备份闭环、S8 的真实 UI/产物验收均未纳入本次放行。
- 多阶段接力中“最终执行人有凭据但后续接力角色缺凭据”的分支保留在 S4 handoff 边界：当前会 `@` 用户并停止，不会丢弃最终 owner；后续阶段再补可恢复操作。
- 新增 runner 目前仍是单一 S3 能力文件，保持少量文件和单一入口以符合 Ponytail；若 S4 继续增加职责，应在增加行为前拆分提示构建/合同策略，避免继续膨胀。

没有发现会阻塞 S4 的 P1/P2 问题，阶段结论为：**S3 通过，可以进入 S4。**
