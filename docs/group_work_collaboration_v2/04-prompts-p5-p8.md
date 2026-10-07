# P5–P8：可直接交给 Codex 的实施提示词

先完成 [P1–P4](03-prompts-p1-p4.md)。每次复制以下一个阶段的完整代码块；每段均要求读取设计及前置实施记录。

## P5 — 成员人格、心情与可追溯工作记忆

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P5，仅完成本阶段。

完整阅读 CLAUDE.md、docs/group_work_collaboration_v2/README.md、01-design.md、
02-evidence-and-plan.md 及 implementation/P1.md 至 P4.md。
先检查 git status 和前置真实接线，不覆盖已有修改，不读 data 中真实私人对话或凭据。

目标：
讨论、调查、制作与审查都使用当前成员自己的职业、性格、有效心情、关系及相关记忆。
工作经验可跨任务复用，但具体项目事实不能进入其他项目，未验证猜想不能沉淀为事实。

先读：
- AICharacter.rolePlaySystemPrompt、personalityTags、旧 memorySummary 的兼容规则
- MemoryContextSelector、PermanentMemory、ObservationEntry 及其 triggers/distillation/retry
- RelationshipState.effectiveMood()、相关可见性和遗忘/审计逻辑
- work_mode_memory_runner.dart 的所有调用者
- P4真实讨论/调查入口与 DefaultWorkTaskRunner 的执行提示入口
- chat_room_message_context_support.dart 的现有工作消息观察路径
- 工作区身份/目录重绑定、WorkContextBoundary、备份及数据清理中的记忆处理

实施要求：
1. 复用当前统一记忆与人物配置，不新增第二套人格/长期记忆服务，不把已弃用memorySummary重新当权威。
2. 在生产提示构建时以当前 actor 选择个人上下文；角色切换不能沿用上一个人的记忆或关系。
3. 查询有效心情必须用effectiveMood，过期心情回到neutral；自定义设定和情绪不能覆盖用户要求、
   事实、权限或验收标准。
4. 给讨论、调查、执行、审查使用一致的有限上下文入口；检查runWithUnifiedMemory是否真正被调用。
   不允许只修改未使用wrapper或仅在测试注入记忆。
5. 按现有工作区能力确定稳定projectScopeId；切换到另一项目不能继承旧项目事实。
   没有适用持久标识时最小追加可空字段并迁移，不用路径字符串猜相同项目就跨群共享。
6. 项目专有事实优先留在该scope的任务/文件/证据上下文；通用已验证经验和用户稳定偏好进入
   成员自己的PermanentMemory，保留可追溯来源及去重身份。
7. 审计旧ObservationEntry接收工作聊天的路径，避免它另把项目规则/猜测抽取成全局事实。
   必要的来源/作用域扩展必须覆盖所有写入者、查询者、备份、审计、遗忘与删除。
8. 严格遵守观察者/主体/消息可见性；未参与成员不获得“亲身工作经验”，协调者不能替所有人写相同经历。
9. 工作阶段验证结果有变化时，旧经验要被更正或标记适用条件，不能保留已推翻的结论当事实。
10. 归纳失败只影响记忆写入，不使已合格任务失败；重试/重启不重复写入，记录可重试状态。
11. 记忆内容作为数据，不是系统权限。低相关历史按预算排除，不能挤掉当前目标、未决项与证据。
12. 项目检索必须尊重删除任务推进的上下文分界线，不能换条检索通道捞回已排除历史。
13. 若改Hive模型先生成g.dart，旧记录缺新增字段有安全默认；修改共享selector不能回归普通群聊/DM。
14. 遵守设计4.1.1：人格通过措辞和关注点自然体现，不每句自报职业，不注入无关生活记忆，
    不强塞情绪表演或编造经历。不同成员可以语气不同，但都要简短接话、给出具体判断。

必要验证：
- 两个角色收到各自不同且真实的相关记忆/性格，关系/心情过期与未过期表现正确。
- 项目A事实不进项目B；已验证通用经验可复用，但不被说成B已验证事实。
- pinned或明确记忆不会绕过主体可见性和作用域；不存在的经历不会被包装成记忆。
- 旧观察器不旁路项目隔离；归纳失败、重复事件、重启去重正确。
- 记忆更正、审计、遗忘、备份/导入和任务删除后的上下文边界不回归。
- 通过P4生产讨论和实际执行适配器验证注入，不只测helper。
对应V24–V27、V50，并覆盖V41的记忆部分；真实表达质量在P8按计划5.4验收。

