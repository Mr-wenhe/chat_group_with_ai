# S1–S8 完成后的全量代码审核

日期：2026-09-15。首轮审核结论为不通过；后续修复与复审结论见本文末尾。**11 项发现均已修复并通过自动化复审。**

## 范围与方法

范围为本次群工作讨论任务的全部工作区改动（包含未跟踪新增文件）、S1–S8 需求/实施/验收文档及关联调用方。并非对仓库所有无关历史功能逐行重新审核。按 Ponytail full、代码 Review 技能及根 AGENTS.md，覆盖输入提及、讨论调度、执行资格、进度、恢复/授权/安装、产物交付、面板操作、持久化、备份和事件流。只读分工检查讨论、交付、UI/备份三个方向，主审检查协调器交叉状态及回归。

首轮审核使用三个临时协调器反例定位 F04–F06。后续已将这些反例转为仓库内长期回归测试，并按根因修复生产代码。

## 发现（按严重程度）

### F01 · P1 · 成员进度可以代替执行人理解程度打开执行门禁

- 位置：[work_discussion_runner.dart:441](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_runner.dart:441)、623、758。
- 证据：成员回复和执行人汇总均使用最大理解百分比，最终门禁没有要求执行人最新汇总明确达到 100%。成员报告 100%、三条依据和完整合同、无未决问题时，即使执行人持续报告 20%，也可以达到 ready。
- 影响：违反 R06/R07，重现“执行人未理解即输出”；现有测试还固化了成员最大值的行为。
- 修复：把执行人的最新有效理解/决策与成员证据分开记录；门禁必须检查执行人明确完成。补成员 100%、执行人低进度的拒绝回归。
- 验证方式：实现与现有测试逐项对照，未另跑真实模型复现。

### F02 · P1 · HTML 请求中的“需求”关键词抢占最终职业资格

- 位置：[work_role_router_planner.dart:48](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_role_router_planner.dart:48)、18；[work_role_router.dart:495](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_role_router.dart:495)。
- 证据：“根据需求做一个 HTML 网页”被推导为 product、frontend，候选筛选固定取第一阶段 product；显式指定前端也先按产品能力校验。
- 影响：产品经理可能成为 HTML 最终候选，正确指定的前端反而被拒绝，违反 B02/A04。
- 修复：按最终产物确定执行资格，讨论上下文关键词不能改变交付职业；显式多阶段接力单独解析。
- 验证方式：路由调用链及条件分支审查。

### F03 · P1 · 无法打开的伪 DOCX 可以通过交付门禁

- 位置：[binary_document_parser.dart:142](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/document/binary_document_parser.dart:142)；[work_artifact_delivery_guard_test.dart:350](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:350)。
- 证据：只按 XML localName 检查 document/body，缺 WordprocessingML 命名空间和 OPC 根关系检查。现有正向夹具使用错误的 `xmlns:w="word"`，且缺 `_rels/.rels`，仍通过“fresh minimal DOCX passes the real Word contract”。相同结构交给 LibreOffice headless 打开失败，提示 `source file could not be loaded`，没有转换结果。
- 影响：任务可以把实际不能打开的 ZIP 标成真实 Word 交付，违反 B03/A16。
- 修复：校验合法 WordprocessingML/Content Types 命名空间及根 officeDocument 关系；使用合法最小 OPC 包作正向夹具，伪包改为拒绝测试。
- 验证方式：上述定向 Flutter 测试通过，独立 Office 打开反例失败。

### F04 · P2 · 停止后“从头开始”不再启动群讨论

- 位置：[work_task_coordinator.dart:1758](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator.dart:1758)、2516。
- 证据：retry 更新 pending discussion 后仅排队执行；_start 因讨论未完成再次暂停，没有启动 discussionRunner。诊断测试对带有效讨论状态、停止前无副作用的任务调用 retry，讨论运行次数实际为 0。
- 影响：用户已点击重新开始，任务仍停在讨论未完成，无法自行前进。
- 修复：通过统一讨论调度入口恢复，并覆盖取消收尾与重复点击竞态。
- 验证方式：新增诊断反例实测失败。

### F05 · P2 · 讨论完成会清掉缺工具安装请求

