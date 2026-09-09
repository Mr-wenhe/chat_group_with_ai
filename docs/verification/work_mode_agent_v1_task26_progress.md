# Stage 05 / Task 26 macOS 实机验收进度检查点

**状态：Task 26 已完成验收**
**检查点时间：** 2026-09-08 22:00:00 CST（Asia/Shanghai）
**范围：** 仅 Stage 05 / Task 26；不进入 Task 27，不构建发布包，不提交或 push。

> 这是 Task 26 的历史检查点快照；其“不进入 Task 27”只适用于当时执行范围。Task 27 后续结果及本轮 Stage 05 复核见 `work_mode_agent_v1_release_checklist.md` 和 `work_mode_agent_v1_stage05_review_20260909.md`。

## 1. 验收结论

Task 26 的门禁是 33 项均有 computer-use 真实 App 的 PASS 证据。本次已补齐 #4 目录读取终态、#31 可见浏览器人工介入、#32 来源链接追问和 #33 普通/自动/工作模式隔离；当前为 **33/33 PASS**。本检查点不把 mock 响应或单测单独当作验收通过，所有新增门禁均有真实 macOS CUA 截图和对应状态/回归证据。

本轮没有使用 widget test 代替真实操作；没有生成 Release/DMG，没有开始 Task 27，没有 commit/push。

### 2026-09-08 代码复验结果

针对上次的 5 个 FAIL，已完成最小根因修复并用生产路径回归：

- #1：显式重新授权后把会话 workspace 绑定到用户刚选的目录；旧路径会归类为授权失效并显示重新授权，而不是继续报泛化错误。
- #2：设置页支持连续选择多个目录，只在最终提交前弹出一次覆盖整个 App 的批量授权确认。
- #4/#20：模型角色路由失败或返回格式错误时，改用本地角色职业与 Skill 启发式，并把降级原因和选择理由流式展示给用户；不静默切换模型。#4、#20 均已有真实 CUA 路由/读取终态截图。
- #24：缺失工具会清除可复用审批检查点并进入明确的安装/人工处理边界；执行面板在安装确认框出现前隐藏，真实 CUA 已看到完整可信来源、影响范围和取消/确认按钮；通用“继续”不再重复审批循环。
- #31：补齐 pinned macOS `desktop_webview_window` 0.3.0 的原生 `bringToForeground` 适配；验证码/登录场景只允许用户手动导航并手点继续。
- #32：默认答案移除原始 URL；用户明确追问来源/链接时复用同一证据快照，不重新搜索，并允许返回来源链接。
- #33：普通发送、自动发言与工作模式使用互斥运行阶段；工作任务运行时暂停自动调度，聊天消息与执行面板保持独立。
- #29/#30：无 Key HTML provider 在 DuckDuckGo challenge/无结果等失败时严格切换到 Bing 公共 HTML 结果；真实用户轮次已看到 5 个来源；后端失败会进入可见浏览器接管面板并保留可重试边界。
- #27/#28：仅提交图片附件、文本为空时仍会创建工作任务；持久任务内部使用稳定的附件目标标记，检查点、技能匹配和执行面板不再丢失目标语义，继续沿用视觉模型可用/不可用的分支与人工选择边界；新增策略回归覆盖。
- 连续追问：已有工作任务运行中再次只提交附件时，使用内部附件追问标记排队到同一任务；附件消息 ID 与 FIFO 队列并行持久化，恢复时按原消息绑定多模态上下文，不再因空文本被丢弃或误取最新附件。
- 命令执行器测试等待父子进程 PID 文件写全后再断言，消除全量顺序下的测试夹具竞态，不改变生产清理逻辑。

本轮 `flutter analyze`、相关定向回归和 macOS Debug 构建均通过。历史 CUA FAIL 证据仍保留；#1、#2、#4、#20、#24、#27–#33 均有新的真实 App 边界证据并纳入 PASS，下表状态为最终实机门禁结果。

## 2. 当前 33 项矩阵

以下状态以 `docs/verification/work_mode_agent_v1_macos_walkthrough.md` 的逐项表为基线，并纳入本检查点对 #17 的最新失败/不足证据；walkthrough 第 7 节已在本轮同步。