优先复用 work_mode_memory_runner_test、memory_context_selector_test、observation_entry_test、
chat_room_memory_prompt_test、relationship_state_mood_ttl_test 及相应备份/生命周期测试。
所有用例30秒限制，不调用真实收费模型验证人格。
完整检查后写 implementation/P5.md，说明写入/读取链路与项目作用域具体实现，
列出通过/失败/未检查项。暂不默认开启v2，不提交/推送，不提前执行P6。
~~~

## P6 — 候选交付版本、证据文件与可靠重发

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P6，仅完成本阶段。

先完整阅读 CLAUDE.md、docs/group_work_collaboration_v2/README.md、01-design.md、
02-evidence-and-plan.md 和 implementation/P1.md 至 P5.md。
检查 git status，保留正在进行的修改。先查复用，不新增Git服务或另一套文件仓储。

目标：
每次送测有真实可打开的候选文件版本，修复生成下一版，测试/异议/签字能绑定确切内容。
工作文件仍在用户原路径修订；回滚快照与交付版本具有不同用途和保留周期。

至少追踪：
- DefaultWorkTaskRunner 的 delivery、artifact selection/bundle、media copy和消息发送
- WorkArtifactDeliveryGuard、artifact notice/confirmation、artifact path history
- _completeValidatedSingleArtifactTask 等自动完成捷径及所有调用者
- WorkSnapshotService/Manifest的撤销与清理
- WorkModeDirectoryService、workspace mutation/path policy、修订钉定
- 现有附件备份/导入、任务/群/附件的数据生命周期

实施要求：
1. 复用筛选、格式校验、打包和copyToMedia，增加 iterationId / candidate manifest / 证据索引，
   不再靠单一lastArtifactPaths或“文件已存在”代表一轮交付。
2. 候选内容冻结，记录真实文件相对路径、尺寸/哈希、需求/团队版本和制作者。
   后续工作文件变化不影响旧候选打开；新修复生成下一iteration。
3. 本轮测试/审查报告按attempt追加为新记录；候选内容不可覆盖，outcome在结论齐全后一次封存。
   不允许一边声称版本不可变，一边不断改同一manifest中的已经签字内容。
4. publication采用staging、校验、原子发布与持久索引，崩溃可恢复；相同发布重试幂等。
   缺文件/复制失败/空间不足不能生成“完整候选”状态。
5. 用户指定原文件仍按原路径覆盖更新；同名修订钉定不能波及脚本、素材、分段源文件。
   版本目录是另外保存的交付副本，不能偷改用户输出位置或把每次修订原文件自动重命名。
6. 交付包只收合同所需文件，过滤凭据和无关缓存。软件候选须完整可打开或按明确基线可重建，
   不把散落差异文件当完整可运行游戏。
7. 保留现有真实DOCX/HTML等结构检查，但群v2制作成功只产生候选；为P7提供工作项完成信号，
   不让single artifact捷径提前把整个任务completed。
8. 测试/签字用真实artifactDigest与版本绑定；外部修改候选或被测工作区必须被检测并使证据失效。
9. 消息区区分候选送测、本轮审查报告和最终交付。首次送测就有文件可打开，不等待最终成功才有附件。
10. 附件投递失败独立于验收结论，重发同一封存版本，保留原发送者，不重跑制作或重复新增迭代。
11. 回滚快照的自动清理不删除交付版本。删除任务遵守现有真删除但保留已生成文件；
    明确清理附件/版本走数据生命周期，不遗留可执行任务或孤儿索引。
12. 接入现有完整/会话备份的附件通道，声明可移植元数据与嵌套引用；配置备份不带交付历史。
    导入仍需核验，不搬运旧机器权限；P8补跨设备最终验证。
13. 包体/磁盘保护继续存在，达到限制给出可处理失败而不是静默覆盖历史、遗漏合同文件。