- 位置：[work_task_coordinator.dart:487](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator.dart:487)、508；[work_failure.dart:226](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_failure.dart:226)。
- 证据：toolMissing 被归入 preservesFolderGate，只有 preservesApprovalGate 保留 pendingToolRequestJson。诊断测试中原有 pandoc 请求在 ready 后变成空串；安装能力判定又依赖这段请求非空。
- 影响：恢复任务在讨论完成后丢失安装/重放依据，与“讨论与权限同时进行且能后续操作”冲突。
- 修复：分别保留目录、安装、视觉和审批暂停原因及各自检查点，讨论完成不能清除其他等待操作。
- 验证方式：新增诊断反例实测失败。

### F06 · P2 · 选择视觉角色后与最终执行人冲突

- 位置：[work_task_coordinator.dart:1823](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator.dart:1823)、2356；[default_work_task_runner.dart:197](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:197)。
- 证据：选择视觉角色直接改 task.characterId，却不更新或重新协商已 ready 的讨论执行人。生产校验只要求视觉角色属于本群。诊断测试操作后实际错误为“任务记录的执行角色与群讨论最终执行人不一致，已阻止执行”。
- 影响：面板提供的恢复操作无法继续有效群任务。
- 修复：视觉协作与最终执行身份分离；如需改变最终执行人，显式走资格校验及讨论修订，不直接覆盖身份。
- 验证方式：新增诊断反例实测失败。

### F07 · P2 · 合法结构化多行回复被状态门禁拒绝

- 位置：[work_discussion_protocol.dart:212](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_protocol.dart:212)；[work_discussion_runner.dart:796](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_runner.dart:796)；[work_discussion_state.dart:238](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_state.dart:238)、730。
- 证据：协议保留换行并允许最多 1201 字符，decisionSummary 状态限制却是无控制字符且最多 1024。有效 JSON 的 public_update 为“结论一\n结论二”或长度 1025–1201，会在协调器写状态时抛错。依据/问题字段存在同类边界。
- 影响：正常模型回复导致 discussionRunnerFailed；之前非 JSON 多行测试没有覆盖此路径。
- 修复：自然语言字段按目标字段统一规范化、限长；身份和路径继续严格验证。补合法 JSON 多行及边界长度回归。
- 验证方式：协议到持久化状态的字段约束审查。

### F08 · P2 · 损坏讨论状态只有提醒，没有可用恢复操作

- 位置：[work_task_panel.dart:1954](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/presentation/work_task_panel.dart:1954)；[work_task_coordinator.dart:2647](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator.dart:2647)、1632。
- 证据：`{"discussionState":{"schemaVersion":99}}` 触发 openTask 提醒，但面板禁用继续且无回答框；顶层无 schemaVersion 不会触发 checkpoint 重建，resumeByUser 抛错，聊天补充也只暂停返回，停止重试仍拒绝无效状态。
- 影响：原任务无法恢复。已有测试只证明提醒存在，未验证操作能恢复。
- 修复：提供用户触发的安全重建讨论操作，保留原任务、请求与附件并隔离旧副作用/审批；补实际恢复链路测试。
- 验证方式：UI、动作模型和协调器恢复路径联合审查。

### F09 · P2 · 中文名字前缀匹配导致错误指派

- 位置：[chat_room_utils.dart:122](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/chat_group/chat_room_utils.dart:122)；[work_role_router_planner.dart:313](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_role_router_planner.dart:313)。
- 证据：群里只有“王明”，用户写“最终由 @王明明 出具 Word 文档”，任意中文后缀规则会截为王明，unknownNames 为空；无 @all 时唯一 explicit ID 将王明绑定为执行人。
- 影响：未知执行人不澄清而错派，违反 B02/A06。
- 修复：优先可信 mention 身份；仅在确定的动词边界兼容无空格输入，不能吞掉任意中文姓名后缀。
- 验证方式：输入解析与路由完整调用链审查。

### F10 · P2 · 自然语言逐字包含检查误拒有效 Word

- 位置：[work_artifact_delivery_guard.dart:354](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:354)、202。
- 证据：“内容包括背景和目标”提取为一个必须逐字出现的词组，分别有“背景”和“目标”章节仍被拒绝；逗号后流程指令也可能被当成正文要求。
- 影响：有效文档卡在失败重试，实际鼓励复制提示词而非覆盖内容。
- 修复：使用讨论确定的结构化章节/验收项；未经结构化的自然语言启发式不宜作为硬失败条件。
- 验证方式：正则切片和正文判定分支审查。

