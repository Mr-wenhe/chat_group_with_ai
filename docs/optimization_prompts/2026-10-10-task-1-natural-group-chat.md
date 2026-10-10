# 任务 1：当前前台群聊的 AI 自然接话

下面的提示词可完整复制到一个新的 Codex 聊天中执行。本任务对应原 HTML 第 2 项，并包含第 8 项中必要的运行护栏。先完成本任务，再执行任务 2；两者涉及部分相同文件，不建议同时修改。

---

请在 `/Volumes/new_disk/work/flutter/chat_group/chat_group` 实现普通群聊的 AI 自然接话。直接完成实现、相关回归验证和完整自检，交付可审查的改动。本次不需要发布、部署、提交 Git 或创建 PR。

## 先读约束与实际代码

完整阅读仓库 `AGENTS.md` 指向的 `CLAUDE.md`，尤其是关键红线、死循环防护、Review / 校验完整性和代码质量检查清单。先查工作区状态，保留用户已有修改。面向用户的回复使用中文。

产品分析来源是 `docs/github_competitor_analysis_2026-10-10.html`，但其中“现有群聊纯随机”的描述不准确：当前已有 `HumanizedChatOrchestrator`，按点名、最近发言、关系、话题等产生 `ReplyIntent`。应在已有链路上补齐逐次模型选人，不重写一套聊天或工作任务运行时。

GitHub 参考只用于理解机制，不直接搬运实现：

