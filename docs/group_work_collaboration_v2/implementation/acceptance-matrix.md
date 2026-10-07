# P8 完整验收矩阵

日期：2026-10-01。范围在实施前确定为 README D01–D18 和设计 V01–V51；下表不缩减范围。**整体结论：未完成完整验收，不可据此宣布可发布。**

“自动通过”仅指所列断言及受控生产接线；fake gateway / fake command / fake pandoc 不证明真实模型、软件交互或网络来源通过。手工栏区分代码/规格核对与真正 App 操作，后者没有授权隔离模型配置，未检查。即使表内某项确定性门槛通过，也不扩大为真实任务验收通过。

## 自动证据索引

所有测试均由 P8 记录中的全量 `flutter test --concurrency 2 --timeout 30s --reporter expanded` 覆盖；P8.md 保存命令、结果与开发失败归因。

| 编号 | 测试文件（相对仓库根）与证据范围 |
| --- | --- |
| A | `test/work_mode/work_collaboration_state_test.dart`：真实全员/身份失效/deferred/显式迁移/压缩门槛 |
| B | `test/work_mode/work_discussion_v2_test.dart`：1及97次调查、选择/缺人、范围分歧、实际gateway形状（受控模型） |
| C | `test/work_mode/default_work_task_runner_stage02_test.dart` 的 `part_p7`：`P7 actual coordinator/default loop … failure repair retest signatures delivery` 各正负场景，含 P8 startup 和 portable-import |
| E | `test/work_mode/work_task_execution_policy_test.dart`、`work_agent_loop_test.dart`：累计/单次限制与进展 |
| F | `test/work_mode/default_work_task_runner_stage02_test.dart` 的 `part_p8`：启动、后置条件、收据、不确定命令、等待/终态、成员/未知schema、v1迁移 |
| G | `test/work_mode/default_work_task_runner_stage02_test.dart`、`work_discussion_runner_test.dart`：真实runner策略、单次模型期限及兼容 |
| H | `test/work_mode/work_task_coordinator_test.dart`、`work_task_panel_test.dart`：FIFO、延期、用户建议、锁/并发、审批幂等、删除/迟到回调 |
| I | `test/work_mode/work_candidate_publication_test.dart`、stage02 `part_p6`：实际冻结文件、缺失/篡改/半途失败/重发、公开报告跨平台路径清洗 |
| J | `test/backup_restore_service_test.dart`（含 `part_03` 与 `part_p6`）：双侧清洗、嵌套新ID、附件/版本/报告、缺文件、配置范围 |
| K | `test/data_lifecycle_service_test.dart`：数据清除/实体删除/关联媒体与设置 |
| L | `test/work_mode/work_agent_loop_test.dart`、`work_task_event_store_test.dart`：副作用后收据前崩溃、持久提交、迟到写/逐ID删除闸门 |
| M | `test/work_mode/work_mode_memory_runner_test.dart`（含 `part_p5`）、`test/observation_entry_test.dart`：边界/人格/经验/失败幂等 |
| N | `test/work_mode/work_mode_chat_ui_integration_test.dart`、`work_mode_s8_end_to_end_test.dart`、`work_discussion_v2_panel_test.dart`、`work_document_tool_test.dart`：新入口/DM、受控DOCX闭环、有界分页、面板 |

## V01–V51

实现文件省略共同前缀 `lib/features/work_mode/`；backup、main、memory、data lifecycle 文件采用其实际目录。手工未检查项的原因见 P8.md 的实际验收记录。