必要验证：
- r001失败后修r002，两版的真实文件都能打开且内容不同，报告和哈希不串版。
- 文件被外部改动、复制中断、发布后索引写失败、重复恢复，不发布假完整版本或重复版本号。
- 原目标同名修订和同时生成脚本/素材互不覆盖。
- 假DOCX/空正文/陈旧文件/缺必要游戏素材不能成为候选。
- 附件失败后幂等重发不重新执行，原发送角色正确。
- 快照清理不删候选；任务删除不复活也不误删用户文件；备份只带便携且允许的内容。
对应V23、V28–V30、V35、V36、V42及V41文件部分。

复用 delivery guard、artifact history、default runner stage02、snapshot、workspace mutation、
backup/data lifecycle测试；允许用临时小文件测试真实复制/打开/哈希，避免巨量模拟文件。
每用例30秒，完整检查后写 implementation/P6.md，说明文件与metadata原子边界和故障恢复。
暂不默认切换生产群入口，不提交/推送，不提前开始P7。
~~~

## P7 — 实际制作、测试、返工和全员认可闭环

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P7，仅完成本阶段。

完整阅读 CLAUDE.md、docs/group_work_collaboration_v2/README.md、01-design.md、
02-evidence-and-plan.md 和 implementation/P1.md 至 P6.md。
检查前置能力真接通，记录git状态，保护未提交改动。不要只删除旧handoff的early return就宣布完成。

目标：
同一个群任务能完成“方案确认→按职责制作→候选送测→实际验证→问题回到群聊→修订→复测→
当前团队逐人认可→正式交付”。软件必须经过完整链路，其他任务走对应专业审查。

先追踪整个生产闭环：
- WorkTaskCoordinator submission/scheduling/execution/discussion/recovery
- WorkRoleRouter / WorkHandoffState 的规划、持久化、推进与消息身份
- WorkAgentLoopResult、DefaultWorkTaskRunner的execute返回及所有completed赋值/发送点
- artifact单文件完成捷径、final response、附件notice重发
- 当前角色的模型/凭据/技能/记忆注入和资源锁获取释放
- P1门槛、P2异常保护、P3用户决策、P4调查、P5人格记忆和P6文件版本

实施要求：
1. 一根AgentTask贯穿整个用户目标，复用唯一WorkAgentLoop执行不同成员工作项，不造另一执行引擎。
2. 区分当前工作项完成与整个任务完成；阶段转换不能先对外发布completed再改回running。
   主动查全部完成捷径，群v2只有一个最终完成入口。
3. 从P4就绪方案派发必要需求/技术/测试材料与实现工作；职责可兼任但测试审查者独立于本轮主要实现者，
   缺能力走P3/D16，不发明新角色或让同一模型伪装另一人签字。
4. 当前actor切换时更新模型配置、凭据解析、职责、记忆、技能与阶段工具权限。
   coordinator/负责人身份不等于所有阶段执行人，不能让上一角色投递下一角色结果。
5. 转移工作项前落盘结果、下一责任与交接依据，释放/重取必要锁，保留会话所有权和并发上限。
   旧handoff作为兼容输入或只读投影，不与v2状态各自推进。
6. 对工具幂等键审计task/stage/workItem/iteration/requestRevision：
   同动作重试不重放副作用，但下一轮合法修复不能被上一轮committed key误判为已经执行。
7. 使用P6候选文件进行验证，记录方法、执行者、版本、运行结果和证据文件。
   HTML能打开/标签完整不是交互测试通过，退出码0也不代表所有验收项已覆盖。
8. 真实浏览器/测试命令不可用时准确阻塞，优先现有已授权能力；需要新增安装/访问照常走审批。
   用户自由建议、人工验收、明确豁免及暂缓通过P3处理，不捏造自动证据。
9. 缺陷带复现/预期/实际/关联验收进入讨论，解决方案明确后派发修复；修复创建新候选并实际复测、
   检查相关回归。不得仅把“建议修改”写进聊天就结束。
10. 修改测试断言、验收标准或范围也要可审查；不能靠删除失败用例把结果刷绿。
    新想法全员同意时更新范围/用例/计划；分歧由用户裁决。