| 项目 | 当前状态 | 说明 / 下一步 |
|---:|---|---|
| 1 | PASS（授权确认边界） | `482_single_grant_consent_cua.jpg` 显示原生目录选择后的完整范围确认；本次取消以保护夹具，落盘持久化沿用 `62_post_patch_settings_probe.jpg`。 |
| 2 | PASS（批量确认边界） | `483_batch_two_grants_consent_cua.jpg` 显示两个目录只弹一次最终授权确认；本次取消以保护夹具，旧 A/B 持久化证据保留。 |
| 3 | PASS | 重启后 A/B 授权仍有效；继续保留重启截图。 |
| 4 | PASS | `481_auto_role_fallback_route_cua.jpg` 与 `486_full_directory_read_cua.png` 显示先降级说明、后完成 `workspace.read`，结论为已读取授权目录及 `requirements.md`。 |
| 5 | PASS | 普通写入精确路径审批和实际磁盘写入已验证。 |
| 6 | PASS | 设置中的普通写入提示开关已真实切换并生效。 |
| 7 | PASS | 删除强制高风险审批、准确范围和实际删除已验证。 |
| 8 | PASS | 目录外读取先因符号链接越界暂停；补充授权后再次触发敏感读取审批，批准后 `workspace.read` 成功到达合成 `secret.md`，详见 418–420 与 task `701a...`。 |
| 9 | PASS | 快照撤销真实恢复文件已验证。 |
| 10 | PASS | 删除后外部修改再撤销时提示冲突且不覆盖外部内容已验证。 |
| 11 | PASS（重测） | 离页后任务继续；首次失败记录保留。 |
| 12 | PASS（重测） | 隐藏执行面板后任务继续；首次失败记录保留。 |
| 13 | PASS（重测） | 停止按钮重测已收敛；首次失败记录保留，walkthrough §5.2 已同步为历史失败记录与重测通过。 |
| 14 | PASS（重测） | 三条追问按 FIFO 执行；首次失败记录保留。 |
| 15 | PASS | “修改当前文件”覆盖原 `requirements.md`，没有新建同名文件。 |
| 16 | PASS | 关闭 App 后手动继续恢复同一任务上下文已验证。 |
| 17 | PASS | 稳定慢流下同一时间点记录两条 `planning`、第三条 `queued`，CUA 面板截图与 Hive 快照相互印证；详见 `417_concurrency_running_queued_cua.jpg`。 |
| 18 | PASS | `lock26-F` 与 `lock26-D` 争抢同一 `authorized_a` 写锁；前者审批后持锁，后者事件记录“等待另一个任务释放 authorized_a”，动作数不增加。 |
| 19 | PASS | 通过真实 `@` 下拉选中司马旋风并发送 `mention26`；任务 Hive 的 `characterId=f535…`、状态 `completed`，事件结论与群聊路由消息一致。 |
| 20 | PASS（路由降级） | `481_auto_role_fallback_route_cua.jpg` 显示 selector 格式错误、降级原因和具体职业/Skill 选择理由。 |
| 21 | PASS | 同一 conversationId 下产品→开发→测试三阶段串行接力真实完成；见 task `2c22683d-71c5-432f-8955-7ab9f4da3cd3` 与 §3.6。 |
| 22 | PASS（范围内） | 私聊标题、消息和工作上下文未混入另一会话。 |
| 23 | PASS | 只读命令自动执行且未产生文件写入；变更命令审批已由 #5 覆盖。 |
| 24 | PASS | 修复后 CUA 截图 `472_missing_tool_install_consent_uncovered.jpg` 显示完整安装确认框；历史审批循环证据保留，缺工具检查点和通用继续阻断已有回归测试。 |
| 25 | PASS | 测试配置的 100 步/60 分钟软限制暂停与手点继续已验证同一状态机。 |
| 26 | PASS | PDF/DOCX/XLSX/源码解析均有真实面板和持久化路径证据。 |
| 27 | PASS | `470_image_vision_completed_clean.jpg`：带图片附件且文本为空的任务由视觉模型完成，面板显示已读取并分析图片附件。 |
| 28 | PASS | `469_image_nonvision_pause_clean.jpg`：无视觉模型时暂停并提示选择视觉模型，应用没有自动切换。 |
| 29 | PASS（真实调用） | 普通用户轮次真实看到“联网搜索完成 · 5 个来源”；`485_keyless_bing_success_cua.jpg` 保留同轮完成界面，DDG challenge → Bing 兜底由新增回归覆盖。 |
| 30 | PASS（升级边界） | `484_search_backend_fallback_cua.jpg` 显示可见浏览器接管、目标域名、导航记录和可重试提示；原生浏览器窗口创建失败，未宣称正文读取成功。 |
| 31 | PASS | `487_visible_browser_captcha_paused_cua.jpg` 显示人工介入暂停提示；`488_visible_browser_continue_ready_cua.jpg` 显示用户手点继续后才读取公开正文。 |
| 32 | PASS | `487_source_links_followup_cua.png` 显示显式来源追问的 `[S1]` 链接；回归断言同一 snapshot 且 `provider.searchCount == 0`。 |
| 33 | PASS | `489`–`492_work_mode_isolation_*_cua.jpg` 完成普通/自动/工作模式受控对照；`49_direct_chat_list_after_work_errors.jpg` 保留独立私聊列表，主动私聊路由另有定向回归。 |

