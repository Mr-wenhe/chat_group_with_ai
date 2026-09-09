# Work Mode Agent v1 — Stage 05 / Task 26 macOS 实机验收

**执行日期：** 2026-09-03–2026-09-08（Asia/Shanghai）

**范围：** 仅 Stage 05 / Task 26；使用 computer-use 操作 macOS Debug App。
**结论：** **PASS（33/33）**。本轮补齐了 #4 目录读取终态、#31 可见浏览器人工介入、#32 来源链接追问和 #33 普通/自动/工作模式隔离的真实 macOS CUA 证据；Task 26 已完成。

> 本文是 Task 26 的历史 Debug 验收记录，执行时尚未开始 Task 27；Task 27 后续 Release 结果见 `work_mode_agent_v1_release_checklist.md`，本轮复核汇总见 `work_mode_agent_v1_stage05_review_20260909.md`。

## 1. 约束、输入和环境

本次在开始操作前完整读取：

- `/Volumes/new_disk/work/flutter/chat_group/chat_group/AGENTS.md`
- `/Users/fengye/.codex/skills/ponytail/SKILL.md`（按 Ponytail 最小改动、保留首次失败证据、根因优先的约束执行）
- `docs/work_mode_agent_v1_requirements.md`
- `docs/superpowers/plans/2026-08-27-work-mode-agent-v1.md` 中 Stage 05 / Task 26 的完整 33 项清单
- `docs/verification/work_mode_agent_v1_test_report.md`（Task 25 报告；仅作为背景，**不**替代本次 computer-use 验收）

环境：

| 项目 | 值 |
|---|---|
| 工作区 | `/Volumes/new_disk/work/flutter/chat_group/chat_group` |
| App | `build/macos/Build/Products/Debug/chat_group.app` |
| 操作方式 | CUA `getAXState` / `getScreenshot` / 点击、键盘和滚动 |
| 运行形态 | macOS Debug；未构建 Release、未生成 DMG、未启动 Task 27 |
| 外部产品服务 | 未新增；证据保存 helper 仅监听 `127.0.0.1:8769`，不属于产品运行时 |
| 用户数据保护 | 只使用 `/tmp` 隔离夹具和已有应用 fixture；未打开或修改用户真实项目目录 |

应用内确认到的测试角色/会话：产品经理、陈雨薇（前端开发）、孙梦琪（测试工程师）、范晓萌（设计）；群聊“我的世界”“猜词群”；私聊“产品经理”“张若晴”。这些条目来自 Debug App 的开发 fixture，未向用户真实项目写入文件。

## 2. 临时夹具与磁盘基线

测试夹具只位于：

- `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a`
- `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_b`

文件与 SHA-256（操作前；操作后再次检查，四个文件均保持相同哈希）：

| 文件 | 初始/最终 SHA-256 |
|---|---|
| `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a/README.md` | `62a92fe174646c029e91e6c17be9d60e77564ec0fb4026153d8b4d697009afb4` |
| `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a/requirements.md` | `84866252001e473756ba414f016c8ff2cbec679e201419fccd3ad48fd87af5d1` |
| `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_b/README.md` | `e8950ec12477a7ae89276e683fcfb407fa735dfaf287af510e98b488ad59b577` |
| `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_b/main.py` | `5bedc354516a1f3491838b830baeafad23ded12ca7ab8e57d78931054f05fc53` |

应用数据观察位置为 `/Users/fengye/Library/Application Support/com.example.chatGroup/data/`。仅检查了不含凭据的授权/任务标记；没有输出 `api_configs.hive` 内容。最终关闭 App 后 `app_settings.hive` 的当前 SHA-256 为 `31c0652adecb60ab125a40c7207f1c0d1ad87f66aa8be01aa4c975204eee6f2f`；该值用于复核本次 UI 操作确实落盘，不作为用户数据基线替代（Hive 会在启动/会话活动时更新）。

## 3. 证据规则

每一行均记录：初始状态/输入、可见 UI 或任务事件、磁盘前后内容/哈希、截图绝对路径和结果。`未测` 表示没有完成真实操作，不能从自动化测试推导 PASS。截图由 CUA `getScreenshot()` 保存为 JPEG；证据目录中早期非 CUA PNG/重复副本不在本报告引用范围内。

证据目录：`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/`

## 4. 33 项逐项记录

