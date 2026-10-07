# 源码事实、GitHub 对照与实施计划

调研日期：2026-09-30。只读检查相关生产入口、状态、交付、恢复、记忆和备份路径；没有运行竞品或本项目功能测试，不声称性能、稳定性或完成率已经实测。在线资料为访问时的 main／指定分支，后续可能变动。

## 1. 当前实现与目标的差距

本地基线：HEAD `b3b7921d6df2ff87b5519bf357aa8c0047f46a9a` 加当时工作树。开始时已有 CLAUDE、跟进澄清、任务面板、上下文及相关测试的未提交修改；本次只新增本目录。

| 已核对事实 | 代码入口 | 对本次改造的影响 |
|---|---|---|
| 动作预算最多 100，总预算最多 60 分钟，超过后 softLimit 暂停；手动继续重置预算 | [work_agent_loop_checkpoint.dart](../../lib/features/work_mode/work_agent_loop_checkpoint.dart) `_effectiveActionLimit/_effectiveTimeLimit`；[recovery](../../lib/features/work_mode/work_task_coordinator_recovery.dart) `_implContinueAfterSoftLimit` | 需要修改所有判定、提示、恢复和展示路径；仅调大 AgentTask 默认值无效 |
| 最少两轮，上限按请求选 2/4/6，另有 96 次调用上限 | [session](../../lib/features/work_mode/work_discussion_session.dart)、[decisions](../../lib/features/work_mode/work_discussion_runner_decisions.dart)、[runner](../../lib/features/work_mode/work_discussion_runner.dart) | 需移除固定业务轮数，改为问题驱动和异常诊断 |
| 满足既有条件时可把模型的 99 归一为 100 | [round completion](../../lib/features/work_mode/work_discussion_round_completion.dart) `_finishRound` | 当前百分比不是测得的理解程度；v2 使用结构化门槛 |
| 讨论提示要求只提供职业建议并禁止工具；气泡统一加“职责意见” | [model I/O](../../lib/features/work_mode/work_discussion_runner_model_io.dart) 生产讨论提示；[member turn](../../lib/features/work_mode/work_discussion_member_turn.dart) `_collectMember` | 改提示词还不够，需接入有权限约束的真实调查 |
| dossier 包含特定项目文件／功能的静态识别 | [project dossier](../../lib/features/work_mode/work_discussion_project_dossier.dart) | 不能当成通用代码理解；优先实际读取并记录来源 |
| 讨论注入 systemPrompt，执行注入 rolePlaySystemPrompt；统一记忆 wrapper 未接入生产调用 | [memory runner](../../lib/features/work_mode/work_mode_memory_runner.dart)、[execution](../../lib/features/work_mode/default_work_task_runner_execution.dart)、[AICharacter](../../lib/core/models/ai_character.dart) | 在实际讨论／调查／执行／审查入口共享正确的成员上下文 |
| selector 按观察者全局检索，不按项目隔离，已通过 effectiveMood 读取心情 | [memory selector](../../lib/features/memory/memory_context_selector.dart) | 接入工作模式时不能将项目事实无差别写入全局记忆 |
| 有阶段计划与持久化，但群讨论任务完成后禁止推进旧 handoff | [role router](../../lib/features/work_mode/work_role_router.dart) `_stagePlan/_success`；[聊天入口](../../lib/features/chat_group/chat_room_agentic_input_support.dart)；[coordinator execution](../../lib/features/work_mode/work_task_coordinator_execution.dart) `_advanceCompletedHandoff` | 要拆分负责人、当前执行者、工作项完成和任务完成，而非只删 early return |
| 已有 DOCX／HTML 等基础结构和合同校验，单文件合格可提前完成 | [delivery guard](../../lib/features/work_mode/work_artifact_delivery_guard.dart)、[delivery](../../lib/features/work_mode/default_work_task_runner_delivery.dart) | 保留基础校验，但群任务只进入候选送审，不能跳过功能验证和全员认可 |
| 已把成果复制到媒体目录生成消息附件 | [delivery](../../lib/features/work_mode/default_work_task_runner_delivery.dart) `database.copyToMedia` 调用 | 可复用为迭代版本的物理文件基础，补齐版本、证据与签字关联 |
| 现有快照保存操作前后镜像并支持撤销／清理 | [snapshot manifest](../../lib/features/work_mode/work_snapshot_manifest.dart)、[snapshot service](../../lib/features/work_mode/work_snapshot_service.dart) | 回滚快照不能充当必须长期可打开的交付版本 |
| 重启执行任务通常转 interrupted 等用户继续，部分未完成讨论可重新启动 | [recovery](../../lib/features/work_mode/work_task_coordinator_recovery.dart) `_implRestore` | 自动恢复是实质行为改造，必须区分中断、主动暂停、待审批和未知结果 |
| 可重试失败有 30／90 秒退避，单次自动恢复有 120 秒包络 | [coordinator](../../lib/features/work_mode/work_task_coordinator.dart)、[auto resume](../../lib/features/work_mode/work_task_coordinator_auto_resume.dart) | 不删除有限错误重试，但不能把 120 秒变成新群任务总时限 |
| 备份只携带白名单可移植状态，导入也清洗，路径／审批不便携 | [backup codec](../../lib/features/backup/backup_entity_codec_memory.dart)、[rewrite](../../lib/features/backup/restore_plan_rewrite.dart) | v2 的嵌套引用与交付文件需显式适配，不能直接备份整个执行 JSON |