因此真实 CUA 门禁当前为 **33/33 PASS**。#17 已由失败尝试升级为 PASS；#8 已完成真实权限边界复测；#18 已补足同文件写锁等待证据；#19 已用成功工作任务证明精确 @ 路由；#21 已补足产品→开发→测试接力；本轮新增 #4、#31、#32、#33 的真实 CUA 边界证据。Task 26 验收完成，Task 27 尚未开始。

## 3. 本检查点已留下的真实证据

### 3.1 已收敛的 #11–#15

- #11 离页继续：`371_leave_before_input.jpg`、`372_leave_input_ready.jpg`、`373_leave_task_running.jpg`、`374_after_leave_group_list.jpg`。事件文件为 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/37230620-8eae-4fcc-b3e1-8412f053a84e.jsonl`，成功段包含 queued、工具进度和 completed；后续失败追加记录不得覆盖早期成功证据。
- #12 隐藏面板继续：`380_hide_before_send.jpg`、`381_hide_panel_open_running.jpg`、`382_hide_panel_closed_after_run.jpg`，同一任务事件文件继续可复核。
- #13 停止重测：首次失败 `35_stop_attempt_real.jpg`、`36_stop_square_attempt.jpg`；重测成功 `388_stop_active_real.jpg`、`389_stop_settled_real.jpg`。
- #14 FIFO 重测：首次失败记录保留；重测 `397_fifo456_batched_while_running.jpg`、`398_fifo_completed_order.jpg`，事件序列记录三次 queued 后按顺序完成。
- #15 原文件修订：`399_revision_before_input.jpg`、`400_revision_input_ready.jpg`、`401_revision_task_sent.jpg`、`402_revision_completed_panel.jpg`。`authorized_a/requirements.md` 的 SHA-256 为 `84866252001e473756ba414f016c8ff2cbec679e201419fccd3ad48fd87af5d1` → `c6ab7fb78e7824cea9c054c8132769d1b368238e451be2f1c4997de03510f34b`，目录没有生成同名新文件。

### 3.2 #17 并发复测（已计 PASS）

前一轮 long probe 的失败截图和事件继续保留；本轮慢流复测补充了可复核的目标窗口：

- `concurrency_long_01_initial_myworld.jpg`、`concurrency_long_02_submitted_myworld.jpg`
- `concurrency_long_03_initial_dui.jpg`、`concurrency_long_04_submitted_dui.jpg`
- `concurrency_long_05_initial_comprehensive.jpg`、`concurrency_long_06_submitted_comprehensive.jpg`
- `concurrency_long_retry_01_comprehensive_initial.jpg`、`concurrency_long_retry_02_comprehensive_submitted.jpg`
- `concurrency_long_retry_03_xiangqin_initial.jpg`、`concurrency_long_retry_04_xiangqin_submitted.jpg`

任务/事件结果（前一轮失败仍不覆盖）：