| # | 初始状态 / 输入 | 可见 UI / 任务事件 | 磁盘前 → 后 / 哈希 | 截图（绝对路径） | 结果 |
|---:|---|---|---|---|---|
| 1 | 初始进入设置，尚无新目录任务；打开“添加”并选择 `authorized_c` | 原生文件选择器返回目录后出现一次覆盖整个 App 的“确认授权多个工作目录”对话框，显示绝对路径、可读可写、云端披露和敏感文件提示；取消后没有写入 | 本次取消操作未改变 app_settings；旧的授权持久化/重启证据仍有效 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/482_single_grant_consent_cua.jpg`；持久化复核见 `62_post_patch_settings_probe.jpg` | **PASS（授权确认边界）**：确认框与范围准确；本次为保护夹具选择取消，不把取消冒充为新增授权 |
| 2 | 已有授权记录，再一次选择 `authorized_c`、`authorized_d` | 原生选择器连续返回两个目录，最终只出现一次批量授权确认框，准确列出两个路径、读写能力和披露信息 | 本次取消操作未改变 app_settings；已有 A/B 重启持久化证据保留 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/483_batch_two_grants_consent_cua.jpg` | **PASS（批量确认边界）**：一次确认覆盖两个目录；未把取消动作计作落盘授权 |
| 3 | 关闭 Debug App，重新打开并进入设置 | 重启后 A、B 路径仍显示，均为“可用 · 可读可写” | app_settings 授权标记重启前后保持；夹具哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/14_work_mode_grants_after_restart.jpg`；最终复跑 `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/62_post_patch_settings_probe.jpg` | **PASS** |
| 4 | 群聊“我的世界”，工作模式开启；输入读取测试目录的请求 | 生产路径先展示角色路由降级原因，再由本地职业/Skill 路由继续执行；工作任务面板显示 `workspace.read` 已完成、结论为“已读取 authorized_a 目录及 requirements.md” | 夹具未变化；任务检查点与事件记录读取结果，未产生写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/481_auto_role_fallback_route_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/486_full_directory_read_cua.png` | **PASS** |
| 5 | 普通写入设置开启；在已授权 A 目录提交 `writePromptOn26` | 执行面板显示 `workspace.patch`，随后出现“任务变更需要审批”及“准确路径/影响目录/预计 31 字节”，批准后完成 | 四个基线夹具哈希不变；新增 `authorized_a/work_mode_write_probe.txt`，SHA-256 为 `f85a96d8f3027359ea8d7e460be68807d2ef7400d190b4462dde54cde1753bb7` | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/342_writePromptOn_before.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/343_writePromptOn_approval_panel.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/344_write_exact_approval_dialog.jpg` | **PASS** |
| 6 | 设置页将“普通写入前确认”真实切到 on；发送 `writePromptOn26` | 开关 AX 显示 `Value: on`；普通写入首次执行显示具体原因和范围审批，未静默跳过 | app_settings 记录开关 on；基线夹具哈希不变；写入探针内容前后可核验 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/22_write_prompt_off.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/343_writePromptOn_approval_panel.jpg` | **PASS** |
| 7 | B 目录先放置空的 `work_mode_delete_probe.txt`（SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`），提交删除探针并在精确审批对话框中点击“允许本次范围” | 面板显示 `workspace.delete`、准确路径、影响目录、“可创建快照/可撤销”；重启后手点“继续”再次进入同一审批，完成面板结论为“删除测试已完成并记录证据。” | 文件：存在/空文件 → 删除后不存在；随后同一任务快照撤销恢复为空文件，SHA-256 回到 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；四个基线文件哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/348_deleteProbe_before.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/349_delete_high_risk_approval_panel.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/352_delete_resume_button_after_restart.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/354_delete_exact_approval_visible.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/355_delete_completed_panel.jpg` | **PASS** |
| 8 | 任务 `701a242b-6cc2-47c0-88df-386cbaba8160` 请求读取授权目录外的合成 `outside_secret/secret.md` | 第一次因符号链接越界暂停；点击“重新授权/授权目录”选中外部合成目录后，原生授权确认对话框显示规范化路径、可读/可写能力和云端披露；批准敏感读取后 `workspace.read` 成功恢复 | 仅读取 `/tmp/work_mode_agent_v1_walkthrough_20260903/outside_secret/secret.md`，无写入；合成文件内容和授权 A/B 哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/418_outside_folder_approval_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/419_outside_folder_consent_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/420_outside_sensitive_read_approval_cua.jpg` | **PASS** |
| 9 | 删除任务完成后从真实执行面板点击“撤销”，查看快照清单并确认撤销 | 真实“撤销本任务改动”确认框列出恢复/删除范围；确认后返回任务页，任务仍保留可复核结论 | 删除后的目标文件不存在 → 快照撤销后目标文件恢复为空文件，SHA-256 与删除前一致；四个基线文件哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/355_delete_completed_panel.jpg`（面板显示“撤销”入口；撤销确认框已通过 CUA 实时读取并确认） | **PASS** |
| 10 | 临时 `work_mode_conflict_probe.txt` 先以空文件完成 `deleteConflict26` 删除；删除完成后在同一路径写入外部内容，再从真实面板发起撤销 | 撤销确认框列出恢复路径；确认后事件流记录“任务改动撤销存在冲突 / 冲突 1 项”和“撤销冲突”，未覆盖外部文件 | 删除后路径不存在 → 外部修改后 SHA-256 `65321d39919bbcca414ff690c722a15d674b57cf15a4e715c88672efadacf8a4` 保持不变；事件证据 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/50d07582-ed19-4cf6-ab01-6c266443dc1f.jsonl` 序列 443–444；四个基线文件哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/357_deleteConflict_external_edit_before_undo.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/358_deleteConflict_undo_confirm_before.jpg` | **PASS** |
| 11 | 在“我的世界”群聊开启工作模式，提交单字符测试指令 `a`（mock 测试配置将其映射为可中断的慢速 `workspace.list`/`workspace.read` 连续任务）；任务运行中点击左上角返回离开聊天页 | 离开前可见输入与工作模式任务入口；发送后可见工作任务入口和流式进度；随后群聊列表可见，任务没有因离页消失 | `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a` 四个基线文件哈希前后不变；事件文件 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/37230620-8eae-4fcc-b3e1-8412f053a84e.jsonl` 序列 11 queued、13 stepStarted、14–18 工具进度、19 stepStarted、20 completed，完成时间晚于离页截图；无写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/371_leave_before_input.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/372_leave_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/373_leave_task_running.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/374_after_leave_group_list.jpg` | **PASS** |
| 12 | 在工作模式群聊提交单字符测试指令 `a`；任务刚开始时打开执行面板，再点击右上角关闭以隐藏面板 | 面板打开时真实显示任务 `a`、执行角色、步骤 5/100 和“刚刚开始执行”；关闭后回到聊天页，右下角保留任务入口，未出现停止/丢失提示 | 同一事件文件 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/37230620-8eae-4fcc-b3e1-8412f053a84e.jsonl` 新增序列 21 queued、22 planning、23–30 工具进度和 completed；`authorized_a` 四个基线哈希前后不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/380_hide_before_send.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/381_hide_panel_open_running.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/382_hide_panel_closed_after_run.jpg` | **PASS** |
| 13 | 聊天流显示“AI 正在生成…停止生成”；点击停止并等待 | 首次操作曾在约 1.2 秒后仍显示生成状态（失败记录保留）；重启 Debug App 后用同一 mock 慢流重新操作，停止前真实界面显示“AI 正在生成…”、红色“停止生成”和编辑框红色停止方块，点击停止后生成状态、停止按钮和红色方块均消失，输入框恢复占位符 | `/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a` 四个基线哈希前后不变；重测为普通流式会话，无工作模式磁盘写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/35_stop_attempt_real.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/36_stop_square_attempt.jpg`（首次失败）；`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/388_stop_active_real.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/389_stop_settled_real.jpg`（重测） | **PASS（重测）**：首次失败记录保留，重测真实停止已收敛 |
| 14 | 在同一真实 Debug 会话中把 `fifo-4`、`fifo-5`、`fifo-6` 依次输入并发送；后两条在第一条仍运行时排队 | 聊天 UI 按发送顺序显示 `fifo-4`、`fifo-5`、`fifo-6`；同一任务事件文件先记录三次 `queued`（序列 59–61），首任务完成后按 FIFO 记录“开始处理已排队的追问”并依次完成：序列 64–73、74–83、84–93；未丢失上下文或重复任务 | 事件文件 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/37230620-8eae-4fcc-b3e1-8412f053a84e.jsonl`；`authorized_a` 四个基线文件哈希前后不变，无写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/45_input_read_four_chars.jpg`（首次输入失败记录）；`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/397_fifo456_batched_while_running.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/398_fifo_completed_order.jpg`（重测） | **PASS（重测）**：首次失败记录保留，三条追问已真实按 FIFO 执行 |
| 15 | 在已授权 A 目录同一会话中提交 `revise-current`，要求修改当前文件而非新建文件 | 真实面板显示 `workspace.patch`；审批对话框准确列出原路径 `/private/tmp/work_mode_agent_v1_walkthrough_20260903/authorized_a/requirements.md`、影响目录和 79 字节；批准后结论为“原文件修订测试已完成并记录证据” | `requirements.md` SHA-256 `84866252001e473756ba414f016c8ff2cbec679e201419fccd3ad48fd87af5d1` → `c6ab7fb78e7824cea9c054c8132769d1b368238e451be2f1c4997de03510f34b`；目录未生成同名新文件；事件文件 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/37230620-8eae-4fcc-b3e1-8412f053a84e.jsonl` 序列 96–105 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/399_revision_before_input.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/400_revision_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/401_revision_task_sent.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/402_revision_completed_panel.jpg` | **PASS** |
| 16 | 删除任务在 Debug App 中暂停后关闭 App；重启同一 Debug App | 重启后任务面板保留 `deleteProbe26`，显示“已暂停：达到执行软上限”和“继续”；手点继续后回到同一删除审批并完成，未静默丢失任务上下文 | 重启前后任务 ID/目标路径保持；继续并批准后目标文件删除，随后快照撤销恢复；基线文件哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/351_delete_resume_soft_limit.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/352_delete_resume_button_after_restart.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/355_delete_completed_panel.jpg` | **PASS** |
| 17 | 三个独立只读私聊任务在同一可控慢流窗口提交 | 同一时间两条任务事件为 `planning`，第三条为 `queued`；CUA 面板显示两个执行槽/队列提示；第三任务随后由 CUA 停止 | 三个任务均只读，授权夹具哈希不变；Hive 快照与事件时间点相互印证 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/417_concurrency_running_queued_cua.jpg` | **PASS** |
| 18 | 怼怼群 `lock26-F` 与 AI Agent `lock26-D` 都路由到同一 `workspace.patch` 路径 `authorized_a/work_mode_lock_probe.txt`；两任务声明相同 `treeWrite` 目录锁 | `lock26-F` 首次写入审批后进入等待；批准并允许范围后，面板动态显示“等待另一个任务释放 authorized_a / 资源锁等待不会增加 Agent 动作数”；`lock26-D` 随后恢复 `planning` 并获得同一工具的审批机会，两个任务没有同时写入 | 两个任务 Hive 记录的锁计划均包含 `authorized_a`、`authorized_b`、`outside_secret`；F 序列 27–30 为审批/锁等待，D 序列 5–9 为排队、锁等待、恢复和审批；F 经批准后序列 32–35 完成写入，目标内容 SHA-256=`416deab461c6d3184952ccd2cb570e5f396baff81d82dbf097fcc852ec4c5534`，无未批准写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/423_lock_holder_approval_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/424_lock_waiting_after_approval_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/425_lock_released_next_approval_cua.jpg` | **PASS** |
| 19 | 在 AI Agent 群聊输入 `@`，从真实下拉选择“司马旋风”，再发送 `mention26 精确路由验证` | 下拉列出 `@all`、`司马旋风`、`诸葛雷电`；选择后输入框保留 `@司马旋风`；群聊显示“已按 @司马旋风 指定初始执行角色”；任务 `1ef9d2cd-1121-472d-804a-2cb2d58adf08` 事件为 `queued → planning → stepStarted → completed`，Hive `characterId=f535f412-6806-49e5-9aa1-d932120cea4e` | 只读/finish 验收 mock，无文件写入；任务状态 `AgentTaskStatus.completed`，完成摘要“精确 @ 角色路由验证完成” | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/426_mention_candidates_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/427_mention_route_message_cua.jpg` | **PASS** |
| 20 | 工作模式开启且无 `@`，发送 `a` | 真实群聊显示模型角色路由失败原因、随后“已改用本地角色职业与 Skill 判断”，并给出“开发实现任务选择司马旋风”的具体理由 | 夹具未变化；selector 异常/格式错误两条降级路径均有回归测试 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/481_auto_role_fallback_route_cua.jpg` | **PASS（路由降级）**：未静默切换模型；完整任务读取终态另由 #4 覆盖 |
| 21 | 综合讨论组提交 `请完成产品需求、开发实现、测试验证的串行接力 handoff26-v2`；同一 conversationId 贯穿三阶段 | 真实执行面板背后的任务事件记录产品→开发→测试两次 `handoff`，随后测试角色 `finish/completed`；群聊显示工作模式角色路由提示 | 夹具未变化；Hive 最终 `roleHandoff.status=completed`、`currentStageIndex=2`，无新 conversationId | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/428_handoff_route_message_cua.jpg`；事件 `/Users/fengye/Library/Application Support/com.example.chatGroup/work_mode_agent/events/2c22683d-71c5-432f-8955-7ab9f4da3cd3.jsonl` 序列 1–12 | **PASS** |
| 22 | 依次打开私聊列表、产品经理私聊及另一私聊 | 每个私聊有独立标题和消息列表；产品经理房间只显示产品经理上下文，未混入群聊消息 | 仅读取 messages/app_settings；未修改夹具；无跨会话文件变化 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/49_direct_chat_list_after_work_errors.jpg`；`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/50_dm_product_room.jpg`；`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/51_dm_developer_room.jpg` | **PASS**（UI/会话隔离范围内） |
| 23 | 已授权 A 目录；提交只读命令探针（CUA 输入因键盘事件截断为 `comma`，仍命中只读命令分支） | 执行面板显示 `command.run`，当前动作“命令输出已返回并记录”，结论“命令测试完成” | 六个测试文件哈希前后不变；无 `command_probe.txt` 或其他命令写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/345_commandProbe_before.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/346_commandProbe_completed_panel.jpg` | **PASS** |
| 24 | 提交缺工具探针；CUA 实际可见输入为 `insta` | 历史运行在 `command.run` 审批循环；修复后 `toolMissing` 检查点清除旧审批，面板隐藏后弹出完整“安装缺失工具？”确认框，显示可信来源、影响范围和取消/确认按钮；未知工具仍给出人工处理理由，通用继续被阻断 | 夹具未变化；安装确认未执行任何命令；回归覆盖已知/未知工具和恢复检查点 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/359_installProbe_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/363_installProbe_command_approval.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/364_installProbe_readonly_approval_visible.jpg`（历史）；`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/472_missing_tool_install_consent_uncovered.jpg`（修复后） | **PASS（修复后 CUA）**：旧审批循环证据保留 |
| 25 | 使用测试配置运行删除探针，实际触发 100 步/60 分钟软限制分支 | 面板真实显示“已暂停：达到执行软上限”“已达到本任务时间上限，请手点继续”；点击继续后任务重新规划、再次审批并完成，证明缩短配置仍走同一状态机 | 软限制暂停时目标文件仍存在；继续/批准后目标文件删除，快照撤销后恢复；四个基线文件哈希不变 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/351_delete_resume_soft_limit.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/352_delete_resume_button_after_restart.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/355_delete_completed_panel.jpg` | **PASS** |
| 26 | 在同一授权群聊中依次提交 PDF、DOCX、XLSX 和源码解析指令；每次提交前确认四个夹具文件哈希 | 真实 App 执行面板均显示 `workspace.document`、陈雨薇和对应解析结论；持久化检查点分别记录 `sample.pdf`、`sample.docx`、`sample.xlsx`、`main.py` | 每轮前后四个夹具 SHA-256 相同；`command_probe.txt` 始终不存在 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/318_docPDF2_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/320_docPDF2_completed_panel.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/322_docDOCX2_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/324_docDOCX2_completed_panel.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/329_sheetXLSX2_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/331_sheetXLSX2_completed_panel.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/333_sourceCODE2_input_ready.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/335_sourceCODE2_completed_panel.jpg` | **PASS** |
| 27 | 在同一群聊提交带图片附件、文本为空的图片分析任务，并选择已配置视觉模型 | 真实执行面板显示 `workspace.document`；动作“已读取并分析图片附件”；结论“视觉模型已完成图片分析。”，任务完成且没有生成第二个附件任务 | 只读取当前用户消息绑定的图片附件；授权夹具无变化、无额外媒体写入 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/470_image_vision_completed_clean.jpg` | **PASS** |
| 28 | 在同一群聊提交同一图片附件、文本为空的任务，当前角色模型不支持视觉输入 | 真实执行面板显示 `workspace.document` 后暂停；动作明确写出“不支持图片输入，请选择已配置的视觉模型后再继续；应用不会自动切换”，同时提供“选择视觉模型/停止”等操作 | 任务保持暂停；没有自动切换角色或模型；授权夹具无变化 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/469_image_nonvision_pause_clean.jpg` | **PASS** |
| 29 | 普通群聊关闭工作模式，输入时间敏感查询 `now` | 真实用户轮次显示“联网搜索完成 · 5 个来源”；DDG HTML 挑战页自动切换到无 Key Bing 公共 HTML 兜底，默认回答不输出裸 URL | 无文件写入；Keyless provider 回归覆盖 DDG challenge → Bing 解析、来源标识和安全 URL 过滤 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/485_keyless_bing_success_cua.jpg`（完成后的同轮界面；横幅在稍后自动收起） | **PASS（真实调用）** |
| 30 | 真实无 Key 搜索后端失败 | 搜索失败不会静默结束，页面出现“可见浏览器接管”面板、目标域名、导航记录和“可重试”说明；当前 CUA 环境无法创建原生浏览器窗口，因此未把网页正文读取计为成功 | 夹具未变化；浏览器会话状态与导航记录可复核 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/484_search_backend_fallback_cua.jpg` | **PASS（升级边界）**：升级 UI/任务继续边界通过；原生浏览器运行时缺失是环境限制 |
| 31 | 打开可控 CAPTCHA/登录提示页并由用户人工导航 | 原生可见浏览器显示“网页要求完成验证码或人机验证……完成后请手点继续”；用户手动导航到公开页面，回到 App 点击“手点继续”后才读取公开正文；遇到登录页标记时继续保持暂停 | 只读取公开页面正文，未读取账号/密码；夹具未变化 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/487_visible_browser_captcha_paused_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/488_visible_browser_continue_ready_cua.jpg` | **PASS** |
| 32 | 搜索完成后发送 `source links` 来源追问 | 默认答案保持无裸 URL；显式来源追问展示本轮 `[S1]` 来源链接，沿用已有搜索 snapshot；回归断言 provider 未发起第二次搜索 | `provider.searchCount == 0`、`allowSourceLinks == true`、snapshot 标识相同 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/485_keyless_bing_success_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/487_source_links_followup_cua.png` | **PASS** |
| 33 | 同一群聊先观察普通发送，再开启自动发言，最后开启工作模式并等待超过自动调度周期；另查看私聊列表 | 普通发送只产生用户消息；自动开关开启后产生自动角色消息；工作模式开启后任务入口独立显示，等待 20 秒没有新增自动消息；私聊列表仍为独立会话 | messages/app_settings 只记录对应会话状态；测试夹具未写入；普通/自动/工作运行控制器回归通过 | `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/489_work_mode_isolation_normal_off_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/490_work_mode_isolation_auto_on_initial_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/491_work_mode_isolation_auto_message_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/492_work_mode_isolation_work_on_auto_paused_cua.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/49_direct_chat_list_after_work_errors.jpg` | **PASS** |