### F11 · P2 · 核心职责规模未满足 R13

- 位置：[work_task_coordinator.dart:442](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator.dart:442)；[work_discussion_runner.dart:103](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_discussion_runner.dart:103)。
- 证据：coordinator 4750 行，本次 +2034/-220；新增 discussion runner 1927 行；default runner 3884 行；panel 2028 行。R13 明确已有大文件不是继续膨胀的理由，AGENTS.md 要求约 500 行/文件、约 50 行/函数及单一职责。
- 影响：讨论、审批、恢复和执行队列的交叉状态集中，增加验证与修改成本；本轮 F04–F06 正位于这些交界。
- 修复：按讨论调度、暂停恢复、身份/权限门禁、交付职责提取模块，保持唯一任务引擎；分步回归，避免无边界重构。
- 验证方式：增量统计、文件规模和职责审查；这是本任务需求未满足项，非新出现的运行崩溃。

## 质量维度结论

- 需求：B01–B03 仍有 F01–F03/F09 对应漏洞，恢复操作存在 F04–F08；不能用阶段完成记录替代验收。
- 正确性/边界/失败：上述状态组合、模型合法文本及文件格式反例未被原有测试有效覆盖。
- 测试有效性：发现正向 DOCX 夹具本身不合法，以及只断言“有按钮/提醒”而未断言“能恢复”的缺口。
- 可读性/架构：检查注释、命名、常量、函数拆分、封装、模块边界，主要未达标项为 F11。
- 安全/兼容：检查讨论身份、审批隔离、检查点 schema、备份角色重映射、公开文本处理、压缩与恢复。未确认额外凭据泄漏或越权问题；这不替代专门渗透测试。
- 性能/生命周期：检查讨论取消、会话占用、事件写入、监听释放；未执行大群高负载/长时间压力测试，不能声明容量指标通过。

## 验证记录与限制

- `flutter analyze --no-pub`：通过，No issues found，日志 `/tmp/chat-group-full-review-analyze.log`。
- `dart format --output=none --set-exit-if-changed lib test`：通过，690 文件、0 修改。
- `git diff --check`：通过。
- `flutter test --no-pub --reporter expanded test/work_mode/work_artifact_delivery_guard_test.dart --plain-name 'fresh minimal DOCX passes the real Word contract'`：通过，但 Office 打开同结构失败，构成 F03 反证。
- `flutter test --no-pub --reporter expanded test/review_coordinator_probe.dart --plain-name AUDIT`：3 项失败，分别对应 F04/F05/F06；临时测试已移出仓库。
- `flutter test --no-pub --concurrency=1 --reporter compact`：2277 项全部通过，耗时约 4 分 12 秒；日志 `/tmp/chat-group-full-review-tests.log`。这不抵消三个新增反例的失败。
- 未进行本轮真实模型精确任务、原生目录授权/撤销、真实插件安装或 Microsoft Word GUI 验收，也未执行所有平台构建。此前 S8 报告已记录原生输入自动化障碍与 Word.app 缺失，本轮未把它们当作已通过。

## 修复与复审（2026-09-15）

F01–F11 已全部完成修复：执行人自身的汇总进度成为执行门禁；HTML 以最终交付资格选择前端；DOCX 交付校验覆盖 OPC 根关系、命名空间和正文；停止重开、缺工具、视觉能力选择、损坏状态重建、中文提及和 Word 正文验收均有回归；协议文本在进入持久化状态前规范化；协调器、执行器、面板和讨论入口拆为职责 `part` 文件。

复审结果：

- `flutter analyze --no-pub`：通过。
- `dart format --output=none --set-exit-if-changed lib test`：通过，726 文件无待修改项。
- `git diff --check`：通过。
- 工作模式受影响集合：240 项通过。
- `flutter test --no-pub --concurrency=1 --reporter compact`：2290 项全部通过。
- 入口文件规模：协调器 389 行、默认执行器 245 行、任务面板 330 行、讨论入口 118 行；实际职责由同目录命名 `part` 文件承载。

未完成项仍仅限首轮已声明的环境验收：真实模型精确任务、原生目录授权/撤销、真实插件安装和 Microsoft Word GUI。本轮没有把这些环境缺口误记为自动化已通过。