11. 其他可完成工作耗尽且有deferred项时触发收尾再提醒；不永久搁置，也不自动完成。
12. 从每位团队成员独立请求对当前候选与验证基线的明确认可，绑定版本。
    一票异议阻止正式交付；请求失败、沉默、协调者概括不算认可。
13. 所有有效异议解决或明确处置，验收通过或显式豁免、全员认可且没有待纳入用户输入，才正式完成。
    候选内容/需求/团队/验证变化使旧签字失效。
14. 交付投递失败只重发已封存文件，不开启新开发轮；日志/消息真实标明验收与投递状态。
15. 非软件任务用同一问题/证据/审查/返工机制，文档检查正文与格式，调研检查来源；
    不强行给所有任务塞程序员、编译和浏览器。
16. 工作群聊天呈现真实成员交接与问题回应，面板呈现详细状态，不能只有后台跑完的一句“大家已完成”。
    调查反馈、测试异议、修订交接和最终认可均遵守设计4.1.1：气泡短而具体，详细报告可打开，
    不重复全文或每次写职业总结，不为简短丢弃任何已发现问题、证据或逐成员认可。

必要受控端到端验证：
- 实际生产调用链：方案确认→写临时HTML r001→验证工具返回明确缺陷→群讨论→修r002→复测→
  所有真实角色响应认可→交付；中途没有completed提前事件。
- 一人拒签、假代签、成员失效、内容被改、旧测试结果、临交付新输入都不能完成。
- 新范围一致通过与分歧弹窗；暂缓项最后再次提醒。
- 测试工具缺失、工具失败、修改断言、复测失败再返工、取消/锁竞争、消息投递失败均有闭环。
- 文档或调研任务通过专业审查闭环；只要求软件需求文档时不擅自开发软件。
对应V08–V10、V18–V20、V28、V30–V36、V44–V47、V51。

优先扩展work_task_coordinator_test、default runner、work_mode_s8_end_to_end、
work_mode_chat_ui_integration_test等现有受控设施，不复制另一个“理想流程”测试runner替代真实接线。
每个测试用例30秒；此阶段的受控通过不宣称真实浏览器/真实LLM已验收。
完成全范围检查后写implementation/P7.md，列明每条完成路径和复测证据。
仍不默认切换生产群入口；最终迁移、恢复和启用由P8完成。不要提交/推送。
~~~

## P8 — 安全自动恢复、迁移备份、生产切换与完整验收

~~~text
在当前 chat_group 仓库实现群聊工作模式 v2 的 P8，这是最后一个阶段。

先完整阅读CLAUDE.md、docs/group_work_collaboration_v2/README.md、01-design.md、
02-evidence-and-plan.md、implementation/P1.md至P7.md。
校验前置实现真实存在且关键测试通过，检查git status，保护所有用户改动。
以01-design.md的V01–V51和README的D01–D18为完整验收范围，先列出范围再动手。

目标：
新群任务默认使用完整v2；旧任务安全迁移；切页面继续、退出App后停止、重新打开核对后自动恢复；
备份、ID重写、删除、权限、普通聊天和DM全部兼容。不能以测试通过替代完整验收。

必须追踪：
- coordinator restore/recovery/auto_resume/scheduling/execution/deletion
- App级WorkTaskOverlayHost和providers/work_task_providers.dart的初始化与dispose
- queues、conversation reservations、resource locks、approval fingerprints、committed actions
- checkpoint/context compaction、未知schema、旧discussionState和handoff
- backup_entity_codec_memory.dart、backup文件收集/导入、restore_plan_rewrite.dart
- data lifecycle、setting keys、WorkContextBoundary、媒体与版本清理
- 聊天输入、任务面板以及所有新群任务创建入口；不要只改一个入口

实施要求：
1. 同设备重启核对角色/文件/版本/工具收据/权限后自动恢复安全可运行工作。
   待用户/待审批仍等待；主动暂停、停止、已完成、已删除任务不自动执行。
2. 进程可能在副作用发生后、提交收据前结束。对uncertain操作检查真实后置条件；
   无法证明时求助，不能盲重放外部调用、安装、删除或写入。不要宣称普遍exactly-once。