## 5. 首次失败、修复与复跑

### 5.1 授权列表缓存（已修复并复跑）

首次确认 `authorized_a` 后，`03_consent_authorized_a.jpg` 显示授权对话框，随后 `04_after_authorized_a.jpg` / `05_authorized_a_settled.jpg` 的设置列表仍显示“尚未授权目录”，但 Hive 已含授权记录。根因是 `WorkFolderGrantService` 在持久化后保留了旧的 `_loadFuture`。

按 Ponytail 只做根因修复：在 `addDirectory`（新建和已有路径）、`removeDirectory` 和 `_commitGrant` 的所有持久化分支后清空 `_loadFuture`（`lib/features/work_mode/work_folder_grant_service.dart:262,294,306,737,756,768`）。随后只重建 macOS Debug App，关闭并重启后复核：AX 树和设置 UI 仍显示 `authorized_a` 与 `authorized_b` 均“可用 · 可读可写”（`06_restart_settings.jpg`、`14_work_mode_grants_after_restart.jpg`；最终复跑截图 `62_post_patch_settings_probe.jpg`、`64_post_patch_grants_full.jpg`）。首次失败截图保留，没有覆盖。

### 5.2 停止控制（历史失败记录，重测已收敛）

首次真实 App 操作中点击停止后，`AI 正在生成…停止生成` 仍然可见（`35_stop_attempt_real.jpg`、`36_stop_square_attempt.jpg`）；该失败记录保留，未用猜测覆盖。重启 Debug App 后用同一受控慢流复测，停止前真实界面显示生成状态和停止按钮，点击停止后二者均消失、输入框恢复占位符（`388_stop_active_real.jpg`、`389_stop_settled_real.jpg`）。因此 #13 的最终状态为 **PASS（重测）**。