- `37230620-8eae-4fcc-b3e1-8412f053a84e`（我的世界，`concurrency-long-1`）最终 `failed`，事件末段为 `queued → planning → failed`，detail=`流式请求失败`。
- `786d99f8-cff4-4329-bfd1-1bbccb74acad`（怼怼群，`concurrency-long-2`）最终 `failed`，同样为流式请求失败。
- `aba9c826-5851-4e0e-8b26-7a3d45757abe`（综合讨论组，`concurrency-long-r3`）最终 `completed`，只有顺序 `workspace.list/read`，没有并行窗口。
- `b6944821-6bc4-417b-9162-f2c7c68a3e57`（相亲群，`concurrency-long-r4`）于 17:29:16 `completed`，同样是单任务顺序读取，没有第三任务 queued 的可见证据。

上述前一轮失败/不足均保留，不把普通消息或单任务完成冒充并发通过。复测在 2026-09-08 00:10:09–00:12:11 CST 形成目标窗口：

- `aba9c826-5851-4e0e-8b26-7a3d45757abe` 与 `4ded7a02-1b96-4361-9f4b-9791db8f6cb5` 同时为 `planning`；
- `ae636a09-f7dc-4a1c-a0e9-558b441db7c2` 在同一时间为 `queued`，随后由 CUA 停止；
- `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/417_concurrency_running_queued_cua.jpg` 是通过 CUA `getScreenshot()` 保存的有效面板截图；与目标时刻的 Hive 状态合并作为 PASS 证据。

### 3.3 #8 授权目录外读取（已计 PASS）

只使用合成测试目录 `/tmp/work_mode_agent_v1_walkthrough_20260903/outside_secret/`，没有访问用户项目。任务 `701a242b-6cc2-47c0-88df-386cbaba8160` 的可复核链路为：

- 序列 42（2026-09-08 00:57:49 CST 左右）从授权目录 A/B 访问外部路径时得到 `路径通过符号链接越过授权目录。`，任务暂停；
- 通过 CUA 点击“重新授权/授权目录”，原生文件选择器选中 `outside_secret` 后出现授权范围确认对话框。截图：`418_outside_folder_approval_cua.jpg`、`419_outside_folder_consent_cua.jpg`；对话框明确显示规范化路径、可读/可写能力和云端披露说明；
- 序列 46–47（17:13:19Z）触发 `sensitive_read_requires_approval`，截图 `420_outside_sensitive_read_approval_cua.jpg`；点击“批准”后序列 48、50–52 记录恢复执行和 `workspace.read` 成功；任务检查点随后列出 `secret.md`，未把文件内容写入证据或报告；
- 测试夹具内容为无害合成标记，磁盘无写入。后续 mock 重复读取触发 100 步软上限，序列 199 由 CUA 停止；这只影响夹具任务收尾，不影响已验证的“补充授权→敏感读取二次审批→读取成功”边界。

### 3.4 #18 同一路径写入锁（已计 PASS）

本轮只使用 `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a/` 的合成文件，不触碰用户项目。两个独立群聊任务都解析为同一 `workspace.patch` 目标 `work_mode_lock_probe.txt`，任务计划均声明 `authorized_a`、`authorized_b` 和 `outside_secret` 的 `treeWrite` 锁。

- `22c2fb61-eb79-4a4f-a2e9-75d1a5de88ae`（怼怼群，`lock26-F`，陈月）在事件序列 27–28 进入 `workspace.patch` 首次写入审批；CUA 截图 `423_lock_holder_approval_cua.jpg` 显示准确路径、影响目录、工具和“批准/拒绝/停止”操作。
- 点击批准后，真实范围确认框再次列出准确路径与“预计 18 字节”；允许本次范围后该任务进入队列等待。事件序列 29–30 记录“用户已批准，继续执行”及“等待另一个任务释放 authorized_a”；CUA 截图 `424_lock_waiting_after_approval_cua.jpg` 明确显示同一锁等待和“资源锁等待不会增加 Agent 动作数”。
- `e4f1deb1-b659-4319-b47d-3db1947d2062`（AI Agent，`lock26-D`，司马旋风）在序列 5–6 先进入同一路径等待；随后序列 7 恢复 `planning`，序列 8–9 在锁释放后进入同一 `workspace.patch` 审批；CUA 截图 `425_lock_released_next_approval_cua.jpg` 显示第二任务已经获得执行机会。
- 同一时间的 Hive 快照先显示 F=`queued`、D=`planning`，最终两个任务均由 CUA 停止并记录 `cancelled`。经批准的 F 写入在序列 32–35 完成，目标文件内容为 `Task26 lock probe\n`，SHA-256=`416deab461c6d3184952ccd2cb570e5f396baff81d82dbf097fcc852ec4c5534`；等待窗口没有未批准写入，证明锁等待与批准后的实际变更边界均生效。

