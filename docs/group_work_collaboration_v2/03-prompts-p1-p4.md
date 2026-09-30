# P1–P4：可直接交给 Codex 的实施提示词

每次复制一个阶段的完整代码块。每段都要求读取共同设计，不需要依赖本次聊天记录；先完成上一阶段，再执行下一阶段。P1–P7 不默认切换生产群入口，最终切换在 P8。

## P1 — 协作状态、版本与确定性门槛

~~~text
在当前 chat_group 仓库实现“群聊工作模式 v2”的 P1，仅完成本阶段，不提前做 P2–P8。

先完整阅读：
- CLAUDE.md（全部强制约束）
- docs/group_work_collaboration_v2/README.md（全部已确认决定和实施约束）
- docs/group_work_collaboration_v2/01-design.md
- docs/group_work_collaboration_v2/02-evidence-and-plan.md

目标：
在既有 AgentTask / discussionState / coordinator 体系中建立唯一的、可迁移的协作状态和确定性业务门槛，为真实成员讨论、制作、验收、返工、文件版本和全员认可提供基础。不是新建工作流框架。

先执行 git status --short，记录当前改动，不覆盖或回退。读取相关实现与全部调用者，至少覆盖：
- work_discussion_state.dart 及其 metadata / validation
- work_discussion_protocol.dart、work_context_builder.dart、work_prompt_context_compactor.dart
- AgentTask、WorkHandoffState、工作检查点编解码和 coordinator 的状态写入
- 备份中的 _safeExecutionStateJson / _portableDiscussionState / 嵌套 ID 重写
- work_discussion_state_test、work_discussion_protocol_test、work_task_checkpoint_test
实际路径若变化，用 rg 查真实入口；不要创建同名替代实现掩盖旧入口。

实施要求：
1. 优先将 executionStateJson.discussionState 升为 schema v2；保留 v1 解码与显式转换路径。不得让旧、新状态都能独立推进一个任务。
2. 定义本设计真正需要的最小值对象：团队及职责、需求/团队版本、工作项及依赖、问题/范围提案、验收项、迭代引用、成员认可和用户决策。历史正文与日志只存索引，不塞进根检查点。
3. 方案就绪门槛检查当前已知疑问、明确方案、产物合同、验收项、团队资格和真实认可；理解百分比不再是 v2 门槛。
4. 正式交付门槛校验同一个 task/request/team/iteration/artifact/verification 版本下全体成员的明确认可，以及验收、问题和待处理输入。沉默、空队伍、缺成员、协调者代签不能放行。
5. 明确 defect / idea / decision / deferred / waived 等语义。不允许“继续”自动变成验收通过；有效异议必须处理，新想法须有逐成员一致同意或用户裁决。
6. 状态增量必须验证来源角色、task/conversation 归属和 expectedRevision。过期结果不能覆盖新状态；同一事件重放不重复写入认可或决策。
7. 当前持久状态与提示压缩结果分离。有损摘要不能回写覆盖未决项和最终门槛。
8. 未知/损坏 schema 保留恢复阻塞，不能清成空 Map。根 checkpoint 与子状态版本分别校验；普通聊天/DM 不因多出字段进入新流程。
9. 本阶段新增状态可由受控测试与后续代码使用，暂不让普通生产群任务默认创建 v2，也不在启动时批量迁移用户数据。
10. 涉及备份的新增字段先明确便携白名单与身份引用，不导出执行权限。完整迁移及默认入口切换在 P8完成。
11. 只添加真实需要的类型或小文件；不要引入事件溯源框架、泛型 DAG、额外数据库或单实现工厂。

必要验证：
- 方案未解决问题、假 100%、多数同意、空团队、代签、成员失效均不能放行。
- 需求/团队/产物/验证版本各自变化会使旧认可不再有效。
- 旧 schema、未知 schema、坏 JSON、重复和过期事件、跨任务/跨群结果都安全处理。
- 压缩不会改变权威状态；非群任务保持原行为。
对应设计矩阵：V02、V22、V30、V40、V41，并为 V08 的生产接线保留门槛测试。

