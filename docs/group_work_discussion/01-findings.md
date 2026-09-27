# 偏差定位与检查记录

## 1. 范围与证据等级

检查基线为 `ec69138`，开始时工作区干净。范围为工作模式输入、角色选择、接力、单任务循环、技能注入、文件完成门禁、追问、审批与恢复，以及对应已有测试。对关键分支进行了源码逐段检查，并与本次需求和旧规格对照；不把本报告称作全仓库 Review 或新需求验收通过。

未读取开发 Hive、API Key 或真实聊天数据库，未调用角色 LLM，未安装转换工具，未实际执行截图任务。因此不能确定截图当时的 App 二进制版本、角色配置、旧任务状态和模型返回；以下明确区分已证实的实现缺口和历史路径推断。

旧规格 [work_mode_agent_v1_requirements.md](../work_mode_agent_v1_requirements.md) 的 4.3（第 87 行）定义的是角色选择与串行接力，并未规定“全员先讨论、执行人收敛后才执行”。新需求应作为该规格的增补与冲突覆盖，不可沿用旧阶段验收结论。

## 2. 全部发现（按严重程度排序）

### F1 / P1：没有讨论前置阶段，选人后立即进入执行

- 证据：`lib/features/chat_group/chat_room_agentic_input_support.dart:67` 工作模式分支直接进入 `_runWorkModeTask`；`:226` 路由；`:382` 的 `coordinator.submit(task)` 提交。`lib/features/work_mode/default_work_task_runner.dart:289` 创建唯一执行角色的 `WorkAgentLoop`。`lib/features/work_mode/agent_decision.dart:4` 只有 plan/tool/clarify/handoff/finish。
- 影响：用户写“大家先讨论”，仍然只是给一个执行角色的自然语言。没有逐成员发言调度、参与记录、建议取舍、理解进度或执行前硬门禁；模型可以直接调用工具。
- 修复方向：复用全局协调器，在群任务执行前增加持久讨论阶段；不同角色真实独立发言，以各自模型配置调用，不能由一个模型冒充全群。讨论状态不得授予工具执行权。
- 对应原始偏差 1；需求 R01–R07。

### F2 / P1：`@all` 与最终执行人混在一个路由语义中

- 证据：`lib/features/chat_group/chat_room_utils.dart:79` 将 `@all` 展开为所有角色 ID；`lib/features/work_mode/work_role_router.dart:68` 在检查具体角色前拒绝任何 `mentionsAll`。`:246` 的 `_routeExplicit` 将第一个被 @ 的角色绑定为初始阶段执行者，并不理解“最后由某人输出”。
- 影响：当前源码遇到截图里的 `@all … 最后由@产品经理` 应拒绝路由，不能按用户意图进入讨论。单独 @ 某位成员征询意见也可能被当成执行人。
- 历史线索：`lib/features/work_mode/work_mode_policy.dart:46` 的旧 `selectExecutor` 遍历 mentionedIds，选首个可用角色；与 `@all` 展开组合时存在选中列表首人的路径。当前 lib 调用检索没有找到其生产调用方，不能说截图确定由此导致。
- 修复方向：区分讨论对象、咨询对象、明确执行委托；广播不能覆盖明确执行人。不确定或歧义必须 @用户澄清。
- 对应原始偏差 2；需求 R02–R04。

### F3 / P1：职业能力约束过粗，无法可靠保证 HTML 由前端角色执行

- 证据：`lib/features/work_mode/work_role_router_planner.dart:48` 按整句关键词推断 product/development/testing/general；development 正则没有 html/前端；`:137` general 一律合格；`:153` 的 profile 包含名字、标签、全局 Skill 正文。`:3` 依照阶段顺序选人且同一角色不可重复。
- 影响：单纯 HTML 任务可能成为通用任务；“产品需求文档中提到开发测试”可能变成产品→开发→测试的实际接力。名字或全局技能提到“开发”也可能增加能力分，违背“以配置职业能力为依据”。安装格式工具不应让测试角色自动取得前端职业资格。
- 修复方向：按最终交付物判断必要职业能力，将当前任务产出与产出内容描述分开；以明确角色职业、能力、职责配置为凭据，名字不作为资格证据；可用性和权限另行验证。
- 对应原始偏差 2；需求 R03、R04、R08。

### F4 / P1：Word 技能主动允许降级，交付门禁不核验 Word 合同