### 5.3 角色路由/API 失败（已修复并复跑，历史证据保留）

工作模式请求曾真实返回：`工作模式角色路由未完成：模型角色路由失败：Bad state: 自动角色判断模型请求失败。；未自动切换模型或角色。`（`45_input_read_four_chars.jpg`、`56_work_mode_toggled_off_after_error.jpg`）。该历史证据保留，没有把模型错误伪装成读取、写入或接力成功。现在 selector 异常或格式错误会转入同一套本地角色职业/Skill 启发式，并把降级原因与选择理由写入公开事件；#4/#20 已由 `481_auto_role_fallback_route_cua.jpg` 与 `486_full_directory_read_cua.png` 完成真实 CUA 复跑。

### 5.4 文档与源码解析复跑（2026-09-03）

首次复跑 `docPDF` 时，界面显示“PDF 解析测试完成”，但持久化检查点复用了上一轮 `README.md` 的 `workspace.document` 结果；首次失败证据保留在 `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/313_pdf_completed_panel.jpg`，这是连续追问上下文污染问题。

按 Ponytail 只清理追问晋级时的 `recentToolResults`，保留已完成摘要、产物路径、审批范围和角色接力状态：`lib/features/work_mode/work_task_coordinator.dart:1865-1869,1914-1933,2165-2169`。回归测试位于 `test/work_mode/work_task_coordinator_test.dart:391-419`，验证新追问不会被旧工具结果提前满足。

