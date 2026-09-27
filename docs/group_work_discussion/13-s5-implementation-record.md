# S5 实施与复审记录：群聊 @提醒与任务面板操作闭环

日期：2026-09-14。范围：只实施计划 S5，读取 S1–S4 记录及 R04/R09/R11；停在 S5，不包含 S6 的真实 DOCX 交付改造、S7 的恢复扩展或 S8 的全链路验收。根 AGENTS.md 与 [Ponytail 技能](/Users/fengye/.codex/skills/ponytail/SKILL.md) full 已遵循；没有自动提交。

## 结果

群工作任务在需要用户介入时会在当前群留下持久的 @提醒和“处理/查看任务”按钮。按钮携带稳定的 `taskId`、阻碍标识和检查点版本，点击后只打开该任务的全局面板；面板继续调用原有协调器的审批、拒绝、目录授权、安装、回答、稍后处理、继续和停止动作。消息、面板和协调器在状态变化、旧按钮失效、并发点击及重启重放时使用同一份任务状态。

## 实施落点

- `WorkTaskUserAction` 将讨论中的补角色、执行人/资格不匹配、必要信息、澄清，以及工具缺失、目录授权、命令审批映射为可执行动作。消息 ID 为 `work-task-action:<taskId>:<blockerId>:<version>`；版本由请求修订、阻碍材料和执行人身份摘要计算，同一授权检查点不会因瞬时暂停或失败文案变化而失效。讨论 runner 的初始 `awaitingExecutor`/候选推举阶段不会误发“补角色”，只有明确资格阻塞才提醒。
- `WorkTaskActionMessageService` 复用现有 `Message`、群消息索引、未读/@统计和用户人物卡名称。相同消息 ID 只写一次，跨 provider 重建和 Hive 重启仍去重；有可用的启用 Agentic AI 成员时用真实成员发送，没有可用 AI 时使用 `senderType: system`，不伪造角色。私聊 `dm:*` 不投影群动作消息。
- `ChatMessageList`/`ChatMessageBubble` 为动作消息显示可访问的按钮语义和键盘可达的 Material 按钮。系统消息居中显示，动作回调保留原始版本信息；普通角色消息仍按原人物卡和引用/媒体逻辑渲染。群讨论的必要问题同时在面板显示输入框，提交复用聊天的 `enqueueFollowUp`，不会另建回答通道。
- `WorkTaskOverlayController` 是 app-scoped 的轻量导航桥。`WorkTaskOverlayHost` 通过精确 ID 打开隐藏任务、保持选中任务跨增量更新，并在 dispose 时解绑；任务生命周期仍由 `WorkTaskCoordinator` 持有。
- 群聊动作处理先按 `taskId` 查询并校验群组、阻碍和版本，失效时只提示状态已更新。补角色入口复用现有 `ChatGroupFormPage`，返回后调用协调器重新清空旧候选并验证成员资格、职业、模型和凭据；其他动作回到同一任务面板，不按“最新任务”猜测。
- 协调器 `_save`/`restore` 会重投影当前动作。审批、目录授权、缺失工具安装在同一检查点共享进行中的 Future；相同动作的双入口不会批准两次、打开两次原生选择器或运行两次安装器。新版本仍独立校验，完成、取消、需求版本变化后旧动作不再 current。安装或授权失败继续保留阻塞，拒绝不转换为同意降级，稍后处理只保留等待状态。
- 讨论 runner 的无角色协调/状态消息使用 `senderType: system`；具体成员贡献仍使用对应成员 ID 和 `senderType: ai`。数据库和群收件箱将 system @提醒纳入现有未读/@规则，并继续遵循 presence 规则。

## A06/A10/A14/A15/A18 覆盖