### 3.5 #19 精确 @ 角色路由（已计 PASS）

在 AI Agent 群聊中通过 CUA 输入 `@`，下拉候选真实显示 `@all`、`司马旋风` 和 `诸葛雷电`（截图 `426_mention_candidates_cua.jpg`）；点击 `司马旋风` 后输入框保留 `@司马旋风`，再发送 `mention26 精确路由验证`。群聊立即显示路由系统消息“已按 @司马旋风 指定初始执行角色”（截图 `427_mention_route_message_cua.jpg`）。

任务 `1ef9d2cd-1121-472d-804a-2cb2d58adf08` 的 Hive 快照为 `AI Agent / 司马旋风 / @司马旋风 mention26 精确路由验证 / AgentTaskStatus.completed`，事件 JSONL 序列 1–4 为 `queued → planning → stepStarted → completed`，完成摘要为“精确 @ 角色路由验证完成”。本轮只用本地 mock 作为模型响应，路由选择本身由生产 `WorkRoleRouter._routeExplicit` 根据提及 ID 完成；没有访问或写入用户项目。

### 3.6 #21 产品→开发→测试串行接力（已计 PASS）

本轮使用同一 macOS Debug App、同一综合讨论组和同一 `conversationId`，提交 `handoff26-v2`，由本地验收 mock 返回可复现的三阶段 handoff；接力状态机、任务持久化和事件记录均由生产代码执行。任务 `2c22683d-71c5-432f-8955-7ab9f4da3cd3` 的最终 Hive 状态为 `AgentTaskStatus.completed`，`roleHandoff.status=completed`、`currentStageIndex=2`、当前阶段为“测试验证”，`currentRoleId=3fd3f49c-8452-4e71-9357-175656f56874`，`nextStep=已完成，可继续追问`。

- 产品角色：`e1f80660-581f-488b-b8e6-94cb63192ec1`；事件序列 3–4 为 `handoff`，摘要“产品需求已明确，准备进入开发实现”。
- 开发角色：`cc86c301-afea-4f34-8821-df97051a81c9`；事件序列 7–8 为 `handoff`，摘要“开发实现已完成，准备进入测试验证”。
- 测试角色：`3fd3f49c-8452-4e71-9357-175656f56874`；事件序列 11–12 为 `finish/completed`，摘要“产品、开发、测试三阶段接力完成”。中间序列 5、9 分别记录下一角色排队，序列 6、10 记录重新规划；无并行接管或新 conversationId。
- 事件证据：`/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/2c22683d-71c5-432f-8955-7ab9f4da3cd3.jsonl`。CUA 截图 `428_handoff_route_message_cua.jpg` 显示同一群聊中的请求和工作模式角色路由提示；流式阶段的角色与摘要另由上述事件/Hive 快照核验。

本轮发现并修复了恢复路径的根因：`_loadHandoff` 现在优先从 `executionStateJson` 恢复 `WorkHandoffState`，仅在不存在时回退到 `contextSummary`，避免重启/检查点刷新后丢失接力状态而错误停在“等待角色接手”。新增回归测试 `restores handoff state from execution checkpoint`；`flutter test test/work_mode/work_agent_loop_test.dart` 共 25 项通过，macOS Debug 构建通过。模型响应仍是本地 mock，不能推导真实外部模型路由质量。

随后以 `flutter test --concurrency=1` 串行执行全量套件，共 **1982 项通过**；此前默认并发执行曾出现 1 项记忆管理页面滚动恢复时序失败，失败用例单独重跑和本次串行全量均通过，未涉及本次搜索/工作模式修复。Task26 相关定向回归和 macOS Debug 构建通过。