- 证据：`lib/features/agentic/document_skill_templates.dart:49` 附近 Word 模板明确指示“没有时如实降级为 Markdown”；同文件 `:24` 通用文档模板要求写 `.md`。`lib/features/agentic/character_skill_resolver.dart:38` 会注入多个推荐模板；`lib/features/work_mode/work_mode_policy.dart:134` 起还会注入角色已绑定 Skill。格式约束与这些模板可能冲突。
- 门禁证据：`lib/features/work_mode/default_work_task_runner.dart:2961` 仅将请求及“是否有可读附件”传给 `WorkArtifactDeliveryGuard.failureFor`；`lib/features/work_mode/work_artifact_delivery_guard.dart:15` 仅识别源码生成要求，不核对明确 DOCX 格式、目标目录、是否为本次产出或正文结构。
- 影响：真实的 Markdown 文件也可能让任务作为完成发布，无法满足“真实 Word，保存在桌面”。只改提示词仍不够，模型 finish 必须被实际交付证据约束。
- 历史线索：`lib/features/agentic/agent_runtime.dart:2114` 将 Word 等二进制路径改成 `.md`；`test/agentic/agent_runtime_permission_test.dart:1518` 等旧测试认可降级成功。当前 provider 使用 `DefaultWorkTaskRunner`（`lib/features/work_mode/providers/work_task_providers.dart:84`），未发现生产实例化旧 AgentRuntime 的调用，因此旧降级代码是兼容路径风险，不能冒充当前入口的直接调用链。
- 修复方向：用户指定格式优先于所有技能；复用 command.run 和可信转换工具安装流程，MD 仅作为中间文件。验证真实 DOCX 包结构、正文、路径及本次产出后才能完成；能力不足应可恢复暂停，不能换格式。
- 对应原始偏差 3；需求 R08、R09。

### F5 / P1：讨论中补充当前会排队，最新旧任务也会直接复用原路由

- 证据：`lib/features/chat_group/chat_room_agentic_input_support.dart:169` 获取 latest task 后直接 enqueueFollowUp 并 return；`:405` 的 `_latestWorkTaskForConversation` 只排除 cancelled，包含 completed/failed。`lib/features/work_mode/work_task_coordinator.dart:332` 普通补充写入 FIFO，非终态等待当前 run 结束。
- 影响：尚无讨论中即时合并分支。存在旧任务时，新输入不会经过本文件中的新任务角色路由，可能继续旧角色/旧接力；这也是截图执行人不符的另一条待现场核实路径。现有安全 FIFO 本身是应保留的能力，不能通过取消旧执行“修复”。
- 修复方向：区分讨论补充、执行补充、澄清回答和已完成任务后的新任务。讨论按版本合并，执行继续 FIFO，同文件修订沿用原路径；新任务必须重新讨论及按新委托选人。
- 需求 R07、R10、R12。

### F6 / P2：现有审批有操作能力，但缺少与群聊 @提醒一致的任务绑定闭环

- 证据：`lib/features/work_mode/presentation/work_task_panel.dart:38` 起已有停止、继续、回答、审批、选目录、安装工具回调；`lib/features/work_mode/work_task_coordinator.dart:564` 安装成功后继续同任务，`:633` 支持目录授权继续。`lib/features/work_mode/work_command_policy.dart:280` 已有 pandoc 的可信安装建议。
- 缺口证据：`lib/features/work_mode/work_agent_loop_actions.dart:26` 澄清主要记录 paused 事件及检查点；`lib/features/work_mode/default_work_task_runner.dart:348` 完成后才走最终聊天消息发布路径。`lib/features/chat_group/chat_room_agentic_input_support.dart:236` 路由失败只写 system 文本并 return，没有等待补角色的持久任务。现有 @用户检测（`chat_activity_policy.dart:119`）可复用。
- 影响：不能保证缺角色、待安装、待授权、待回答等状态同时在任务面板和群聊中提供可恢复入口。路由尚未成功就 return 时尤其无法保留完整任务等待状态。
- 修复方向：复用事件/检查点、任务面板和 @规则，用 taskId + blockerId + version 绑定一次待操作提醒。消息入口打开已有任务面板即可，不另造审批系统；失效操作不可执行。
- 需求 R04、R09、R11。

### F7 / P2：理解百分比、收敛节奏与恢复数据均没有专门契约

- 证据：`lib/features/work_mode/work_task_event.dart:24` 的 progressCurrent/Total 是通用工作进度；`agent_decision.dart` 没有理解状态。`lib/features/work_mode/work_agent_loop_checkpoint.dart:223` 已有计划后要求下一步 tool/finish/clarify/handoff，不支持多角色长期讨论。`lib/core/models/agent_task.dart:123` 当前默认 100 actions / 60 分钟，不能误用仓库说明里的旧 12 步作为现行预算。
- 影响：不能用 action 比例冒充理解程度，也不能靠延长单 Agent 循环实现多成员讨论。新状态若只塞入 JSON 而不接入检查点白名单和压缩，会在恢复时丢失。
- 修复方向：为理解依据、未解决项、发言参与、无进展轮数、最新请求版本定义最小状态；复用现有 JSON 扩展及严格编解码，不重建存储框架；执行门禁校验版本和阻碍。
- 需求 R05–R07、R12。

### F8 / P2：测试覆盖现有能力，未覆盖三个偏差联合场景

