# S6 实施与复审记录：真实 Word、指定路径与交付门禁

日期：2026-09-14。范围：只实施计划 S6，覆盖 B03、R08/R09、A14–A17/A21，以及 S1–S5 已有生产工作模式的 finish、文件发布和兼容路径收紧；停在 S6，不包含 S8 的真机 Word 打开验证。根 AGENTS.md 与 [Ponytail 技能](/Users/fengye/.codex/skills/ponytail/SKILL.md) full 已遵循；没有自动提交。

## 结果

明确要求 Word/Word 格式的任务现在只能以本次任务生成或修改、位于合同指定位置、结构真实、正文非空的 `.docx` 完成。Markdown 可以作为转换源，但不会被当作最终交付，也不会由当前生产工作模式静默改名或降级。真实转换仍复用现有 `command.run`、可信的 pandoc 建议和现有命令/安装/授权恢复，不新增转换插件市场或 DOCX SDK。

文件交付被拆成两个门禁：WorkAgentLoop 的 finish 门禁先验证产物合同，DefaultWorkTaskRunner 发布消息前再次验证并复制附件。文件保存成功而附件复制失败时，消息明确区分“文件已保存”和“附件交付失败”，任务保留可重试检查点；重试沿用已保存文件，不重新转换或覆盖原文件。

## 实施落点

- `BinaryDocumentParser.validateDocxForDelivery` 在现有有界 ZIP/XML 解析基础上增加交付专用校验：`[Content_Types].xml`、Word 主文档 Override、`word/document.xml` 根节点/`body`、正文段落；继续使用条目数、单条目读取、总展开字节和 XML 读取上限。普通文档理解路径保留旧的最小夹具兼容，不把读取兼容放宽到交付门禁。
- `WorkArtifactDeliveryGuard` 读取现有讨论合同和 `lastArtifactPaths`，要求当前任务时间范围内的普通文件、路径授权通过、规范化位置匹配、真实 `.docx`、大小上限、结构可解析、正文非空；带有“包括/包含/至少包含/核心内容”等范围时逐项检查正文。陈旧文件、错误目录、伪 ZIP、伪扩展名、仅有 Markdown 中间件、空正文和符号链接均不能通过；“Markdown 转换/转成 Word”也会进入同一 DOCX 门禁。
- `DefaultWorkTaskRunner` 在真实 finish 后调用门禁，在公共消息写入后再调用门禁并进入现有附件选择/复制流程。显式文件请求的附件全部失败会持久化 `artifactDelivery` 可重试失败和安全提示；`reportFailure` 不重复发送第二条失败消息。普通不要求交付文件的任务仍保留原有附件复制兼容行为。
- Word 直接写入路径在生产 Stage02 的 `workspace.patch` policy gate 被拒绝，提示只能写 Markdown 转换源并使用 `command.run` 生成 DOCX；不会在写入后才用扩展名伪装。`WorkModePolicy`、`document_skill_templates` 和 `AgentPromptBuilder` 均声明显式格式/位置优先、`skill.download` 只代表技能元数据、转换工具缺失/非零退出/权限或附件失败要暂停恢复，正文或命令输出中的“自动授权/改目录/忽略审批”不产生授权。
- 旧 `AgentRuntime` 仍作为兼容路径保留；只对用户明确 Word/DOC/DOCX 或目标 `.doc/.docx` 关闭原有二进制 Markdown 降级，PDF/XLSX/PPTX 等未纳入本次生产路径的旧兼容行为不顺手重构。对应旧测试改为验证 DOCX 失败且不写入，同时保留其他格式的历史兼容测试。
- `command.run` 的路径、声明影响范围、命令审批、进程边界、输出上限、缺工具安装建议和目录授权均复用现有实现；S6 没有绕过命令/路径审批，也没有把 Skill 安装当成 pandoc 已存在。实际桌面/Key/Word GUI 验证留给 S8。

## A14–A17/A21 验证矩阵