| 验收项 | S5 覆盖与证据 |
| --- | --- |
| A06 无前端、指定错职业、重复/未知角色 | 角色阻塞持久化；群里 @用户；按钮打开精确任务；补成员后重新验证，不自作主张换人或执行。`work_task_user_action_test.dart`、`work_discussion_runner_test.dart`、`work_task_panel_test.dart`。 |
| A10 缺必要信息 | `missingUserInformation`/澄清映射到“回答问题”；面板输入和聊天 FIFO 共用 `enqueueFollowUp`，回答后继续原检查点。相关 coordinator/panel 测试。 |
| A14 缺工具、安装成功/失败/稍后 | `toolMissing` 绑定版本；现有可信安装 handler 和面板确认框复用；成功回到原任务，失败保持暂停；安装双入口共享 Future。coordinator 安装与 panel 测试。 |
| A15 目录授权、选错、拒绝/取消 | `folderAuthorization` 绑定版本；复用现有 grant service/picker；覆盖校验失败或取消时保留暂停，可再次授权，成功回到原任务。coordinator folder 测试。 |
| A18 双入口、旧按钮、重启 | 审批/目录/安装并发去重；消息 ID 跨重建和重启稳定；current 校验拒绝旧版本；隐藏旧任务按 ID 打开。action-message、coordinator、panel、chat list 测试。 |

## 测试与检查

已扩展以下行为测试：动作映射和版本失效、无候选初始阶段不误提醒、消息持久化/真实 sender/system sender/重启去重、气泡按钮真实回调和 Semantics、隐藏旧任务精确打开及增量保持、审批/目录/安装双入口并发、补成员重新讨论、问题回答、失效版本和终态按钮。最终验证命令和结果记录在本文件复审表中。

本阶段没有新增 Hive model 字段，也没有新增 annotation provider，因此不运行 `build_runner`；没有增加依赖。现有父工作区的 S1–S4 修改全部保留。

### 最终验证表

| 命令 | 结果 |
| --- | --- |
| S5/S4 相关回归测试（讨论 runner/state、动作消息、面板、协调器、群聊列表/索引及 mention，共 14 个测试文件） | 通过，199 个测试 |
| `flutter test --no-pub --reporter compact` | 通过，2206 个测试 |
| `flutter analyze --no-pub` | 通过，无问题 |
| `dart format --set-exit-if-changed`（本次变更的 47 个 Dart 文件） | 通过，0 个文件需要修改 |
| `git diff --check` | 通过 |

## Ponytail full 复审

复查范围覆盖消息持久化与索引、人物卡/mention 解析、气泡和列表、任务 overlay/controller、WorkTaskPanel、WorkTaskCoordinator 的审批/拒绝/安装/目录/恢复/停止、WorkTaskClarification、WorkDiscussionRunner 的 sender 身份和重启重投影，以及相关 provider。检查了需求符合性、失败路径、并发和 stale action、可读性、架构边界、安全、性能、dispose、键盘/语义标签、列表增量更新和 Hive/旧数据兼容。

首轮复查修复了三类问题：动作写入 Future 的自引用完成错误、讨论 runner 初始阶段误发补角色提醒、审批/目录动作在双入口并发时第二次报错；同时把无角色身份的协调消息改为 system sender，并让安装去重键包含版本。修复后继续执行全部相关检查，未保留 S5 范围内的 P1/P2 阻塞。

## 阶段边界

S5 只提供提醒、任务定位和既有动作闭环；真实 Markdown→DOCX 工具/产物结构和严格交付门禁仍由 S6，跨版本恢复与更广兼容由 S7，真实设备/桌面与全矩阵验收由 S8。当前停在 S5。

## S5 独立校验与修复（2026-09-14）

本节是对上面首轮 S5 实施记录的独立复审与回归闭环，不改写首轮验证数字。复审范围覆盖本轮 S5 的全部生产代码、测试和文档，以及 A06/A10/A14/A15/A18；逐项检查了需求符合性、失败路径、并发与旧动作、可读性、架构边界、安全、性能、dispose、可访问性、Hive/旧数据兼容和测试有效性。

复审发现并修复了以下问题：