- 证据：`test/work_mode/work_role_router_test.dart:44` 起覆盖显式 @、自动职业路由、接力等；`test/work_mode/work_artifact_delivery_guard_test.dart:5` 起仅三例源码门禁。当前聊天集成测试使用内存 DB/模拟网关，不能证明真实模型讨论质量或 Word 可打开。
- 影响：测试全绿不能证明先讨论、最终执行人和 Word 交付符合要求。旧降级测试甚至保护了本次明确禁止的行为。
- 修复方向：加入从输入到讨论、阻碍、恢复、交付的可运行测试以及真实 UI/真实 DOCX 验收；保留非冲突旧行为，明确更新冲突测试理由。
- 需求 R13。

## 3. 可复用能力与质量检查

| 维度 | 已检查结论 / 后续风险 |
|---|---|
| 需求、正确性 | F1–F5 为业务语义与已确认需求的偏差；当前方案不是仅改 prompt |
| 边界、失败路径 | 已查看 unknown/ambiguous 角色、无凭据、clarify、安装失败、授权取消、恢复与 FIFO；缺角色等待与讨论重入需补齐 |
| 测试有效性 | 基线测试有真实策略与协调器断言；不覆盖新讨论语义及真实 Word，参见 F8 |
| 可读性、注释、命名 | 现有 WorkRoleRouter / WorkTaskCoordinator 等命名可复用；新增复杂状态需 why 注释，避免任意 map 散落 |
| 硬编码 | 阶段匹配现为关键词常量/正则；新轮数、汇总间隔、进度依据统一命名，不能分散在 widget |
| 函数、文件、封装 | runner 与 coordinator 已是数千行文件，不能继续整段塞入讨论实现；只抽新增独立职责，不做全仓重构 |
| 架构、模块化 | 继续用全局协调器和 provider；讨论顺序调用角色模型，唯一最终执行人拥有工具执行权；页面不拥有生命周期 |
| 安全 | 保留路径授权、命令审批、凭据隔离、会话隔离；成员意见、技能、附件不是授权来源；公开摘要不是内部推理 |
| 性能 | 用轮次/请求预算及摘要控制讨论；事件增量发布、避免全量重建和忙轮询；真实大群延迟未实测 |
| 新老兼容 | JSON 扩展要进入白名单与上下文压缩；不改旧 Hive 枚举序号。旧任务恢复、私聊固定角色、备份中的未知状态需分别验证 |

## 4. 已执行校验与限制

完整命令和结果见下表；测试只使用仓库既有测试，不新增或修改测试代码。

| 命令 | 结果 |
|---|---|
| `git status --short`、`git rev-parse --short HEAD` | 初始干净，基线 ec69138 |
| `rg --files -g AGENTS.md` 与 `rg -n` 检索入口、调用方、模板、测试 | 找到根规则；定位以上调用链与历史路径 |
| `flutter analyze --no-pub` | 通过，No issues found，8.4 秒 |
| `flutter test --no-pub test/work_mode/work_role_router_test.dart test/work_mode/work_artifact_delivery_guard_test.dart test/work_mode/work_task_coordinator_test.dart test/work_mode/work_task_panel_test.dart test/work_mode/work_follow_up_policy_test.dart test/work_mode/work_mode_chat_ui_integration_test.dart` | 112 项通过 |
| `flutter test --no-pub test/work_mode/work_mode_task_recovery_test.dart test/work_mode/work_failure_recovery_test.dart test/work_mode/work_task_checkpoint_test.dart test/work_mode/work_context_builder_test.dart test/work_mode/work_document_tool_test.dart test/work_mode/work_command_policy_test.dart test/work_mode/work_folder_grant_service_test.dart test/agentic/character_skill_resolver_test.dart test/agentic/expert_skill_catalog_test.dart` | 117 项通过 |

两批合计 229 项既有测试通过，未执行新功能验收测试。文档完成后还核验了本目录链接和 `git diff --check`；最终 `git status --short` 仅显示新增 `docs/group_work_discussion/`，已有受跟踪文件没有改动。

日志暂存 `/tmp/chat-group-discussion-baseline-tests.log`、`/tmp/chat-group-discussion-baseline-analyze.log`、`/tmp/chat-group-discussion-recovery-tests.log`。探索时部分 shell 通配路径不存在，已改用真实目录检索；这不是应用检查失败。

未执行：全仓测试、Android/iOS/Release 构建、真实 API 讨论、重启运行中的 App、实际插件安装/桌面授权/Word 打开验证、截图版本与真实角色配置取证。原因：本次是代码定位及计划，未修改功能；避免真实任务副作用和私人数据读取。全量安全审计及整库性能压测不在范围。

结论：现有实现不满足本次新确认的群工作流程。已找到当前源码中的确定缺口；截图“谁在什么版本执行、是否复用旧任务”的现场归因仍未证实。后续实施按验收矩阵补齐，不把既有测试通过标成需求验收通过。