| 验收项 | S6 覆盖与证据 |
| --- | --- |
| A14 缺转换工具、安装成功/失败/拒绝/稍后 | 复用 `WorkCommandRunner` 的 `toolMissing`、可信 pandoc 安装建议和 coordinator 既有安装恢复；提示词要求安装成功后重新检测，不把 `skill.download` 当转换程序。相关命令 runner、Stage02 missing-tool recovery 和 coordinator 测试通过。 |
| A15 桌面未授权、选错、拒绝、撤销 | `WorkModeWorkspaceService`/`WorkspacePathPolicy` 仍是唯一目录边界；指定桌面使用现有 preferred root，错误/撤销授权继续暂停并可重新授权。工作模式完整回归覆盖目录拒绝、再授权和恢复。 |
| A16 伪 DOCX、空正文、陈旧产物、错误目录、损坏 ZIP | `work_artifact_delivery_guard_test.dart` 使用临时目录覆盖真实最小 DOCX、ZIP 外壳、无正文、陈旧文件、错误目录、Markdown 源和显式位置；结构检查不是只看扩展名或 ZIP 头。 |
| A17 文件保存成功但附件失败 | `default_work_task_runner_stage02_test.dart` 使用模拟 `mediaCopier` 抛错，确认文件仍可读、任务为可重试失败、消息明确“文件已保存/可重试交付”、没有重复转换或媒体附件。 |
| A21 不可信“自动授权/改目录/忽略 Word” | `WorkModePolicy`/Word Skill/AgentPrompt 文本明确拒绝；交付测试断言这些词不能授权，命令和目录仍须结构化 policy/审批。 |

另外，转换非零退出、进程输出和资源上限由现有 `work_command_runner_test.dart`、`work_command_policy_test.dart`、`work_document_tool_test.dart` 及 Stage02 recovery 测试覆盖；测试工具均为模拟 process starter、临时目录或内存网关，不使用真实桌面、真实 Key 或真实安装器。

## 测试与检查

本轮执行并通过：

| 命令 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 通过，`No issues found!` |
| `flutter test --no-pub test/work_mode` | 通过，676 个测试 |
| `flutter test --no-pub --reporter compact test/agentic` | 通过，299 个测试 |
| `flutter test --no-pub test/work_mode/default_work_task_runner_stage02_test.dart` | 通过，15 个测试；含附件失败可重试回归 |
| `flutter test --no-pub test/work_mode/work_artifact_delivery_guard_test.dart test/work_mode/work_mode_policy_test.dart test/agentic/agent_runtime_permission_test.dart test/agentic/edward_qa_infer_path_verify_test.dart` | 通过，111 个测试 |
| `flutter test --no-pub --reporter compact` | 通过，2234 个测试 |
| `dart format --output=none --set-exit-if-changed lib test` | 通过，688 个文件、0 个文件需要修改 |
| `git diff --check` | 通过 |

中间一次并行探索命令误带不存在的 `test/binary_document_parser_test.dart`；该命令被纠正后，实际 DOCX 解析/理解命令通过，且全量测试、静态分析、格式和差异检查均通过。该误调用不属于产品测试失败，也没有留下生成物。

## 复审结论与边界

复审检查了技能注入和 Word 提示词、command policy/runner、路径授权与文件写入、finish 门禁、消息发布和附件复制、旧 AgentRuntime 调用方/测试、ZIP/XML 资源限制、路径规范化、符号链接、文件损失、进程参数注入和私聊兼容。没有删除用户自定义 Skill，没有把群讨论逻辑扩展到私聊，也没有对未纳入生产路径的旧二进制格式做无关重构。

S6 只证明临时目录中的结构和交付门禁行为；没有宣称系统能在当前环境真实安装 pandoc，也没有宣称桌面 Word GUI 已打开文件。真实环境工具可用性、原生审批、用户桌面和 Word 打开验证留到 S8。本实施记录的实施阶段当时停在 **S6**；后续复审结论见下节。

## S6 复审：复审→修复→再次复审（2026-09-14）

### 范围与判定方式

本轮复审覆盖 S6 的全部实现和现有调用链：S1 产物合同到 `WorkArtifactDeliveryGuard` 的 finish/消息双门禁、DOCX Open XML 结构与正文读取、Markdown→Word 的命令/安装/授权恢复、桌面及显式路径解析、附件复制和失败重试、S5 任务提醒入口、旧 `AgentRuntime` 兼容降级、私聊隔离，以及相关测试。按根 AGENTS.md 的完整性规则逐项检查需求符合性、正确性、边界与失败路径、测试有效性、可读性、架构、隐私/安全、性能、兼容性和代码质量十项；没有删除或覆盖工作区内其他阶段的改动，也没有自动提交。