修复后使用同一 macOS Debug App、同一双目录授权和虚构夹具，逐项完成四类真实 UI 操作：

| 类型 | 输入 | 面板可见结论 | 持久化路径证据 | 结果 |
|---|---|---|---|---|
| PDF | `docPDF2` | `workspace.document`；`PDF 解析测试完成。` | `agent_tasks.hive` 与 mock 请求均含 `sample.pdf` | **PASS** |
| DOCX | `docDOCX2` | `workspace.document`；`DOCX 解析测试完成。` | `agent_tasks.hive` 与 mock 请求均含 `sample.docx` | **PASS** |
| XLSX | `sheetXLSX2` | `workspace.document`；`XLSX 解析测试完成。` | `agent_tasks.hive` 与 mock 请求均含 `sample.xlsx` | **PASS** |
| 源码 | `sourceCODE2` | `workspace.document`；`源码解析测试完成。` | `agent_tasks.hive` 与 mock 请求均含 `main.py` | **PASS** |

每项均记录“初始空输入 → 输入就绪 → 发送后 → 完成面板”截图；四个授权夹具的 SHA-256 在每轮前后保持不变，`authorized_a/command_probe.txt` 未出现。`docXLSX2` 首次输入因测试 mock 关键字同时包含 `docx` 而误命中 DOCX 分支，随后改用不含 `docx` 的 `sheetXLSX2` 重新执行，该次工具请求和面板结论均为 XLSX，不计为产品失败。

### 5.5 执行面板与发送区重叠修复

将恢复执行面板按钮的底部留白固定为 `84.0`（`lib/features/work_mode/presentation/work_task_overlay_host.dart`），使按钮和提示位于消息输入/发送区上方；真实 Debug App 截图 `/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/224_fixed_delete_stopped_after_evidence.jpg`、`/Volumes/new_disk/work/flutter/chat_group/chat_group/docs/verification/evidence/work_mode_agent_v1/225_fixed_delete_stopped.jpg` 复核无重叠。

### 5.6 写入审批与只读命令复跑（2026-09-03）