| 项 | 规格场景与预期 | 实现入口 | 自动证据/结果 | 手工证据/结果及原因 | 结论 |
| --- | --- | --- | --- | --- | --- |
| V01 | 简单方案一次讨论已明确；复杂方案超过六轮；不凑轮数、不按轮数终止，按真实门槛推进 | `work_discussion_v2_session.dart / work_discussion_v2_approvals.dart` | B：1/97 次实际工具读取、方案逐人认可；通过 | 真实复杂任务的自主轮次未检查 | 未检查（实际验收）；自动子项通过 |
| V02 | 模型说 100% 或 coordinator 单独说全员同意；不能替代问题证据、方案认可或成员签字 | `work_collaboration_state_gate.dart / work_discussion_v2_protocol.dart` | A：百分比、代签、他人签字拒绝；B：旧协议拒绝；通过 | 状态与协议审查已检查 | 通过（确定性自动范围） |
| V03 | 已知玩法疑问未解决就请求写游戏；拒绝提前制作；允许授权的代码查证 | `work_discussion_investigation.dart / work_agent_loop_actions.dart` | B：ready 前 mutation 不进入 handler；通过 | 真实飞行棋规则缺口未检查 | 未检查（实际验收）；自动子项通过 |
| V04 | 程序员讨论中读源码并报告修改位置；实际工具执行、证据进入讨论，非虚构 dossier | `work_discussion_investigation.dart` | B：实际受控文件读取进入成员讨论，gateway 配置逐员接线；通过 | 真实模型源码查证未检查 | 未检查（实际验收）；自动子项通过 |
| V05 | 调查请求写文件、安装或任意命令；阶段权限与已有审批在运行时生效 | `work_agent_loop_actions.dart / work_task_coordinator_decisions.dart` | B：伪装只读命令仍拒绝；H：审批、路径与安装边界；通过 | 真实工具审批 UI 未检查 | 未检查（实际验收）；自动子项通过 |
| V06 | 相关成员发言与闲置成员；不强制全群凑数；每人用自己的身份和配置 | `work_discussion_v2_team.dart / work_discussion_runner_model_io.dart` | B：相关团队选择、逐成员 gateway 配置；通过 | 真实闲置成员与表达未检查 | 未检查（实际验收）；自动子项通过 |
| V07 | 缺测试／成员掉线／明确指定者不合格；用户确认补人或人工承担，不偷换／代签 | `work_discussion_v2_team.dart / default_work_task_runner_production.dart` | B：缺人确认、删除、不合格角色、配置缺失；C：manual-no-tester；通过 | 桌面补人操作未检查 | 未检查（实际验收）；自动子项通过 |
| V08 | 多数赞成但一名当前团队成员有异议；正式交付仍被阻止 | `work_collaboration_state_gate.dart / work_discussion_v2_approvals.dart` | A：真实全员门槛；C：逐员 delivery approval；通过 | 真实异议讨论未检查 | 未检查（实际验收）；自动子项通过 |
| V09 | 纯偏好、有效缺陷、异议有效性有争议；分别形成提案、返工、用户裁决，不丢意见 | `work_task_coordinator_decisions.dart / work_discussion_v2_actions.dart` | A：idea/deferred 不是豁免；B：分歧 adopt 双分支；C：缺陷返工；通过 | 真实异议有效性对话未检查 | 未检查（实际验收）；自动子项通过 |
| V10 | 全员同意新功能；有人反对；违反用户禁止项；分别自动更新范围、弹窗裁决、请求用户改变明确约束 | `work_discussion_v2_actions.dart / work_collaboration_state_updates.dart` | B：新范围同意/反对/用户裁决及旧认可失效；通过 | 用户禁止事项实际对话未检查 | 未检查（实际验收）；自动子项通过 |
| V11 | 群任务超过 100 动作与 60 分钟仍有进展；自动继续，累计计数不被清零伪装，检查点有效 | `work_task_execution_policy.dart / work_agent_loop.dart` | E：有效群 v2 累计限制豁免，DM 不豁免；通过 | 真实连续 60 分钟未检查；未伪造实耗时 | 未检查（实际验收）；自动子项通过 |
| V12 | 讨论超过 96 次有效调用；不因旧调用总额截止，仍受异常与上下文保护 | `work_discussion_v2_session.dart / work_task_execution_policy.dart` | B：97 次读取后仍推进；E：读取进展与重复证据区分；通过 | 真实超过 96 次模型调用未检查 | 未检查（实际验收）；自动子项通过 |
| V13 | 同一失败反复重试；多轮无新增事实；有限异常尝试后呈现阻塞与证据，用户建议可恢复 | `work_agent_loop_retry.dart / work_task_coordinator_auto_resume.dart` | E/H：重复失败无进展保护、网络自动阶梯、手动清标记；通过 | 真实网络故障未检查 | 未检查（实际验收）；自动子项通过 |
| V14 | 有相关读取进展但尚无产物；不误判死循环；模型自称进展而无依据不能重置保护 | `work_task_execution_policy.dart / work_discussion_v2_session.dart` | E：97 次新读取仍有进展，重复证据不能重置；通过 | 静态及受控进展测试已检查 | 通过（确定性自动范围） |
| V15 | 单次无首字节、命令挂起、协议反复损坏；单次超时／有限重试有效，归因可区分 | `work_model_deadline.dart / work_command_runner.dart` | G：首字节/总请求时限；H：命令超时与失败归因；通过 | 真实模型慢流未检查 | 未检查（实际验收）；自动子项通过 |
| V16 | 自动恢复后健康执行超过 120 秒；不被旧自动恢复整轮 deadline 错杀 | `work_task_coordinator_execution.dart / work_task_execution_policy.dart` | F：将自动整轮 deadline 缩为 10 ms，健康恢复 40 ms 后仍运行；G：startup 闭环；通过 | 真实健康恢复超过 120 秒未检查；缩时测试只证明策略 | 未检查（实际验收）；自动子项通过 |
| V17 | 弹窗自由建议、重复提交、过期按钮；建议落盘后处理，双入口幂等且绑定正确版本 | `work_task_coordinator_decisions.dart / presentation/work_task_decision_dialog.dart` | H：重复审批、建议落盘、过期版本拒绝；面板 widget 测试；通过 | 真实双入口弹窗未检查 | 未检查（实际验收）；自动子项通过 |
| V18 | “先继续”且还有独立工作；指定项 deferred，独立工作继续，不记 pass／waived | `work_task_decision.dart / default_work_task_runner_production.dart` | A：deferred 非 pass/waived；C：deferred 阻止交付；通过 | 真实独立工作推进未检查 | 未检查（实际验收）；自动子项通过 |
| V19 | 其他工作做完，仍有暂缓项；收尾再次弹窗，跨页面／重启不漏不刷屏 | `work_task_user_action.dart / work_task_action_message_service.dart` | H：延期收尾提醒、通知幂等；F：启动保留 waiting 状态；通过 | 真实退出重开后收尾弹窗未检查 | 未检查（实际验收）；自动子项通过 |
| V20 | 用户明确豁免／人工测试；准确来源与风险记录，重新核对新基线，不伪造工具证据 | `work_task_coordinator_decisions.dart / default_work_task_runner_candidates.dart` | C：manual/waiver/manual-no-tester；候选按内容重新绑定；通过 | 真实用户人工测试操作未检查 | 未检查（实际验收）；自动子项通过 |
| V21 | 执行中连续补充且带附件；全部顺序落盘，在安全点生效，不取消丢请求 | `work_task_coordinator_follow_up_input.dart / default_work_task_runner_attachments.dart` | H：两个 attachment-bound FIFO 补充；F：迁移保留队列；J：新 ID 附件关联；通过 | 真实输入/重启混合时序未检查 | 未检查（实际验收）；自动子项通过 |
| V22 | 新版请求到达时旧模型／工具返回；旧结论不覆盖新版，真实已发生副作用仍记录 | `work_task_coordinator_execution.dart / work_agent_loop_checkpoint.dart` | H：迟到版本输入与完成竞争；L：副作用先落意图；通过 | 受控时序已检查；真实进程中止未检查 | 未检查（实际验收）；自动子项通过 |
| V23 | 同名修订及同时写脚本、素材；原目标覆盖，其他文件不被误钉定到目标 | `default_work_task_runner_attachments.dart / work_task_coordinator_follow_up_input.dart` | G/H：修订目标/新交付分类、工作区附件与产物路径；C：实际修复版本；通过 | 同名脚本与素材联合真实任务未检查 | 未检查（实际验收）；自动子项通过 |
| V24 | 人格、职业与心情不同；当前成员上下文真实不同，过期心情 neutral，质量标准相同 | `work_discussion_member_turn.dart / default_work_task_runner_context.dart` | M：成员人格/职业/关系上下文接线，过期心情；B：独立配置；通过 | 真实角色表达未检查 | 未检查（实际验收）；自动子项通过 |
| V25 | 同项目经验、跨项目事实、通用经验；项目事实隔离，通用已验证经验可复用且有来源 | `work_mode_memory_runner.dart / memory_context_selector.dart` | M：项目事实隔离、有来源通用经验复用；通过 | 静态与隔离测试已检查 | 通过（确定性自动范围） |
| V26 | 旧观察器收到工作聊天／未验证猜想；不泄漏项目事实进全局、不将猜想永久固化 | `observation_entry_work.dart / observation_entry_triggers.dart` | M：工作聊天跳过旧观察器，未验证经验不固化；通过 | 静态与隔离测试已检查 | 通过（确定性自动范围） |
| V27 | 记忆归纳失败或恢复重复写；不阻断合格交付、不产生重复经验 | `work_mode_memory_runner.dart / default_work_task_runner_production_delivery.dart` | M/C：失败不阻断交付、重复经验幂等；通过 | 真实重启归纳失败未检查 | 未检查（实际验收）；自动子项通过 |
| V28 | 第一版失败、第二版修复；两版实际文件均能打开，报告分别绑定对应内容 | `work_candidate_publication.dart / work_candidate_evidence.dart` | I：r001 failure 与 r002 repair 不同冻结字节及报告；C：生产闭环；通过 | 真实飞行棋两版打开/操作未检查 | 未检查（实际验收）；自动子项通过 |
| V29 | 复制半途失败／重启重发；不发布半成品候选、不生成假迭代，不重新执行制作 | `work_candidate_publication.dart / default_work_task_runner_candidates.dart` | I：复制失败不发布、恢复出版索引、重发同一候选；C：delivery-failure；通过 | 静态与故障注入已检查 | 通过（确定性自动范围） |
| V30 | 文件哈希或需求／团队版本变化；旧签字不能放行当前版本 | `work_collaboration_state_gate.dart / work_candidate_evidence.dart` | A：四类身份变化失效；I：manifest mutation；C：old-evidence/content-change 子场景；通过 | 静态与身份测试已检查 | 通过（确定性自动范围） |
| V31 | HTML 仅结构通过、没有浏览器能力；不称运行测试通过，出现可处理阻塞 | `default_work_task_runner_review.dart / work_tool_registry.dart` | C：缺能力/关键验收不放行；实际 registry 未注册 browser.context；通过 | 未运行飞行棋浏览器交互；正确阻塞不等于游戏测试通过 | 通过（缺能力阻塞）；交互未检查 |
| V32 | 测试失败、修复后受影响回归；真正 QA→讨论→开发→复测，不能写完文件就 completed | `default_work_task_runner_production.dart / default_work_task_runner_review.dart` | C：software/retest-failure 实际文件、fake 模型/命令的 QA→开发→复测；通过 | 真实飞行棋返工回归未检查 | 未检查（实际验收）；自动子项通过 |
| V33 | 退出码 0 但未覆盖关键验收项；验收仍不满足，不能靠全员口头同意绕过 | `work_candidate_evidence.dart / work_collaboration_state_gate.dart` | C：uncovered/invalid tool receipts 等负向场景，不能口头 completed；通过 | 真实测试用例覆盖审查未检查 | 未检查（实际验收）；自动子项通过 |
| V34 | 修改测试删掉失败断言／修改验收标准；变更可审查，不能偷改成绿；必要时重开方案讨论 | `work_discussion_v2_actions.dart / work_candidate_evidence.dart` | C：变更验收/测试身份后阻止旧证据，A：需求变化失效；通过 | 真实删断言行为评审未检查 | 未检查（实际验收）；自动子项通过 |
| V35 | 测试代码运行后改变被测文件；内容身份校验失败，不能沿用原候选证据 | `work_candidate_evidence.dart / default_work_task_runner_review.dart` | I：测试修改被测文件导致 invalidated；C：content-change 候选拒绝；通过 | 静态与文件篡改测试已检查 | 通过（确定性自动范围） |
| V36 | 全员认可最终版但附件发送失败；验收状态保留，显示投递失败，可幂等重发 | `default_work_task_runner_candidates.dart / work_task_coordinator_recovery.dart` | I/C：投递失败状态、幂等 message ID、重发无新制作；通过 | 真实附件发送故障未检查 | 未检查（实际验收）；自动子项通过 |
| V37 | 切换页面／群；正常退出／进程中止；App 运行中继续；重启核对后自动恢复安全动作 | `main.dart / work_task_overlay_host.dart / providers/work_task_providers.dart / work_task_coordinator_startup_recovery.dart` | F：重复 restore 幂等、cancel dispose；C：startup 恢复闭环；N：App host widget 接线；通过 | 真实切页面/正常退出/kill 后重开未检查 | 未检查（实际验收）；自动子项通过 |
| V38 | 待用户／主动暂停／停止／删除后重启；不自动越过决策，不复活停止／删除任务 | `work_task_coordinator_startup_recovery.dart / work_task_coordinator_recovery.dart` | F：paused/approval/interrupted/cancelled/completed 不调用模型；H：删除迟到 runner；L：删除闸门；通过 | 真实系统进程终止组合未检查 | 未检查（实际验收）；自动子项通过 |
| V39 | 副作用完成但结果写入前崩溃；不盲重放，按实际证据恢复或请求处理 | `work_agent_loop_actions.dart / default_work_task_runner_recovery.dart / work_task_event_store.dart` | L：真实文件已写、receipt 前中止，重开不重放；F：后置 SHA 匹配/不匹配、command 无法证明、设备收据重开；通过 | 真实 OS kill 窗口未检查；不承诺普遍 exactly-once | 未检查（实际验收）；自动子项通过 |
| V40 | 旧任务、未知字段／版本、损坏状态；可解释迁移／阻塞，旧完成记录不伪造签字 | `work_mode_v1_migrator.dart / work_task_coordinator_startup_recovery.dart` | F：legacy 100% 保留产物/FIFO、无签字、显式继续；G/H：未知 schema 原文阻塞；迁移重开测试；通过 | 真实旧用户任务未读取，迁移桌面操作未检查 | 未检查（实际验收）；自动子项通过 |
| V41 | 压缩、检查点、备份导入和新 ID 恢复；未决项保全，引用正确，审批／路径不越界携带 | `backup_entity_codec_memory.dart / restore_plan_rewrite.dart / restore_plan.dart` | J：双侧 portable 清洗、全量/会话备份、copyWithNewIds 嵌套字段、FIFO附件重写、相对合同文件/摘要保留、unverified；A：compact 保留门槛；通过 | 实体活动引用已检查；冻结历史文件保留原来源 ID/摘要，不作为执行引用；真实跨设备未检查；原任务显式继续、旧方案归档、重新绑定/制作、r008/r009返工重测及新签字受控链路通过 | 未检查（实际跨设备）；自动子项通过 |
| V42 | 回滚快照清理、任务删除、明确清理附件；历史交付按自身生命周期处理，用户产物不被误删 | `data_lifecycle_service_deletion.dart / managed_media_store.dart / work_task_event_store.dart` | K/L/H：任务/会话/角色清理、保留已生成文件、逐 ID 解除 tombstone；通过 | 真实磁盘保留策略长周期未检查 | 未检查（实际验收）；自动子项通过 |
| V43 | 普通聊天、DM、其他群任务；隔离不回归，DM 不取消既有累计限制／不引入团队 | `chat_room_agentic_input_support.dart / work_task_execution_policy.dart` | N：新群 v2、DM 目录授权及执行；全量普通聊天/DM 回归；E：DM 仍有限制；通过 | 真实普通聊天与 DM 手工回归未检查 | 未检查（实际验收）；自动子项通过 |
| V44 | 多任务资源竞争、取消和重复启动；单会话所有权、资源锁、并发上限仍正确 | `work_task_coordinator_scheduling.dart / work_task_coordinator_discussion_lifecycle.dart / work_resource_lock_manager.dart` | H：同会话 FIFO、锁、两槽；新增 P8 讨论/执行共用槽；C：lock；F：重复 restore；通过 | 真实多群资源竞争未检查 | 未检查（实际验收）；自动子项通过 |
| V45 | 文档、调研、设计任务；使用专业审查闭环，不硬套开发角色或伪造证据 | `default_work_task_runner_review.dart / work_document_tool.dart` | C：document 专业审查；N：长 DOCX 实体生成、完整分页正文、独立审查与逐员签字；通过 | 真实含来源核查调研 DOCX 未检查；当前网络来源能力阻塞 | 未检查（实际验收）；自动子项通过 |
| V46 | 只要游戏需求文档而非游戏；交付真实指定文档，不凭关键词擅自开发软件 | `work_role_router.dart / work_discussion_v2_team.dart` | B：文档内 HTML 游戏测试不扩大交付；N：Word 产品文档闭环；通过 | 真实仅文档请求未检查 | 未检查（实际验收）；自动子项通过 |
| V47 | 临交付到达的新输入；完成入口检测到待纳入输入，不抢先 completed | `work_task_coordinator_execution.dart / default_work_task_runner_production_delivery.dart` | C/H：完成前待纳入输入/arrivingInputCounts，旧结果不抢先完成；通过 | 真实交付临界输入未检查 | 未检查（实际验收）；自动子项通过 |
| V48 | 长上下文与大量历史版本；有界模型上下文和检查点索引，不截掉必要门槛信息 | `work_agent_loop_checkpoint.dart / work_collaboration_state.dart / default_work_task_runner_context.dart` | A/E/G：compact 与有界上下文；长 DOCX 每页至多4 chunks；64索引/128动作缓存超限保守阻塞；通过 | 任意长真实任务未检查；容量上限不是无限留存 | 未检查（实际验收）；自动子项通过 |
| V49 | 连续讨论中的建议、追问、反对与查证反馈；普通发言简短、接话具体且有新增信息，不轮流复述背景或输出职业报告；真实模型样本按 4.1.1 评审 | `work_discussion_member_turn.dart / work_public_update_stream.dart` | B：实际生产 gateway 形状、协议分离/详情保存；预写模型仅证明接线；通过 | 5.4 连续真实讨论样本缺失 | 未检查（实际验收）；自动子项通过 |
| V50 | 不同性格／职业成员及协调总结；有自然的关注点与表达差异，不编经历、不强塞情绪；协调者不逐条长总结或代答 | `work_discussion_runner_model_io.dart / default_work_task_runner_context.dart` | B/M：逐人配置与人格上下文、非职业模板提示；通过 | 5.4 真实人格差异及协调表达缺失 | 未检查（实际验收）；自动子项通过 |
| V51 | 多缺陷报告、必要长解释、修订交接和最终认可；气泡简明但完整问题与证据可查，不截断协议、不丢异议或逐人认可；闭环各阶段沿用发言规范 | `work_discussion_v2_protocol.dart / presentation/work_task_panel_details.dart / default_work_task_runner_review.dart` | B/N：长解释完整详情可查；C/I：缺陷/修订/报告/逐人认可保留；通过 | 5.4 真实讨论及测试返工连续样本缺失 | 未检查（实际验收）；自动子项通过 |