运行最小相关现有测试与新增回归，每用例 30 秒。改 Hive/JsonSerializable 后先生成代码，不手改 g.dart。
完成范围内全部质量检查，修复问题后写 docs/group_work_collaboration_v2/implementation/P1.md：
实际数据形状、兼容决定、改动入口、测试命令、通过/失败/未检查项、后续接口。
报告不能声称协作闭环已经上线；本阶段仅提供可验证基础。不要自动提交或推送。
~~~

## P2 — 取消累计限制，同时建立有证据的停滞保护

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P2，仅执行本阶段。

完整阅读 CLAUDE.md，以及 docs/group_work_collaboration_v2/ 下的 README.md、
01-design.md、02-evidence-and-plan.md 和 implementation/P1.md。
先核对 P1 实际接口和测试，检查 git status，不覆盖已有改动。缺少前置实现时说明具体缺口，
不要另写一个状态模型或跳过门槛假装继续。

目标：
v2 群任务取消累计 100 动作、60 分钟、固定讨论轮数和每任务 96 次讨论调用截止；
有可验证进展就自动继续。保持单次调用/命令超时、有限错误重试、取消、检查点、并发和现有费用治理。
不能把上限调大，不能靠反复清零预算实现“无限”，不能把总限制换成隐藏的短恢复时限。

先追踪全部生产调用：
- WorkAgentLoop、work_agent_loop_checkpoint/actions/retry 里的预算计算、检查和消息
- DefaultWorkTaskRunner 对 maxActions/softTimeLimit 的传入
- WorkDiscussionRunner / session / round_completion / summary 的 min/maxRounds 与 maxCalls
- coordinator 的 auto_resume、recovery、execution 及 120 秒自动恢复包络
- 任务面板的 x/100、软限制文案、进度总数和继续入口
- WorkTaskBudgetWait、现有 retry/failure/liveness 与日志保留
查全部调用方，避免只删外层判断但内部仍会暂停。

实施要求：
1. 累计限制的适用性从已校验的 v2 群状态明确推导；普通聊天/DM保持旧行为。
2. 累计动作/时间继续记录，但群流程不再依据它们终止，也不提供误导的完成百分比。
3. 无固定讨论最低轮数和最高轮数。调度可以让出执行权后自动续调，不把调度批次变成用户继续门槛。
4. 在现有故障/重试基础上集中实现有证据的停滞判定：相同失败指纹、重复方案、无问题/证据/验收变化；
   参考设计阈值，命名集中并支持假时钟/受控结果测试。模型自报 substantive_progress 不能单独算进展。
5. 新的相关读代码结果也可能是进展，不能以“没生成文件”误杀调查。空改文件、重复哈希和重复话术不能刷进度。
6. stalled 状态保存最近有效进展、尝试摘要和仍缺什么，交给 P3 决策入口；等待用户时停止空转模型。
7. 将单次超时、重试耗尽、外部费用/速率约束和无进展区分，用户可见信息真实，敏感日志保持脱敏。
8. 审计 autoResumeRoundTimeout：v2 正常续跑/启动恢复不能被固定 120 秒包住整段工作；
   重连探测与单次请求仍有边界。保留取消和自动重试/用户继续身份隔离。
9. 更新输出协议/检查点/进度UI中依赖旧总数的分母。移除总量门槛不能引入除零或无限 widget timer。
10. 本阶段不默认启用生产 v2；新策略必须被 v2 可执行入口消费，不能只留测试中孤立的方法。