- **[P1，已修复] 轻量宿主会强制读取不存在的 app-scoped provider，且无处理器时仍展示不可用按钮。** 仅提供任务流或回调的嵌入场景可能在 `ProviderScope` 外构建时触发空值异常，或者点击没有实际协调器的审批/安装/授权按钮。`WorkTaskOverlayHost` 现在对 controller、coordinator、event store、snapshot/browser service 使用可选降级；没有真实处理器的动作不渲染，时间线使用明确的空流。见 [work_task_overlay_host.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/presentation/work_task_overlay_host.dart:121) 和 [work_task_overlay_host.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/presentation/work_task_overlay_host.dart:259)。回归覆盖见 [work_task_panel_test.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_task_panel_test.dart:1489)。
- **[P1，已修复] 面板按钮在点击时读取任务版本，原地更新可能让旧按钮操作新检查点。** 任务后台更新而 widget 尚未重建的窗口内，旧审批/拒绝/目录/安装/稍后按钮可能越过 stale guard。按钮现在在渲染时捕获版本快照，点击前再次核对当前版本；版本不一致时只报告提醒已失效，绝不调用旧的 legacy callback。见 [work_task_panel.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/presentation/work_task_panel.dart:690) 和 [work_task_panel.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/presentation/work_task_panel.dart:965)。回归覆盖见 [work_task_panel_test.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_task_panel_test.dart:708)。
- **[P1，已修复] 动作消息异步写入期间可能沿用旧任务或已离组角色的身份。** 凭据解析和 Hive 写入之间任务可能被修订、执行人可能被替换或角色可能离开群组，旧消息会错误地代表新执行人。写入前后现在都重新读取任务并校验 `taskId/blockerId/version`，重新确认群成员资格；角色失效时使用明确的 system sender，不伪造备用角色。见 [work_task_action_message_service.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_action_message_service.dart:52) 和 [work_task_user_action.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_user_action.dart:309)。回归覆盖见 [work_task_action_message_service_test.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_task_action_message_service_test.dart:263)。
- **[P2，已修复] 文件夹授权检查点会因等待中转暂停或补充失败文案而改变版本。** 用户取消第一次目录选择后，任务进入 `paused` 并记录失败信息，但当前帧仍可见的“授权目录”按钮会被误判为 stale，第二次点击无法打开确认框。动作版本现在只由实际操作范围（路径、请求/工具标记、请求 FIFO 和执行人身份）决定，排除瞬时 status 与失败文案；同一检查点可再次授权，真正改动范围仍会使旧按钮失效。见 [work_task_user_action.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_user_action.dart:180) 和 [work_task_user_action_test.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_task_user_action_test.dart:173)，端到端回归见 [work_mode_chat_ui_integration_test.dart](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_mode_chat_ui_integration_test.dart:594)。
- **[P2，已修复] 其它 S5 边界问题。** 复审同时确认并保留了首轮发现的动作写入 Future 自引用、初始 `awaitingExecutor` 误发补角色提醒、审批/目录双入口重复弹窗或重复执行、安装取消后的并发 drain、安装去重键缺少版本、无角色协调消息冒充 AI、system @提醒未进入未读/索引、旧任务按“最新任务”误打开、补角色后未清空旧候选、群成员/职业/模型/凭据复核不足、问题回答未回到原检查点、dispose 后仍回调等修复。相关行为均有对应回归测试；未发现新的 S5 P1/P2 问题。

### 独立复审最终验证

| 命令 | 结果 |
| --- | --- |
| `flutter test --no-pub test/work_mode` | 通过，669 个测试 |
| `flutter test --no-pub --reporter compact` | 通过，2226 个测试；末行为 `All tests passed!` |
| `flutter analyze --no-pub` | 通过，`No issues found!` |
| `dart format --output=none --set-exit-if-changed`（变更及新增 Dart 文件，共 50 个） | 通过，0 个文件需要修改 |
| `git diff --check` | 通过 |

中间一次全量回归曾暴露测试夹具的 `const` 编译提示和上述目录授权竞态；两者均已修复，并在最终全量回归中再次通过。没有新增 Hive 字段、Riverpod annotation 或依赖，因此本轮不需要运行 `build_runner`。

### S5 门禁结论

S5 的独立 review→修复→复审闭环已完成，S5 范围内没有遗留 P1/P2 问题，可以进入 **S6**。S6 仍未实施；本轮没有改动真实 Markdown→Word/DOCX 转换、插件安装或 Word 产物交付，这些属于下一阶段的明确范围。