## D01–D18

| 项 | 用户决策 | 实现入口 | 自动证据/结果 | 手工证据/结果及原因 | 结论 |
| --- | --- | --- | --- | --- | --- |
| D01 | 开工前确认完整方案；解决当前所有已知疑问后才正式制作；允许先读取资料查证，不默认先做原型。执行中新发现的问题回到讨论。 | 见 V01、V03、V04 实现入口 | B：对应子项通过，详见 V01、V03、V04 | 见 V01、V03、V04；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D02 | 团队自主决定开工；根据方案、问题清单和验收标准决定；用户偏好、范围取舍分歧或团队无法解决的问题才找用户。 | 见 V02、V07、V09 实现入口 | A；B：对应子项通过，详见 V02、V07、V09 | 见 V02、V07、V09；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D03 | 全员认可后交付；当前工作团队每位成员必须明确认可，不能改成负责人独自批准或多数票。 | 见 V08、V30 实现入口 | A：对应子项通过，详见 V08、V30 | 见 V08、V30；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D04 | 异议必须有依据；关联目标、需求或质量要求，并给出具体问题、依据和可验证的解决条件；无法统一的新想法弹窗裁决。 | 见 V09、V32、V51 实现入口 | A；C；B/N：对应子项通过，详见 V09、V32、V51 | 见 V09、V32、V51；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D05 | 一致同意的新想法可加入；即使超出原有范围，只要工作团队一致同意，也可纳入并更新需求、测试和计划；不得覆盖用户明确禁止事项或新增工具授权。 | 见 V10 实现入口 | B：对应子项通过，详见 V10 | 见 V10；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D06 | 取消群任务累计限制；取消累计 100 步与任务总时长限制；持续有进展就继续，反复失败、持续无进展或无法解决的阻塞才求助。 | 见 V11、V12、V13、V14、V15、V16 实现入口 | E；B；E/H；G；F：对应子项通过，详见 V11、V12、V13、V14、V15、V16 | 见 V11、V12、V13、V14、V15、V16；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D07 | 弹窗可输入建议；用户可以解释、纠正、提供替代方案，团队收到后继续；不能只有重试／停止按钮。 | 见 V17 实现入口 | H：对应子项通过，详见 V17 | 见 V17；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D08 | 暂缓后继续，最后再提醒；用户让某项先放着时，保留待办并推进不依赖的工作；其他工作完成后再次弹窗，不能把“继续”视为豁免或验收通过。 | 见 V18、V19、V20 实现入口 | A；H；C：对应子项通过，详见 V18、V19、V20 | 见 V18、V19、V20；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D09 | 只选相关成员参与；从当前群选择相关工作团队；其他成员可补充意见，不强制凑数发言或承担签字责任。 | 见 V06、V07 实现入口 | B：对应子项通过，详见 V06、V07 | 见 V06、V07；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D10 | 所有任务；软件有必经流程；文档、调研、设计等使用对应审查；软件交付必须经过完整开发测试闭环。 | 见 V31、V32、V33、V34、V35、V45、V46 实现入口 | C；I；B：对应子项通过，详见 V31、V32、V33、V34、V35、V45、V46 | 见 V31、V32、V33、V34、V35、V45、V46；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D11 | 人格影响表达与关注点；性格、职业、心情、关系可以影响措辞和讨论习惯，不能降低职责、事实或验收标准。 | 见 V24、V50 实现入口 | M；B/M：对应子项通过，详见 V24、V50 | 见 V24、V50；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D12 | 每轮保留交付版本；每轮送测／修订留存可打开的文件版本，关联修改说明、测试结果和未决问题；最终标记验收通过版本。 | 见 V28、V29、V30、V36 实现入口 | I；A；I/C：对应子项通过，详见 V28、V29、V30、V36 | 见 V28、V29、V30、V36；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D13 | 经验可跨项目复用；已验证通用经验和稳定用户偏好可跨项目；项目事实保持项目边界，历史经验不等于本次证据。 | 见 V25、V26、V27 实现入口 | M；M/C：对应子项通过，详见 V25、V26、V27 | 见 V25、V26、V27；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D14 | 执行中及时纳入补充；即时确认收到，在安全检查点处理；必要时回到讨论并更新实现和测试，保留成果、不丢输入。 | 见 V21、V22、V47 实现入口 | H；C/H：对应子项通过，详见 V21、V22、V47 | 见 V21、V22、V47；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D15 | 本地持久执行；切群／切页面继续；退出 App 后不继续生成，下次打开核对现场后自动恢复可执行工作。 | 见 V16、V37、V38、V39、V44 实现入口 | F；L；H：对应子项通过，详见 V16、V37、V38、V39、V44 | 见 V16、V37、V38、V39、V44；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D16 | 缺角色由用户确认补充；从已有角色库推荐，由用户确认加入本次任务；无合适人选时用户补角色或承担对应验收。 | 见 V07 实现入口 | B：对应子项通过，详见 V07 | 见 V07；真实闭环/样本未检查 | 未检查（完整实际验收） |
| D17 | 交付实施提示词；给 Codex 等开发工具的分阶段仓库改造提示词，不单独交付一套产品运行时角色提示词。 | `03-prompts-p1-p4.md` / `04-prompts-p5-p8.md` / implementation | 不适用（文档交付） | 已检查分阶段实施记录，无替代设计 | 通过 |
| D18 | 发言必须像真实同事讨论；简短、具体、接住他人的问题，有角色差异；消除冗长职业报告和重复背景。覆盖讨论与测试返工全过程，以连续真实群聊样本验收，不能只隐藏长文本。 | 见 V49、V50、V51 实现入口 | B；B/M；B/N：对应子项通过，详见 V49、V50、V51 | 见 V49、V50、V51；真实闭环/样本未检查 | 未检查（完整实际验收） |