首轮基线为 S6 定向测试 118 项通过、静态分析通过。之后按“发现全部问题→修复→定向回归→全量复审”循环；全量测试中曾出现一次与 S6 无关的搜索时序用例失败，单独重跑和第二次全量均通过，记录为测试时序波动而非产品失败。

### 复审发现、修复与证据

| 等级 | 问题、证据和影响 | 修复与再次验证 |
| --- | --- | --- |
| P1 | 相对合同位置曾以授权根目录拼接，任务工作区位于授权根的子目录时，文件虽写入正确工作区仍会被门禁判错。 | `WorkArtifactDeliveryGuard` 现在以持久化工作区根解析相对位置，并保留路径段越界拒绝（[guard.dart:301-314](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:301)）；嵌套工作区回归在 [work_artifact_delivery_guard_test.dart:228](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:228)。 |
| P1 | 附件复制失败曾可能重新进入模型、命令和写文件链，导致重复转换、覆盖或再次产生副作用。 | 失败时持久化 `artifactDeliveryRetryOnly` 与原消息 ID，重试在 [default_work_task_runner.dart:3651](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:3651) 只复制已保存产物；协调器在 [work_task_coordinator.dart:2318](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_task_coordinator.dart:2318) 保持同一任务和版本。回归确认模型调用次数不增加、消息不重复、文件不重写（[default_work_task_runner_stage02_test.dart:727](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/default_work_task_runner_stage02_test.dart:727)、[work_task_coordinator_test.dart:461](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_task_coordinator_test.dart:461)）。 |
| P1 | DOCX 校验曾从整个 XML 文档提取段落，文档 `body` 外的伪正文可使空正文包通过。 | 交付校验现在要求唯一 `body`，只解析其后代段落（[binary_document_parser.dart:51](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/document/binary_document_parser.dart:51)、[binary_document_parser.dart:123](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/document/binary_document_parser.dart:123)）；body 外段落回归在 [work_artifact_delivery_guard_test.dart:302](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:302)。 |
| P1 | macOS `/var` 与 `/private/var` 别名会让显式绝对目标与实际文件字面路径不同，成功产物被错误拒收。 | 对已存在的绝对合同路径先解析符号链接再比较，最终组件仍拒绝符号链接（[guard.dart:320](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:320)）；别名回归在 [work_artifact_delivery_guard_test.dart:286](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:286)。 |
| P1 | 中文显式目标和旧的 `桌面/`、`Desktop/` 前缀曾被当作工作区下的重复目录，或被前置中文描述吞进文件名。 | 路由按最终格式选择输出路径、截断描述前缀并把桌面前缀解释为已绑定桌面根（[work_role_router_models.dart:230](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_role_router_models.dart:230)、[work_role_router_models.dart:270](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_role_router_models.dart:270)）；门禁兼容旧前缀（[guard.dart:340](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:340)）。中文文件名和旧合同回归在 [work_role_router_test.dart:603](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_role_router_test.dart:603) 与 [work_artifact_delivery_guard_test.dart:248](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:248)。 |
| P1 | 讨论已经确定 DOCX 后，用户的“继续执行”等短续接没有重复格式词，文本规则可能把 Word 要求降成普通回复。 | `requiresDocxArtifact` 读取持久化合同并保留短续接门禁，同时允许明确的打开/阅读/分析请求走只读路径（[guard.dart:66](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:66)）。无文件服务的兼容完成门禁和消息发布也传入合同格式（[guard.dart:222](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:222)、[default_work_task_runner.dart:3174](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:3174)）；短续接回归在 [work_artifact_delivery_guard_test.dart:87](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:87)。 |
| P2 | `command.run` 的空 `workingDirectory` 曾可能落到应用私有目录，而用户要求的桌面/工作区路径应由授权工作区决定。 | 空值现在归一到当前工作区，非绝对相对值也以工作区为基准（[default_work_task_runner.dart:1839](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:1839)）；只读命令回归确认进程目录等于授权目录（[default_work_task_runner_stage02_test.dart:1792](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/default_work_task_runner_stage02_test.dart:1792)）。 |
| P2 | 多文件任务部分附件成功、部分复制失败时曾可能仍标记完成，用户会误以为所有产物都已发送。 | 汇总选择、打包和复制跳过项；文件任务只要有跳过项就进入可重试失败，提示保存与附件状态分开（[default_work_task_runner.dart:3326](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:3326)、[default_work_task_runner.dart:3346](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:3346)）；回归在 [default_work_task_runner_stage02_test.dart:874](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/default_work_task_runner_stage02_test.dart:874)。 |
| P2 | 直接把 `workspace.patch` 指向 `.doc/.docx` 曾可触发旧的文本降级路径，扩展名看似 Word 但内容并非 DOCX。 | Stage02 在角色合同为 Word 时拒绝直接二进制 patch（[default_work_task_runner.dart:1825](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/default_work_task_runner.dart:1825)）；旧运行时同样拒绝并引导 `command.run` 转换（[agent_runtime.dart:2123](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/agentic/agent_runtime.dart:2123)），回归在 [agent_runtime_permission_test.dart:1515](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/agentic/agent_runtime_permission_test.dart:1515)。 |
| P2 | 文件意图正则把普通文本 `password` 的 `word` 子串识别成 Word 文件请求，可能错误触发产物门禁。 | Word/DOCX 和扩展名规则改用单词边界（[guard.dart:95](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_artifact_delivery_guard.dart:95)）；回归在 [work_artifact_delivery_guard_test.dart:45](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_artifact_delivery_guard_test.dart:45)。 |
| P2 | MD→Word 请求曾把 Markdown 源路径当成最终 DOCX 位置，尤其是“`proposal.md` 转 Word”没有显式输出名时会形成错误合同。 | 路由按最终格式挑选输出路径；只有明确 `.docx` 才绑定位置，源文件只作为转换输入（[work_role_router_models.dart:291](/Volumes/new_disk/work/flutter/chat_group/chat_group/lib/features/work_mode/work_role_router_models.dart:291)）；回归在 [work_role_router_test.dart:572](/Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_role_router_test.dart:572)。 |