仓库说明有两条需要在实施时更新：`CLAUDE.md` 中“无文件结构校验”和“handoff 全 lib 无 producer”与当前代码不一致。本次没有修改该文件；P8 以最终代码更新事实说明，并保留用户正在进行的其他编辑。

## 2. GitHub 相关项目：借机制，不照搬

这些项目分别覆盖团队编排、软件协作或持久执行，并非每个都是具备相同群聊人格体验的直接竞品。以下区分来源事实和对本项目的设计判断。

### AutoGen：动态选人和停止条件分开

**来源事实：** SelectorGroupChat 可通过模型或 selector/candidate 函数选下一发言者；max_turns 与 termination_condition 是不同参数。终止条件另有消息数、Token、超时、移交等组合能力。[SelectorGroupChat 源码](https://github.com/microsoft/autogen/blob/main/python/packages/autogen-agentchat/src/autogen_agentchat/teams/_group_chat/_selector_group_chat.py)、[官方终止条件说明](https://microsoft.github.io/autogen/dev/user-guide/agentchat-user-guide/tutorial/termination.html)。

**采用：** 下一成员由待解决问题与能力决定，业务完成条件独立于资源／故障条件。

**不照搬：** 不能把出现“APPROVE”或某个成员说结束作为本项目的正式完成证据；用户要求逐成员、逐版本明确认可。框架允许不设轮数，不等于无进展保护可以删除。

### MetaGPT：职责和真实测试动作

**来源事实：** 项目用产品、架构、工程等角色组织软件流程。QaEngineer 源码包含写测试、运行和调试结果的动作路由，并有默认值为 5 的 test_round_allowed 检查。[仓库介绍](https://github.com/FoundationAgents/MetaGPT)、[QaEngineer 源码](https://github.com/FoundationAgents/MetaGPT/blob/main/metagpt/roles/qa_engineer.py)。

**采用：** 软件开发把需求、设计、实现、测试责任和产物联系起来；测试是有实际动作和返回结果的责任。

**不照搬：** 本需求取消固定测试轮次，不直接复制其测试次数上限；角色 SOP 可约束责任，不应让每条群聊都像固定报告。这里不据单个类推断该项目所有工作流的行为。

### ChatDev：讨论、代码评审和修改循环

**来源事实：** 当前主分支为 ChatDev 2.0，经典软件公司工作流位于 chatdev1.0。经典默认配置显式定义需求分析、编码、CodeReviewComment/Modification、TestErrorSummary/Modification 等阶段，代码评审与测试组合阶段分别配置 cycleNum=3。[当前仓库说明](https://github.com/OpenBMB/ChatDev)、[经典默认工作流配置](https://github.com/OpenBMB/ChatDev/blob/chatdev1.0/CompanyConfig/Default/ChatChainConfig.json)。

**采用：** 让评审／测试结果进入修改过程，而非收集完建议即结束。

**不照搬：** 不采用固定阶段发言剧本或固定三轮循环；用户的任务类型不限软件，不能把经典软件流水线机械套给所有产物。本文对经典配置的判断不代表 2.0 的所有能力。

### OpenHands SDK：工作区中的实际执行

**来源事实：** SDK 提供 Agent、Conversation 和文件／终端等工具，支持本地与隔离工作区，并作为 OpenHands 产品的执行基础；当前仓库说明区分 SDK/Agent Server 与前端、自动化仓库的职责。[软件 Agent SDK](https://github.com/OpenHands/software-agent-sdk)。

**采用：** 成员判断应来自对真实工作区的操作，工具和环境能力需要实际可用，不能只有职业标签。

**不照搬：** 本项目已有 Dart 工具／审批／协调器，不为获得该机制引入 Python Agent Server、容器平台或第二运行时。该来源不证明“任意任务可无限自主完成”，也不证明本项目已具备浏览器测试。

### LangGraph：持久中断与恢复输入

**来源事实：** LangGraph 提供持久状态与人工介入能力；interrupt 可把问题交给调用方再恢复。官方说明强调节点恢复会重跑相关逻辑，中断前副作用需幂等或拆离。[GitHub 仓库](https://github.com/langchain-ai/langgraph)、[官方 interrupts 文档](https://docs.langchain.com/oss/python/langgraph/interrupts)。

**采用：** 弹窗是一条持久化决策，不是仅挂在界面上的等待；用户自由建议与恢复动作绑定稳定 ID，并考虑重复提交／重放。

**不照搬：** 不引入该框架替代已有协调器。检查点不能自动提供 exactly-once 保证，本项目仍需核对已发生的副作用。

### 综合结论

最适合本项目的组合是：问题驱动的选人、职责明确的真实行动、带证据的测试返工、可恢复的人类决策、版本绑定的全员认可。**不建议整体迁移到任何一个竞品框架。**

角色长期人格与心情继续复用本项目已有能力。这部分不是从竞品宣传中推导出来的。本文没有通过星数、角色数或文档里的“自主”措辞判断交付质量。

## 3. 对旧设计的明确替换

| 旧规则／行为 | v2 规则 | 必须保留的边界 |
|---|---|---|
| 先讨论收建议，选一个最终执行者 | 调查、分工制作、独立验证、返工与全员认可 | 不虚构角色或资格 |
| 理解 100% 才执行 | 已知问题处置完毕、方案与验收明确且团队认可 | 不在方案未确认时擅自制作 |
| 2/4/6 轮、96 次、100 动作、60 分钟 | 无累计业务截止；按进展继续 | 单次超时、有限错误重试、异常检测与现有费用治理 |
| 执行补充等当前任务结束才处理 | 落盘后到安全检查点增量处理 | 不强杀副作用、不丢输入、独立新任务仍排队 |
| 合格文件生成即完成 | 文件先送审，最终完成有唯一门槛 | 真实格式、指定路径、附件重发 |
| 重启主要由用户手动继续 | 核对后自动恢复安全可运行工作 | 用户暂停／停止、待审批、未知动作不得越过 |
| 每个成员给职责意见 | 相关成员自然对话并实际解决问题 | 内部协议仍需严格校验 |
| 历史文件主要是附件或回滚快照 | 有明确候选迭代、测试与最终认可关联 | 不覆盖原工作路径、不把快照保留策略套给交付文件 |

这些替换不能通过关闭旧测试完成。旧业务断言应改成新规则的测试，旧安全回归测试必须保留，发现旧测试隐藏了必要边界时补充说明。

## 4. 八个串行实施阶段

| 阶段 | 修改目的 | 主要接入点 | 交付与放行证据 |
|---|---|---|---|
| P1 | 一份可迁移的协作状态与门槛 | discussion state/protocol、context、checkpoint、现有类型校验 | 版本绑定、全员认可、损坏状态／旧记录可测；暂不默认启用 |
| P2 | 去掉累计限制而保留可恢复故障保护 | agent loop 的全部预算调用、discussion session、retry、auto_resume、进度展示 | 假时钟跨 60 分钟、超过 100／96 次仍有进展；无进展和单次超时仍拦截 |
| P3 | 用户决策、自由建议、延期与安全点补充 | clarification、follow_up、coordinator、action service、overlay/panel | 双入口幂等、建议恢复、延期收尾再提醒、并发补充不丢失 |
| P4 | 相关团队的自然讨论和实际查证 | role router、discussion model I/O/member/session、唯一 agent loop 的调查模式 | 生产调用链中按问题读代码、简短具体地接话与确认方案；无固定轮次或职业报告模板；真实表达按5.4验收 |
| P5 | 接入真实成员上下文和可追溯经验 | AICharacter、memory selector/observation、work memory runner、生产 prompt | 各成员差异、心情过期、项目隔离、经验去重和旧观察器旁路覆盖 |
| P6 | 每轮文件版本及证据归属 | artifact guard、delivery、media/bundle、snapshot 边界 | 两版均可打开，原文件修订不变，崩溃发布／附件重试正确 |
| P7 | 制作→验证→讨论→修复→认可闭环 | coordinator execution、handoff 兼容、runner result、completion shortcuts | 真调用链跑出失败→修复→复测→全员认可；非软件同样可闭环 |
| P8 | 恢复迁移、备份与最终群入口切换 | restore、queues/locks、backup/import、data lifecycle、UI/说明 | V01–V51 全部有结论；真实验收与未检查项明确，默认群入口启用 |

P1 定义后续阶段的最小必要接口。P2 的异常保护不能拖到无限续跑上线之后补；P6 文件身份成立后，P7 才能实现可信签字与复测。P8 不用新开关掩盖未接线分支，完成后新群任务只走 v2，旧状态通过显式迁移进入它。

每阶段最多增加与真实职责对应的少量类型／文件；具体数量由当前源码规模决定，不把“八个阶段”变成八个新的服务层。

## 5. 贯穿验证与实际验收脚本

### 5.1 自动检查

- 每阶段运行受影响测试，单用例 30 秒上限；模型／工具使用受控替身，检查生产入口、真实状态转移和真实临时文件。
- Hive 或 JsonSerializable 变动：先 `dart run build_runner build --delete-conflicting-outputs`。
- P8 运行 `flutter analyze` 与 `flutter test --timeout 30s`；范围包含工作模式、群输入、记忆、备份、删除与私聊回归。已有失败和本次回归分开归因，但均列出。
- gateway 未修改就不机械运行其测试；若改到搜索代理则补 `cd gateway` 后 `npm test`。
- 不用全文搜索到几个关键词、模型自称完成、只跑纯状态测试，替代真实生产链路验收。

### 5.2 飞行棋端到端验收

1. 在有产品／前端／测试等合格成员、授权临时目录和可用测试环境的群中提出制作本地 HTML 飞行棋。
2. 给出一个确实缺少的玩法规则；验证成员讨论、查证和用户弹窗，再补充规则。
3. 团队确认方案与用例，生成 r001 实际游戏文件，测试发现预置可复现缺陷。
4. 群内出现对应测试证据与问题讨论；前端修复到 r002，测试实际复测并执行相关回归。
5. 验证 r001 与 r002 均可打开，报告不串版。成员签字前改变文件，确认旧签字立即失效。
6. 制造一个未具备能力的验收项；用户输入“该项先放着，其他先做”。确认其未被记为通过，其他工作完成后再次弹窗。
7. 用户补齐条件并完成验证，或明确人工验收／豁免；按真实记录重新审阅后，全体团队认可同一版本并交付。
8. 在上述不同阶段切页面、关闭／重启；用受控崩溃测试覆盖不可依赖手动操作复现的写入窗口。检查无副作用重放和重复附件。

真实测试能力不可用时，记录 V31 的正确阻塞行为；这不等于“飞行棋实际交互验收通过”。

### 5.3 非软件验收

提出生成一份包含来源核查的调研 DOCX，验证需求讨论、实际查证、文档生成、内容／格式审查、问题修订和全员认可；只交付所要求文档，不能因正文涉及软件就自行编程。另用受控集成覆盖设计／数据任务的通用审查规则。

### 5.4 群聊发言质量验收（D18／V49–V51）

在上述实际验收中使用已授权的真实角色和模型配置，保留从提出具体问题到处置结论的连续群聊记录，以及测试发现问题到开发回应、修复和复测的连续记录；不为了样本数量强制追加聊天。标明模型、角色、任务阶段与对应证据，样本脱敏，不读取私人历史。

逐项人工评审设计4.1.1：普通发言是否简短、能否直接回答前文、是否提供具体新增信息、是否重复背景或套模板、职业与人格差异是否自然、协调者是否过度总结。核对必要长解释是否确有信息价值，完整缺陷报告与证据是否可打开，以及异议和逐成员认可是否完整保留。出现不合格发言要指出原句、上下文及原因，修正后复核受影响场景，不能只挑几句好话展示。

自动检查负责生产接线、文本与协议分离、详情入口和状态完整性；长度统计只作诊断，不能证明自然性。fake模型返回预写对话或模型自评通过均不能代替真实体验验收。不新增逐条模型润色／打分服务。没有真实可用环境时将相关项记为未检查，不能声称发言体验已经修好。

## 6. 暂不增加的能力与扩展条件

- 不做退出 App 后的服务器／后台常驻执行；用户已选重新打开后恢复。
- 不做多人并行写工作区；串行职责交接足够，确有性能证据后再考虑并发写隔离。
- 不做通用 DAG 编辑器、投票平台、插件市场、自动创建虚构角色或新模型供应商接入。
- 不默认安装浏览器测试平台；已有可用且授权的能力优先，缺失时使用已确认的用户决策流程。
- 不制作另一套长期记忆数据库；只有现有模型确实无法表达项目作用域时才最小追加字段。
- 不为总费用或交付时间承诺上限；现有用户费用治理继续有效，当前业务选择本身也允许范围持续增长。

以上不缩减用户已确认的闭环、版本、全员认可或角色记忆要求。