必要验证（不真实等待一小时）：
- 假时钟跨过 60 分钟、101+ 动作和97+讨论调用，有进展的群任务仍运行且计数真实。
- 单次无输出、挂起命令、损坏协议、重复失败按其保护终止本次尝试；用户可取消。
- 连续必要读取不误判；换措辞和相同文件内容不能绕过停滞。
- 等待审批不触发停滞；条件变化后的恢复能推进，但重复同输入不无条件抹掉失败证据。
- v2 健康自动续跑跨 120 秒不被误杀；DM仍保持原预算语义。
- 长上下文能压缩且保留未决项，不会随总步数无限增长请求。
对应 V11–V16、V43、V48；涉及讨论调度的完整效果在 P4复核。

优先复用 work_agent_loop_test、work_task_budget_wait_test、work_discussion_runner_test、
work_failure_recovery_test、work_task_coordinator_test 和 compactor 测试。
所有单用例 30 秒上限，必要时用现有假服务，禁止收费模型压力测试。
完整收集并修复本阶段问题，写 implementation/P2.md，明确未默认启用和所有验证限制。
不要自动提交、推送或开始 P3。
~~~

## P3 — 自由建议弹窗、暂缓收尾提醒与执行中补充

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P3，只完成本阶段。

先完整阅读 CLAUDE.md、docs/group_work_collaboration_v2/README.md、01-design.md、
02-evidence-and-plan.md，以及 implementation/P1.md、P2.md。检查 git status，保护现有改动。
特别注意当前仓库正在演进的 follow-up 澄清和 WorkTaskClarification.isAnswerable，不能另起一套真假判断。

目标：
把用户介入做成可持久恢复的任务决策，支持选方案、自由建议、暂缓指定项、明确豁免或人工验收；
用户在执行中补充要求时安全落盘，在下一个安全检查点处理，而不是等整个任务结束。

先读实际调用链：
- WorkTaskClarification、WorkTaskUserAction、WorkTaskActionMessageService
- work_task_coordinator_follow_up_input/follow_up_promotion/discussion_lifecycle/recovery
- work_follow_up_policy.dart 及聊天输入路由
- work_task_panel / controls / actions、work_task_overlay_host 和已有通用审批弹窗
- 当前输入FIFO、附件绑定、会话保留和已删除任务闸门
结合 P1 状态复用能用的入口；业务决策不要假装成命令授权，命令审批也不能因输入一句建议被绕过。

实施要求：
1. 一份 decision 记录驱动聊天、面板、弹窗：taskId、decisionId/revision、原因、依据、选项、影响和答案。
2. 提供可输入自由文本的弹窗，按实际问题给适用按钮。显示选择的代价和仍缺少的条件。
3. 答复先持久化再提示收到。原问题与建议共同用于解释，不能脱离原请求错误分类。
4. 不明答复保留 pending 并说明为何尚未解决；不要把每次未解决都机械弹同一句。
5. “先继续/其他先做”只能使指定项 deferred，不能 pass/waived。没有明确指向且会影响多个事项时做必要澄清。
6. deferred 项不阻止已确认且无依赖的工作；全部其余可完成工作完成时发出新的 remainderReady 提醒，
   自动再次弹窗。多个剩余项可聚合显示，不能因首次问题已提醒而漏掉收尾提醒。
7. 弹窗关闭不算答复。用户主动暂停/停止和仅暂缓某项是不同动作；不要把任务暂停状态当作永久关闭待办。
8. 去重与幂等覆盖聊天/面板同时提交、重复点击、页面重建、App重启和过期按钮；拒绝跨任务/旧版本恢复。
9. 接收执行中的新输入立即持久化消息和附件ID。当前不可分割工具动作完成后在安全点处理，
   保留已经发生的副作用，不强杀写入，不取消旧任务后丢新输入。
10. 需求变化使旧结论/认可失效并重新讨论受影响部分；明确独立新任务仍FIFO排队，询问进度不触发重做。
11. 临交付前原子核对待处理输入，不能最后一条补充输给 completed 竞争。
12. 其他群任务不抢占当前弹窗焦点，保留可达入口；回到对应任务呈现。需补成员时显示候选并由用户确认，
    实际选人与能力核验接 P4，不自动改永久群成员。