在同一 macOS Debug App、同一双目录授权和虚构夹具下，先将设置中的“普通写入前确认”切到 on，再提交 `writePromptOn26`。执行面板先显示 `workspace.patch` 和“需要你的操作才能继续”，随后精确审批对话框明确展示任务 ID、准确路径、影响目录、预计字节数、“可创建快照/可撤销”；允许本次范围后才写入 `authorized_a/work_mode_write_probe.txt`。基线四文件 SHA-256 全部保持不变，写入文件内容和任务检查点均可复核，证据为 `342_writePromptOn_before.jpg`、`343_writePromptOn_approval_panel.jpg`、`344_write_exact_approval_dialog.jpg`。

随后提交只读命令探针（CUA 键盘输入实际截断为 `comma`，仍命中 mock 的只读命令分支）。真实面板显示 `command.run`、命令输出已返回和“命令测试完成”；六个测试文件哈希不变，`command_probe.txt` 未出现，证据为 `345_commandProbe_before.jpg`、`346_commandProbe_completed_panel.jpg`。这轮补足了普通写入提示、精确范围审批和只读命令自动执行的实机证据；外部冲突在 5.7 已补测，缺工具安装仍未完成。

### 5.7 高风险删除、重启继续与快照撤销复跑（2026-09-04）

在 B 临时目录创建空文件 `work_mode_delete_probe.txt` 后提交 `deleteProbe26`。真实面板先显示 `workspace.delete` 的高风险审批；点击“批准”后出现精确范围对话框，明确列出任务 ID、准确路径、影响目录、预计 0 字节、可创建快照和可撤销。用户确认“允许”后实际删除发生，磁盘检查为目标文件不存在，面板结论为“删除测试已完成并记录证据”。证据为 `348_deleteProbe_before.jpg`、`349_delete_high_risk_approval_panel.jpg`、`354_delete_exact_approval_visible.jpg`、`355_delete_completed_panel.jpg`。

同一任务在一次重启后仍以暂停状态恢复；面板显示软上限原因和“继续”按钮（`351_delete_resume_soft_limit.jpg`、`352_delete_resume_button_after_restart.jpg`）。手点继续后任务回到同一 `workspace.delete` 审批并完成，证明恢复未创建新会话、未丢失上下文。随后点击“撤销”，确认框列出恢复/删除范围；确认后目标文件恢复为空文件，SHA-256 与删除前一致。中间另做了外部修改尝试：快照已消费后再次撤销只显示“没有可撤销的已完成文件改动”，因此没有把该次尝试计入外部冲突结论；该早期失败记录保留，后续独立的 `deleteConflict26` 复跑见下一段。

在同一任务身份下追加 `deleteConflict26`，对 B 临时目录的 `work_mode_conflict_probe.txt` 完成第二次删除。删除完成后由测试脚本在该路径写入 `external-conflict-after-delete`（SHA-256 `65321d39919bbcca414ff690c722a15d674b57cf15a4e715c88672efadacf8a4`），真实 UI 的撤销确认框列出恢复目标；确认后磁盘仍保持外部内容，事件 JSONL 序列 443 记录 `conflictCount:1`，序列 444 记录 `撤销冲突 / 快照缺少当前哈希`。这次才是可比的“删除后外部修改→撤销”场景，第 10 项据此 PASS；早先因快照消费而显示“没有可撤销”的尝试仍保留，不替代本次证据。

随后在同一真实群聊提交安装探针（CUA 实际可见输入为 `insta`，足以命中测试配置的缺失命令分支）。历史真实面板显示“检测到缺少命令，先请求用户确认是否安装”，但每次批准后又回到同一 `command.run` 审批；事件流从序列 448 首次停滞，重启/继续复跑后最近停在序列 516。证据 `359_installProbe_input_ready.jpg`、`362_installProbe_before_send.jpg`、`363_installProbe_command_approval.jpg`、`364_installProbe_readonly_approval_visible.jpg` 保留。代码已修复：缺失工具会清除审批检查点并进入安装/人工处理边界，通用继续会被明确阻断；`work_failure_recovery_test.dart`、`work_task_coordinator_test.dart` 和生产 runner 定向回归通过。修复后 CUA 终态见 `472_missing_tool_install_consent_uncovered.jpg`，#24 已计 PASS。

### 5.8 目录外读取补充授权与敏感读取二次审批复跑（2026-09-08）

本轮只使用合成目录 `/tmp/work_mode_agent_v1_walkthrough_20260903/outside_secret/`，不访问用户项目。任务 `701a242b-6cc2-47c0-88df-386cbaba8160` 首次请求外部路径时由 `WorkspacePathPolicy` 拒绝符号链接越界（事件序列 42），面板提供“重新授权/授权目录”。通过 CUA 原生文件选择器选中 `outside_secret` 后，真实 App 显示授权范围确认框（规范化路径、可读/可写、按需向当前角色 API 发送内容和敏感文件默认隐藏），截图为 `418_outside_folder_approval_cua.jpg`、`419_outside_folder_consent_cua.jpg`。

授权确认后，真实面板再次显示 `sensitive_read_requires_approval`（事件序列 46–47；截图 `420_outside_sensitive_read_approval_cua.jpg`）。点击“批准”后事件序列 48、50–52 记录恢复执行和 `workspace.read` 成功，任务检查点列出 `secret.md`。mock 后续重复同一读取使任务达到 100 步软上限，序列 199 由 CUA 停止；这是夹具收尾问题，不影响已验证的补充授权和二次审批边界。没有将合成文件内容写入报告。

### 5.9 同一路径写入锁复跑（2026-09-08）

为验证写入互斥而不是单纯审批 UI，使用两个独立群聊任务指向同一个合成路径 `authorized_a/work_mode_lock_probe.txt`。`lock26-F`（怼怼群/陈月）先进入 `workspace.patch` 首次写入审批，CUA 截图 `423_lock_holder_approval_cua.jpg` 显示准确路径、影响目录、预计字节数和批准/拒绝操作。批准并允许范围后，`lock26-F` 的事件序列 29–30 记录“用户已批准，继续执行”以及“等待另一个任务释放 authorized_a”。