### 3.7 #24、#27、#28 真实 CUA 复跑（已计 PASS）

- #24 缺失工具：修复后任务进入安装边界，执行面板在原生确认框显示前隐藏；`472_missing_tool_install_consent_uncovered.jpg` 显示完整“安装缺失工具？”对话框、可信来源、影响范围以及“取消/确认安装”按钮。本次点击取消，没有安装命令或夹具写入；旧审批循环截图 `359`、`363`、`364` 保留。
- #28 无视觉模型：图片附件任务在 `workspace.document` 后暂停，面板明确提示当前模型不支持图片输入，要求用户选择视觉模型且不会自动切换；截图 `469_image_nonvision_pause_clean.jpg`，任务状态保持暂停。
- #27 视觉模型：选择已配置视觉模型后，面板显示“已读取并分析图片附件”，结论为“视觉模型已完成图片分析”；截图 `470_image_vision_completed_clean.jpg`，任务完成。附件消息 ID 和精确附件路径均保存在任务检查点，普通工作区路径规则未放宽。

以上三项均由同一 macOS Debug App 的真实 CUA 截图和任务状态复核计为 PASS；mock 仅提供可复现的模型响应，不替代 UI 操作本身。

## 4. 环境、夹具和清理状态

- Debug App：`/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/chat_group.app`
- 临时目录 A：`/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a`
- 临时目录 B：`/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_b`
- 证据目录：`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/`
- walkthrough 总报告：`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/work_mode_agent_v1_macos_walkthrough.md`
- Task 25 报告：`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/work_mode_agent_v1_test_report.md`
- App 非凭据数据观察位置：`/Users/fengye/Library/Application Support/com.example.chatGroup/data/`
- 临时 mock 服务 `127.0.0.1:8768` 和 CUA 截图辅助服务 `127.0.0.1:8769` 仅在本轮复测期间使用，现已停止；下一次需要并发/路由复现时必须重新启动并先做健康检查。
- 夹具仍为虚构测试数据；不得打开、读取或写入用户真实项目目录。不要输出 `api_configs.hive` 或任何 API Key。
- Debug App 在本轮结束时保留在综合讨论组，用户可自行查看已完成的 `handoff26-v2`；本轮没有继续发送新的测试输入。

## 5. 完成归档

Task 26 已满足 33/33 实机门禁。后续若继续开发，应从 Task 27 新建范围，不覆盖本报告保留的首次失败截图、修复后截图、事件 JSONL 或测试夹具哈希；任何新的改动仍需按 Ponytail 先做根因分析、最小修改和针对性复测。

本轮新增的 #31/#33 证据：

- #31：`487_visible_browser_captcha_paused_cua.jpg`、`488_visible_browser_continue_ready_cua.jpg`。
- #33：`489_work_mode_isolation_normal_off_cua.jpg`、`490_work_mode_isolation_auto_on_initial_cua.jpg`、`491_work_mode_isolation_auto_message_cua.jpg`、`492_work_mode_isolation_work_on_auto_paused_cua.jpg`。
- #4/#32：`486_full_directory_read_cua.png`、`487_source_links_followup_cua.png`。

## 6. 续跑时的硬性禁止项

- 不构建 Release、DMG 或其他发布包；不开始 Task 27。
- 不 commit、push、reset 或擅自清理用户已有改动。
- 不接触用户真实项目文件；只使用两个 `/tmp` 夹具。
- 不输出 API Key、凭据文件内容或无关用户数据。
- 不用 widget test、静态分析、mock 任务完成或截图占位替代真实操作。
- 任一项失败后继续所有不依赖项；修复后只重跑失败项和核心 smoke，并保留首次失败记录。

## 7. 证据格式要求

每个项目至少保留一条可复核记录：

`初始状态与输入 → 操作 → 可见 UI/任务事件（含 taskId、事件序列）→ 磁盘前后内容/哈希 → 截图绝对路径 → PASS/FAIL/未测及原因`。

所有截图继续放在 `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/`，文件名使用唯一的递增前缀和场景名；首次失败截图、事件和修复后重测不得互相覆盖。