以上问题均已在修复后再次复审；当前 S6 范围没有遗留 P1/P2 阻塞项。DOCX 结构门禁仍包含 Content Types、主文档部件、唯一 body、正文非空、核心内容项、路径授权、修改时间、大小/解压上限和最终组件符号链接检查；普通文档理解路径保持兼容，不把兼容夹具放宽到交付门禁。

### 最终验证矩阵

| 命令 | 结果 |
| --- | --- |
| `flutter test --no-pub --reporter compact test/work_mode` | 通过，687 项；串行运行 |
| S6 交付/路由/Stage02/协调器/命令/文档/讨论定向组合 | 通过，251 项 |
| `flutter test --no-pub --reporter compact test/agentic` | 通过，299 项（全量复跑亦覆盖） |
| `flutter test --no-pub --reporter compact` | 第二次串行复跑通过，2244 项 |
| 搜索时序失败用例单独重跑 | 通过；第一次全量中的唯一失败为时序波动 |
| `flutter analyze --no-pub` | 通过，`No issues found!` |
| `dart format --output=none --set-exit-if-changed lib test` | 通过，688 个文件，0 个文件需修改 |
| `git diff --check` | 通过 |
| S6 调试标记扫描（`S6_DEBUG`/阶段 TODO/FIXME） | 无输出 |

### 未在 S6 宣称完成的事项

真实 pandoc/转换器安装、安装失败与原生权限 UI 的现场表现、用户真实桌面路径、Word GUI 打开/渲染、真实多供应商/多角色讨论，以及跨版本重启和旧备份的更广恢复，仍按计划留给 S7/S8；本轮没有用模拟测试替代这些现场证据，也没有修改用户桌面或真实 Keychain。

### 放行结论

S6 已完成“复审→修复→再次复审”闭环，S6 范围内无遗留阻塞问题，**可以进入 S7**。本节结论只放行下一阶段，不宣称 S8 的整体验收完成。