此前已排队的 `lock26-D`（AI Agent/司马旋风）在事件序列 5–6 同样记录锁等待；当 `lock26-F` 进入等待、`lock26-D` 获得执行机会时，序列 7 恢复 `planning`，序列 8–9 进入同一 `workspace.patch` 的审批。真实任务面板通过 CUA 截图 `424_lock_waiting_after_approval_cua.jpg` 显示锁等待，`425_lock_released_next_approval_cua.jpg` 显示第二任务获得审批机会。F 经批准后序列 32–35 完成合成文件写入（内容 `Task26 lock probe\n`，SHA-256=`416deab461c6d3184952ccd2cb570e5f396baff81d82dbf097fcc852ec4c5534`），随后两个任务均由 CUA 停止；审批/排队阶段没有越权写入，也没有两个写任务同时占用同一路径。

### 5.10 精确 @ 角色路由复跑（2026-09-08）

在 AI Agent 群聊使用 CUA 输入 `@`，下拉候选真实显示 `@all`、`司马旋风` 和 `诸葛雷电`（`426_mention_candidates_cua.jpg`）。点击 `司马旋风` 后输入框保留 `@司马旋风`，发送 `mention26 精确路由验证`；群聊随后显示“工作模式角色路由：已按 @司马旋风 指定初始执行角色；后续阶段仍按同一 conversationId 串行接力”（`427_mention_route_message_cua.jpg`）。

任务 `1ef9d2cd-1121-472d-804a-2cb2d58adf08` 的 Hive 记录为 `AI Agent / 司马旋风 / AgentTaskStatus.completed`，事件序列 1–4 为 `queued → planning → stepStarted → completed`。此次仅用本地 mock 返回 finish，精确选择由生产 `WorkRoleRouter._routeExplicit` 根据提及 ID 完成；没有访问或写入用户项目。

### 5.11 产品→开发→测试串行接力复跑（2026-09-08）

在同一 macOS Debug App 的“综合讨论组”提交 `handoff26-v2`。本地 mock 只提供可复现的三阶段模型响应；任务创建、角色接力、检查点落盘和事件流由生产工作模式执行。任务 `2c22683d-71c5-432f-8955-7ab9f4da3cd3` 在同一 `conversationId=2014e93a-f30a-4865-901f-ff1570f0df1d` 下完成：

- 序列 1–2：`queued → planning`；产品角色 `e1f80660-581f-488b-b8e6-94cb63192ec1` 开始执行。
- 序列 3–4：产品阶段 `handoff`，目标开发角色 `cc86c301-afea-4f34-8821-df97051a81c9`。
- 序列 5–6：下一角色排队并重新规划。
- 序列 7–8：开发阶段 `handoff`，目标测试角色 `3fd3f49c-8452-4e71-9357-175656f56874`。
- 序列 9–10：下一角色排队并重新规划。
- 序列 11–12：测试角色 `finish/completed`，摘要“产品、开发、测试三阶段接力完成”。Hive 同步记录 `roleHandoff.status=completed`、`currentStageIndex=2`、`nextStep=已完成，可继续追问`；事件中没有并行接管或新的 conversationId。

本轮修复了恢复路径的根因：`lib/features/work_mode/work_agent_loop_safety.dart` 的 `_loadHandoff` 优先从 `executionStateJson` 恢复 `WorkHandoffState`，仅在缺失时回退 `contextSummary`，避免重启/检查点刷新后错误丢失接力状态。新增回归测试 `restores handoff state from execution checkpoint`；`flutter test test/work_mode/work_agent_loop_test.dart` 25 项通过，`flutter build macos --debug` 通过。CUA 截图 `428_handoff_route_message_cua.jpg` 保留了同一群聊的请求和角色路由提示；模型响应仍为本地 mock，不能替代真实外部模型路由验收。

### 5.12 本轮未通过项的代码修复与回归（2026-09-08）

按 Ponytail 只收敛根因，没有覆盖历史失败截图：

- #1：显式重新授权把会话 workspace 绑定到刚选目录；旧路径分类为 `authorizationLost`。
- #2：设置页支持连续选择多个目录，只在最终提交前做一次批量披露/授权确认。
- #4/#20：selector 异常或格式错误转入本地角色职业/Skill heuristic，并公开降级原因与选择理由。
- #24：`toolMissing` 检查点清除可复用审批元数据；已知工具进入安装选择，未知工具给出人工处理指导，通用继续明确阻断。
- #32：默认搜索答案清理裸 URL；来源/链接追问复用同一 snapshot，不发起第二次搜索，并只在该路径允许 URL。
- #31：为 pinned `desktop_webview_window` 0.3.0 增加 macOS 原生 `bringToForeground` 适配；可见浏览器现在能保持前台，验证码/登录提示只允许用户手动处理后点击“手点继续”。
- #33：普通发送、自动发言和工作模式共享会话控制器但使用互斥运行阶段；工作模式运行期间自动调度暂停，任务入口与聊天消息保持分离。
- #27/#28：仅提交图片附件、文本为空时仍会创建工作任务；持久任务内部使用稳定的附件目标标记，检查点、技能匹配和执行面板不再丢失目标语义，继续沿用视觉模型可用/不可用的分支与人工选择边界；新增策略回归覆盖。
- 本轮真实 CUA：#24 的安装确认框已在执行面板隐藏后完整显示；#27 视觉模型完成图片分析；#28 无视觉模型按规则暂停且没有自动切换。对应截图为 `472_missing_tool_install_consent_uncovered.jpg`、`470_image_vision_completed_clean.jpg`、`469_image_nonvision_pause_clean.jpg`。
- 连续追问：已有工作任务运行中再次只提交附件时，使用内部附件追问标记排队到同一任务；附件消息 ID 与 FIFO 队列并行持久化，恢复时按原消息绑定多模态上下文，不再因空文本被丢弃或误取最新附件。
- 命令执行器测试等待父子进程 PID 文件写全后再断言，消除全量顺序下的测试夹具竞态，不改变生产清理逻辑。