13. 建立新状态与 WorkTaskClarification.isAnswerable 的统一解释，保留现有跟进目标选项、拒绝答复提示及清理逻辑。
14. 不使用 initState 的 postFrame→setState 循环、不用 timer 重弹推进；状态由 app 级协调器所有。

必要验证：
- 自由建议解开阻塞与仍未解开两条路径；“继续”不等于豁免；人工结果来源不能伪装自动测试。
- 暂缓→独立工作完成→再次弹窗；跨重启提醒不漏不重复，尚有未决项不能正式完成。
- 双入口/旧按钮/重复答复只生效一次，答案绑定正确 task/revision。
- 连续两条修改携带不同附件，安全点按顺序处理；旧模型返回被拒，已发生文件动作仍留记录。
- 问进度、独立新任务、修改同一文件的语义保持正确；删除任务后迟到答复不复活记录。
对应 V07、V09、V17–V22、V47，并为 P7 的依赖调度提供真实入口。

复用 work_task_clarification_test、work_follow_up_policy_test、work_task_coordinator_test、
work_task_user_action_test、work_task_action_message_service_test、work_task_panel_test 等。
遵守30秒单测与Hive/widget/AppToast规则。不要仅测纯函数而漏实际两个UI入口。
本阶段完成后写 implementation/P3.md，说明所有检查、未检查及如何被 P4/P7消费。
暂不默认开启 v2，不提交/推送，不提前实现后续阶段。
~~~

## P4 — 相关成员自然讨论、真实调查和方案确认

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P4，仅执行本阶段。

完整阅读 CLAUDE.md、本目录 README.md、01-design.md、02-evidence-and-plan.md 和 P1–P3实施记录。
本目录指 docs/group_work_collaboration_v2/。先检查 git status 和真实前置接线，保护用户未提交改动。

目标：
团队以解决问题、查证和确认方案为目的协作；成员使用自己的模型和职责自然交流。
去掉固定职业建议稿、强制轮次、模型理解百分比门槛，让程序员在讨论中能够真正读取相关代码。

优先阅读：
- WorkRoleRouter 全部调用者及 chat_room_agentic_input_support.dart
- WorkDiscussionRunner / session / member_turn / summary_turn / model_io / decisions
- work_discussion_project_dossier.dart、discussion protocol/state
- WorkAgentLoop 的 execute/result 和工具注册、workspace.list/read/search
- 现有角色技能、模型可用性、工具和目录资格核查、治理网关与搜索安全入口

实施要求：
1. 按任务所需能力从当前群选相关团队；成员以自己的AICharacter、模型配置和有效能力参与。
   协调职责由团队内成员兼任，不能一次让一个模型编造所有成员发言。
2. 缺必要角色从已有角色库推荐，经 P3用户确认加入当前任务；未获确认不得调入。
   对指定成员不合格、重复名字、缺API配置、掉线/删除给出可处理原因，不隐式替换或剔除异议人。
3. 区分用户要求实际开发软件与仅写软件需求文档；不得仅根据 HTML/游戏/测试关键词扩展交付对象。
4. 当前问题/工作项驱动发言者和下一动作，不按固定名单轮流发言，不要求所有群成员凑数；
   方案确认和最终认可仍覆盖当前工作团队。
5. 实际生产提示保留内部严格协议，公开输出只显示自然回应、事实、问题和结论；
   移除统一“职责意见”前缀、合同JSON正文、每句理解百分比。不额外加模型改写每条发言。
6. 成员能够直接回应前一人的具体疑问、提出有依据的反对意见，或说明需要调查什么；
   解析失败不以预览文本代替结构化状态或认可。
7. 调查调度复用同一个 WorkAgentLoop 和现有工具入口，不在讨论runner新增独立工具循环。
   每个调查动作绑定任务、成员、问题与需求版本，实际工具结果返回台账后再继续讨论。