- [Aithos](https://github.com/excing/WebMultiAgentChat)：每次选下一位发言者，也允许结束。
- [SillyTavern 群聊](https://docs.sillytavern.app/usage/core-concepts/groupchats/)：规则选人与角色上下文合并是不同机制；完整合并人设可能导致身份混淆。
- [AutoGen SelectorGroupChat](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/selector-group-chat.html)：候选资格、重复发言限制和结束条件。

先追踪所有调用方、设置读写、取消路径、测试、备份与清理路径，再列出本次实际修改范围。重点核对：

- `lib/features/chat_group/humanized_chat_orchestrator.dart`
- `lib/features/chat_group/chat_room_conversation_support.dart`
- `lib/features/chat_group/chat_room_agentic_round_execution_support.dart`
- `lib/features/chat_group/chat_room_agentic_support.dart`
- `lib/features/chat_group/chat_room_agentic_round_support.dart`
- `lib/features/chat_group/chat_room_message_context_support.dart`
- `lib/features/chat_group/chat_room_page_state.dart`
- `lib/features/chat_group/chat_room_page_lifecycle_support.dart`
- `lib/features/chat_group/conversation_controller.dart`
- `lib/features/chat_group/auto_chat_scheduler.dart`
- `lib/features/chat_group/reply_eligibility_policy.dart`
- `lib/features/chat_group/group_mute_store.dart`
- `lib/features/settings/`、`lib/features/settings/providers/api_config_providers.dart`
- `lib/features/ai_governance/ai_request_gateway.dart`、`ai_request_guard.dart`
- `lib/core/storage/api_credential_resolver.dart`
- `lib/features/agentic/context_window_manager.dart`
- `lib/main.dart` 中的导航与路由，以及现有在场状态服务
- `lib/features/backup/`、`lib/core/database/data_lifecycle_*`

## 已确认的产品行为

用户主要需要日常陪伴：角色按最新内容自然接话，有自己的身份、语气和关系表现。质量优先，可以接受每条 AI 发言前最多一次额外选人调用。

1. 所有普通群统一默认使用 AI 自然接话，不要求逐群开启或逐群配置选择器。
2. 全局设置中只需选择一个已有 `ApiConfig` 供选择器使用。选择器是幕后选人步骤，不是群成员，不产生聊天气泡。
3. 每个角色的实际发言继续使用该角色绑定的 API 配置。不要覆盖角色配置，也不要复制或要求新增 API Key。
4. 只有当前群聊页面实际可见、App 处于前台、且符合既有自动聊天策略时，才允许选人和自动发言。
5. 切换到另一群、退出群聊、打开覆盖聊天的其他页面、App 进入后台、页面释放或用户点停止时，旧群停止触发新请求。已有请求尽力取消，迟到响应不得启动下一位、重新启动计时器或向旧群补发消息。
6. 保留当前成员公开简介：姓名、身份、性格等。首版不增加完整 APPEND，不拼接其他成员整份 `rolePlaySystemPrompt`、私聊或私有记忆。
7. 工作模式任务仍由既有协调器管理，其跨页面执行行为不在本任务的停止范围。私聊维持原选人规则。圆桌会议既有全员讨论与共享搜索规则保留；群自动发言仍受前台、可见性约束。

## 选择器与回合

- 每一步都先根据当前真实状态过滤候选：当前群成员、启用状态、API 配置与凭据可用性、频率限制、禁言、点名例外、正在生成状态和共享群主客身份。
- 客人客户端不调用选择器或角色模型；共享群的 AI 生成继续只由主人端负责。
- 明确点名优先使用既有点名规则。选择器的结束决定不能吞掉仍待处理且有资格的明确点名；超限、停止和资格失败仍是硬约束。
- 没有候选时不调用模型；只有一个确定候选或明确点名即可决定时，可直接选人，省去无意义调用。
- 对其他情况，每次选人都读取最新已确认的对话。上一位回复完成后再决定下一位，不在用户发送时一次锁定整轮名单。
- 候选必须覆盖全部符合资格的成员。现有评分可辅助选人和兜底，但不要只暴露原编排器的前三名，导致其他成员永远没有被模型选择的机会。
- 使用稳定角色 ID，不能用名字当主键；重名角色仍须可区分。
- 最小响应协议可用 `{"speakerId":"候选角色ID"}` 与 `{"speakerId":null}`，后者表示结束。严格校验类型、候选归属和响应大小，不执行任何模型返回的指令。
- 保留、复用现有 `ReplyIntent` 的动作、对象、语气、长度和关系规则。最终意图必须对应实际选中的角色，并针对其可见的最新对话；不要仅换发言人，却继续套用另一角色的意图。
- 默认避免同一角色连续抢话；仅一个候选、有效点名等合理例外按已有规则处理。
- 回合必须有界。保留现有普通用户回合最多 3 条、点名回合当前 2 条、空闲单轮最多 2 条及 burst/cooldown 规则；以实际代码为准核对这些值。不得把旧的三轮变量直接当成“每轮再生成三条”，造成回复上限倍增。
- 选择器返回结束时正常结束当前回合。空闲场景进入既有等待或冷却，不立即重新请求同一段对话；新的用户输入可以开始新回合。

## 模型、预算与失败路径

- 复用 `ApiCredentialResolver` / `CredentialRepository`、`AiRequestGateway`、模型能力表、账本和窗口预算。不要直接绕过网关调用 `ChatApiService` 或新建 HTTP 客户端。
- 优先使用已有带响应体上限的非流式网关方法，避免先解码无界响应。选择器需要短 JSON，不需要流式显示或工具能力。
- 每一步最多一次实际选择请求，关闭网关内部自动重试；本任务不增加 JSON 修复调用或第二次“再选一次”。
- 可采用集中常量作为初始保护值：估算输入上限 2048 token、输出上限 128 token、响应体上限 16 KiB、整次选择时限 15 秒；均需被所选模型的实际能力上限进一步约束。这些是工程起点，不能宣称经过真实模型调优。不要新增一组用户必须填写的高级参数。
- 请求总时限不能仅依赖不断被重置的 receive timeout；超时同时取消对应请求。所有等待之后重新校验可见群、App 状态、回合有效性和成员资格。
- 手动用户回合与空闲自动回合分别沿用对应的预算用途，保证选择器费用也计入同一会话与自动聊天预算。若增加新的用途枚举，必须完整检查账本、策略、展示和兼容调用方，不能绕过自动聊天开关或预算。
- 价格未知时沿用已有提示并记录真实 usage，不声称金额上限可被精确执行；仍用请求大小和调用次数限制控制风险。
- 未选择全局配置、引用配置被删除、凭据缺失、超时、断网、空响应、非法 JSON 或返回不存在的角色时，使用现有本地编排器完成该步，且不反复请求选择器。
- 用户停止、页面隐藏、App 后台、权限/资格失效或硬预算阻塞时，应结束；这些情况不能通过“失败兜底”绕过约束继续发言。
- 取消或失败要释放本轮运行标记、计时器和预算预留。只处理本任务的普通聊天状态，不删除已有消息或工作任务。
- 维持每个用户回合复用一个搜索上下文的行为；动态改变发言人不得造成每人重复搜索，空闲自动聊天仍不得擅自发起搜索。

## 前台与可见性是硬验收条件

当前实现的 `_pageActive` 主要来自 Widget 的 `activate` / `deactivate`，`_handleAppLifecycleState` 主要处理 `resumed`。不要把 Widget 仍 mounted 当作“用户正在看这个群”，也不要假设 push 新路由必然触发 Widget deactivate。

采用符合现有导航结构的最小修复，分别判断路由可见性与 App 生命周期。补齐离页、进入后台、返回前台和返回当前路由的对称行为；只有当前可见群满足全部条件时才恢复调度。暂停期间不能积累一批计时器，恢复时不能补跑多个过期回合。

选人、回复及由该回合新触发的摘要/压缩请求，在发出前均应检查允许条件。已经发出的上游请求不保证撤销计费，但本地不得采纳失效结果或继续生成。

## 隐私与数据兼容

- 选择器只读取当前群允许共同使用的历史、群背景和公开成员资料。不得直接传全部 `_messages`，不得从其他群、私聊或观察者私有记忆补充上下文。
- 复用 `visibleToCharacterIds` 的可见性判据。若采用共同可见历史，应是候选可见范围的交集；最终角色请求仍按该角色的可见范围过滤。
- 全局设置仅持久化已有 API 配置的本机引用，不保存明文 Key、凭据对象、完整配置副本或私有正文；不要把 Key 写入 `app_settings`。
- 遵守 `CLAUDE.md` 的导出/备份字段红线。新增选择器的设备配置引用不写进可分享数据，恢复后需要重新选择本机配置；不要为了方便迁移输出 `apiKey` / `apiProvider` / `apiConfigId`。既有备份实现与文字约束如有冲突，明确记录，不能在本任务中擅自扩散该行为或重写整个备份系统。
- 新配置引用须覆盖 API 配置删除、替换、恢复、损坏值和数据清理：不可留下会误绑另一配置的引用，不可因缺失引用反复报错或调用模型。
- 如新增需要随备份携带的非凭据设置，检查 `backup_setting_keys.dart`、配置范围、会话选择、恢复 ID 改写和生命周期清理。不要给所有设置机械新增备份规则。
- 不更改既有 Hive 字段编号或复用 typeId。只有确实改动 Hive/JSON 模型时，才运行要求的代码生成并提交相关生成文件。

## 验收与测试

使用隔离 Hive 和可控假模型，不读取真实 `data/*.hive`、不使用真实 Key，不用真实网络验证来代替回归测试。为新分支与取消逻辑添加少量有效测试，复用现有 helpers。

至少覆盖这些行为：

1. 新旧普通群使用同一个全局选择器配置；实际发言仍用各角色自己的配置。
2. 两个重名角色按 ID 正确选择；第 4 位及之后的合格成员也可以被选择。
3. 第一位发言后，下一次选择输入包含最新合法回复，返回结束后不再调用。
4. 点名、禁言例外、无资格成员、小时限额与仅一个候选遵守既有策略。
5. 超时、非法响应、配置失效只产生一次选择请求并有限兜底；预算阻塞或取消不兜底发言。
6. 用户停止、导航到其他页、A 群切 B 群、App 后台、页面 dispose 均停止旧群；迟到选择/流式响应不会落入旧回合，也不会唤醒计时器。
7. 返回前台但旧群仍被路由遮挡时，旧群不恢复；回到当前群后只恢复一个调度器。
8. 用户正在输入、工作模式、共享群客人身份时，不启动空闲模型调用。
9. 每轮调用次数、回复数、输入/输出窗口和预算预留受限；不能以“5 个角色”为未经证明的固定阈值。
10. 隐藏历史、私聊和私有记忆不进入选择器；搜索快照仍按用户回合复用。
11. 新设置的保存、读取、删除/替换引用、恢复和清理行为可预测，新增导出内容无禁止字段或密钥。

优先复用 `test/humanized_chat_orchestrator_test.dart`、`test/group_mute_orchestration_test.dart`、`test/conversation_controller_test.dart`、`test/chat_room_page_lifecycle_test.dart`、`test/auto_chat_scheduler_test.dart`、`test/chat_activity_policy_test.dart`、`test/chat_room_memory_prompt_test.dart` 及相关预算、备份和实时群测试。

遵守单用例 30 秒上限和仓库 pump、AppToast、Hive 写入隔离约束。先跑实际受影响测试及静态分析；更改公共共享代码时再扩大到对应调用方回归，不能只跑新测试就宣称完成。

最终交付说明：具体行为变化、修改文件、已执行命令与结果、全部发现和处理结果、剩余未验证项。尤其区分“假模型验证通过”和“真实提供商的自然度、延迟、费用尚待体验”。按 `CLAUDE.md` 的代码质量清单逐项自检，不为该功能新增无关抽象、依赖或后台服务。