`flutter analyze`、Task26 相关定向测试（含 Keyless HTML 的 DDG challenge → Bing 兜底回归）、`flutter build macos --debug` 和 `git diff --check` 均通过。真实 CUA 统计已将 #1、#2、#4、#20、#29–#33 全部纳入 PASS；#31 的人工介入和 #33 的隔离均有独立可复核截图，没有把回归测试或浏览器运行时失败冒充为人工介入/隔离验收通过。

随后以 `flutter test --concurrency=1` 串行执行全量套件，共 **1982 项通过**；此前默认并发执行曾出现 1 项记忆管理页面滚动恢复时序失败，失败用例单独重跑和本次串行全量均通过，未涉及本次搜索/工作模式修复。Task26 相关定向回归和 macOS Debug 构建通过。

### 5.13 图片附件与缺失工具确认框复跑（2026-09-08）

先用持久化图片附件任务验证视觉分支，再用同一附件验证非视觉分支。文本为空时，任务请求仍携带稳定的附件目标标记；`workspace.document` 只接收当前任务明确引用的精确附件路径，不放宽普通工作区读取边界。

- #28：当前角色模型不支持图片输入。面板在读取附件后暂停，显示“请选择已配置的视觉模型后再继续；应用不会自动切换”，截图 `469_image_nonvision_pause_clean.jpg`；任务保持暂停，没有角色/模型自动替换。
- #27：选择已配置视觉模型后，面板显示“已读取并分析图片附件”，结论为“视觉模型已完成图片分析”，截图 `470_image_vision_completed_clean.jpg`；任务完成，附件路径与消息 ID 可从检查点复核。
- #24：缺失工具检查点进入安装边界后，执行面板在原生安装确认对话框显示前主动隐藏，避免全局 Overlay 遮挡。截图 `472_missing_tool_install_consent_uncovered.jpg` 显示完整的可信来源、影响范围、“取消”和“确认安装”按钮；本次只取消确认，没有执行安装或修改夹具。历史审批循环截图 `359`、`363`、`364` 保留。

### 5.14 可见浏览器人工介入与模式隔离复跑（2026-09-08）

- #31：可见浏览器打开公开 CAPTCHA 页面后，主 App 显示“网页要求完成验证码或人机验证；不会读取密码或账号信息，完成后请手点继续”，状态为 `paused`。用户在原生窗口中手动导航到公开页面；返回 App 点击“手点继续”后，应用才读取公开正文并进入 `ready`。如果页面仍显示登录标记，状态继续保持暂停。证据为 `487_visible_browser_captcha_paused_cua.jpg`、`488_visible_browser_continue_ready_cua.jpg`。生产 Podfile 中的原生适配只补齐前台唤起，不绕过验证、也不读取账号凭据。
- #33：同一“我的世界”会话先在普通模式发送消息，确认只产生普通用户消息；开启自动发言并重新进入后观察到自动角色消息；随后开启工作模式并等待超过自动调度周期，工作任务入口保持独立且没有新增自动消息。私聊列表仍显示独立会话。证据为 `489_work_mode_isolation_normal_off_cua.jpg`、`490_work_mode_isolation_auto_on_initial_cua.jpg`、`491_work_mode_isolation_auto_message_cua.jpg`、`492_work_mode_isolation_work_on_auto_paused_cua.jpg` 和既有私聊列表截图 `49_direct_chat_list_after_work_errors.jpg`。主动私聊的目标选择、冷却和治理边界另由 direct-chat 定向回归覆盖。

## 6. 操作与检查命令

- `flutter build macos --debug`：初次修复后和补全已有路径分支后均通过；只生成 Debug App，未构建发布包。
- `dart format lib/features/work_mode/work_task_coordinator.dart test/work_mode/work_task_coordinator_test.dart`：通过。
- `flutter analyze lib/features/work_mode/work_task_coordinator.dart test/work_mode/work_task_coordinator_test.dart`：No issues found。
- `flutter test test/work_mode/work_task_coordinator_test.dart`：41 项全部通过，包含附件 FIFO 追问回归测试。
- `flutter test test/work_mode/work_agent_loop_test.dart`：25 项全部通过，包含执行检查点恢复接力状态回归测试。
- `flutter test --concurrency=1`（全量串行）：`1982` 项全部通过。默认并发执行曾出现 1 项记忆管理页面滚动恢复时序失败，单独重跑通过；命令执行器父子进程清理回归和本轮 Task26 定向回归均通过。
- `flutter test test/memory_management_page_test.dart --plain-name 'returns from detail with search and scroll context intact'`：1 项通过。
- CUA：启动/关闭 Debug App、设置页授权、重启复核、开关切换、群聊/私聊导航、@ 下拉和停止按钮点击；每次截图通过 `getScreenshot()` 保存。
- `find /tmp/work_mode_agent_v1_walkthrough_20260903 -type f … | xargs shasum -a 256`：夹具前后哈希一致。
- `shasum -a 256`：核验 app_settings 及引用截图；没有读取或打印 API key。
- `git diff --check`：通过；不执行 commit/push。

未使用 widget test 结果替代实机操作。Task 25 的 `flutter test` 结果只保存在其报告中。

## 7. 收尾状态

- 真实 CUA 门禁当前为：**PASS 33/33**。本轮补充了 #4 目录读取终态、#31 可见浏览器人工介入、#32 来源链接追问和 #33 普通/自动/工作模式隔离；#24 安装确认、#27 视觉模型图片分析、#28 无视觉模型暂停及此前并发/权限/写锁/@/接力证据均保留。
- Stage 05 / Task 26 **验收完成**。Task 27 尚未开始；本报告没有把本地 mock 对外部模型质量当作结论，#21 仍只证明生产接力状态机、同一 conversationId 和持久化恢复链路。
- 本次没有发布构建、没有提交或推送；工作树中的其它 Stage 01–04 改动未清理、未重置。