## 未解决/关键未检查项

1. V31/V32/V37/V44：生产 `browser.context` 无 runtime 注册；macOS/Chrome 可用不能等同 App 有受控浏览器测试能力。未执行真实飞行棋、页面切换/重开和实际并发试验。
2. V45/D10：受控 DOCX 的真实文件/解析/分页审查通过；模型与 Pandoc 测试进程受控。专业审查未接入网络来源核验，未执行含来源核查的真实调研 DOCX。
3. D18/V49–V51：未获得合法专用真实角色模型配置，未采集连续讨论及测试返工样本；不做“像真人”结论。
4. V39/V41：故障注入覆盖代表性窗口，未执行真实 OS kill 或第二设备导入。机器可执行引用按新 ID 改写；冻结历史文档内原来源 ID/签字按原字节保留，仅作历史，不作为当前授权。
5. V48：有界索引达到容量会阻塞，不静默丢弃未决项；未测试任意长任务与所有磁盘/系统故障组合。

6. **V41 实现缺口已修复**：portable-unbound 原任务显式继续后精确重绑定、归档旧方案、重新制作/核对并取得新认可；旧签字、答案和人工豁免不授权新环境，延期与补充保留。自动证据见 `acceptance-import-final.log`、`acceptance-affected.log` 和 `acceptance-boundary.log`；真实第二设备仍未检查。

Continuation automated verification: 2984 tests passed; analyze clean. Matrix remains 51 V rows and 18 D rows. Real environment gaps retain unchecked status. See P8 section 10 and P8-verification.md for command hashes.