3. 自动启动恢复与有限网络错误重试分开；健康v2恢复不得被旧120秒整轮deadline杀掉，
   也不能把自动标记泄漏到用户手动继续。
4. 恢复重新获取必要资源锁，遵守单会话所有权和App并发上限；没有可运行工作时释放运行槽。
   任务保留、输入FIFO、延期提醒、角色身份和版本索引都必须恢复。
5. v1已完成任务保留历史，不伪造签字。v1未完成任务保留产物与补充，
   显式转换/核对后继续；旧100%不算新方案/验收确认，未知schema不能降为空状态。
6. 新群任务所有创建入口启用v2；旧群任务通过迁移进入。DM和普通聊天仍走原行为。
   不留下两个可竞争执行循环；清理已经被新路径取代且确无调用者的旧格式/门槛分支。
7. 备份保持现有导入导出双侧清洗：公开需求/版本/报告索引可以便携，绝对路径、审批、
   资源锁、可信本地工具收据不可携带为新机器可执行权限。
8. 完整/会话备份含范围内的版本文件和关联报告；配置备份不带任务历史。
   缺物理文件明确记录不完整，不能只备份索引却展示可打开历史。
9. copyWithNewIds重写嵌套task/conversation/character/message等引用，项目作用域重新绑定；
   导入历史认可只作为历史，当前执行仍需新环境核对，不能旧签字跨内容或角色生效。
10. 所有新增设置键若需备份，遵守CLAUDE列出的backup keys、conversation scope、ID rewrite、
    data lifecycle全部入口；优先不要为已有状态另造重复设置。
11. 删除任务后的迟到runner/模型/弹窗/记忆/版本写回不复活任务；保留已生成交付文件。
    数据清除和备份恢复只解除符合条件的删除闸门，不清空全部保护集合。
12. 模型上下文与根checkpoint保持有界索引，长任务不无限增长prompt，未决项/延期/认可身份不丢失。
13. UI显示当前阶段、待决事项、本轮文件、验证和逐成员认可，不再显示误导的x/100、
    “理解100%”完成门槛或群累计到时需继续按钮；保留真实单次故障提示。
14. 更新CLAUDE事实说明和必要用户说明，修正结构校验/handoff旧描述，并说明新群任务流程；
    不在AGENTS.md复制权威约束，不覆盖CLAUDE里无关的已有修改。
15. 不增后台常驻服务、不自动安装新平台、不引入竞品SDK，不扩大发布/推送权限。

测试与验收：
- 为V01–V51逐项填写实现入口、自动证据、手工证据、通过/失败/未检查和原因。
- 完成有代表性的崩溃窗口测试、版本/消息重发、队列补充、延期收尾提醒和跨设备导入测试。
- 复用并运行受影响测试后，执行flutter analyze与flutter test --timeout 30s。
- 模型/Hive变动先dart run build_runner build --delete-conflicting-outputs，不能手改生成文件。
- 若搜索gateway有改动再运行gateway的npm test，没改不机械追加。
- 按02-evidence-and-plan.md执行软件飞行棋闭环和非软件文档闭环的实际验收，
  使用合法现有测试配置/授权临时目录，不读私人历史或自行泄露凭据。
- 缺真实模型/浏览器/工具环境时明确未检查；受控fake通过只证明编排，不证明实际软件已测通过。
- 按计划5.4保留连续真实群聊样本，评审短而具体的接话、角色差异、非模板表达和完整证据；
  覆盖讨论及测试返工交接，不能挑几句好话、只数长度或只凭模型自评宣布“像真人”。
- 单用例超过30秒按仓库规则终止并报告，继续其他不依赖该失败的检查。
- 全范围审查需求、正确性、边界失败、测试有效性、安全、性能、可读性、架构和新老兼容；
  收集全部问题后修复/集中报告，不见第一个错误就结束。

输出：
- implementation/P8.md：生产切换、恢复迁移、兼容处理、真实命令与全部检查结果。
- implementation/acceptance-matrix.md：D01–D18、V01–V51逐项证据，不写无证据的“全部通过”。
- 说明未解决问题及影响。尚有阻塞或关键未检查时，不宣称验收通过/可发布。
完成已授权实施与必要修复，不自动提交、推送或发布；不要转而生成另一份替代设计。
~~~