8. 只读能力在运行时限制：受控list/read/search和授权资料；任意command.run、安装、写探针不伪装只读。
   搜索继续使用现有策略与生产gateway，浏览器默认能力边界不变。
9. 替换 dossier 中特定样例项目的硬编码推断。概况可以导航，代码判断必须引用真实读到的来源。
10. 所有已知疑问已处置、完整方案/产物合同/验收明确、团队认可才进入ready；
    不为凑轮数继续，不允许模型说100%绕过门槛，不默认先写原型。
11. 新想法有全体成员明确同意即可更新范围、需求/测试/计划；分歧走 P3用户裁决；
    不得覆盖用户明确禁止事项或扩大工具授权。沉默不算同意。
12. 停滞检测使用 P2，旧 min/maxRounds 和96次逻辑不能继续截断 v2。
13. 给 P5保留当前角色上下文的实际接入点，不新造临时记忆系统；给 P7输出可执行工作项与方案，
    但本阶段不把完整制作/测试循环伪造为已经完成。

公开发言质量是核心要求，必须实施 01-design.md 的 4.1.1，不能只加一句“请自然聊天”：
- 普通回复默认一到三个短句，围绕当前一个主要问题，接住上一人的具体疑问，给本轮新增信息；
  不重复背景、完整需求和全盘方案，不统一职业前缀、固定标题、编号或“结论/依据/行动”模板。
- 建议具体且说明必要理由；允许追问、反对、承认不确定和更正，不编造经历或已执行结果。
  不用强塞语气词、表情、玩笑或争吵代替人格；没有新增信息可不说，但不得省略必要答复和认可。
- 协调者仅在收敛、决策、交接时简短总结。完整需求、测试明细、代码和日志进文件/详情，
  气泡给关键发现和真实证据入口；完整问题必须一次收集，不能只保留第一项。
- 例如测试说“掷骰子连点会不会走两次？移动中可能要禁用按钮，我先查这个”，
  开发直接回应具体机制；实际复现后才能说“我复现了”。示例不能变成所有成员固定台词。
- 追踪生产 prompt（包括实际使用的 buildAgentDecisionPrompt）、角色要求、上下文、summary及UI拼接，
  移除冲突的长报告要求。不能只改未调用helper或仅折叠UI；不截前N字、不机械拆泡、
  不降低整个结构化协议的token预算来强行变短，不加逐条第二模型润色或无限风格重试。
- 必要复杂解释可更长，保持完整证据和协议；为P5人格表达、P7测试返工与交付消息复用同一规范。

必要验证：
- 受控模型分别接收不同身份，用真实临时项目执行读取，返回证据并改变实际待决问题状态。
- 明确简单任务不凑两轮，复杂任务超过六轮仍可推进；97次有效调用不会被旧总上限截断。
- 写文件/危险命令在ready前被阶段策略拦截，现有授权不能被角色发言越过。
- 未知玩法需要用户决定；模型100%、伪造他人签字、旧版回复不能开工。
- 相关团队选择、缺人确认、掉线保留责任、指定成员资格、文档任务不误启动开发。
- 新范围全员同意与存在分歧两条路径，旧认可版本失效。
- 覆盖短回复、必要长解释、多缺陷报告、协调总结、直接提问和逐成员确认；公开文本与协议各自完整，
  详情入口真实可达。自然性不能只靠提示词关键词、字数或fake对话判定，真实样本验收见计划5.4。
对应 V01–V07、V10、V12、V46、V49、V51。

复用 discussion runner/protocol/state、role router、workspace file tool、governance和群工作UI集成测试。
增加真实接线验证，不能只断言提示词包含“读代码”或“自然”二字。
所有测试单用例30秒上限，Hive/widget/AppToast操作遵守CLAUDE.md约束。
完成全部范围检查，写 implementation/P4.md，报告固定格式去除、真实调查能力、状态流和未检查项。
不默认切换生产群入口、不提交/推送；下一阶段是P5。
~~~
