# 最新 DEBUG 现场验收矩阵

RUN_ID：acceptance-20261015T101325Z。场景定义以 docs/autonomous_group_work/11-independent-acceptance-prompt.md 为准。本矩阵统计的是产品现场验收，不把源码、单测、P0 样本或验收者本人操作冒充 AI 成员使用。

## 状态与证据

- blocked：现场流程所需模型、数据隔离证明或系统能力不可用；没有据此判定产品实现失败。
- partial：只有局部工具、渲染、代码或包验证证据，完整产品场景未成立。
- not_run：未实际执行该负例/流程；相关代码检查不能提升为现场通过。
- E1：当前代码回归：重点 Flutter 301 通过/1 跳过；Appium 所有权/原生断言 8/8；输出 token 协议 11/11；输出预留 5/5；Gateway 32/32；分析无问题。细节见 commands.log。
- E2：当前仓库 DEBUG .app build、签名验证、真实 bundle archive 5/5，以及 CUA 可见 DEBUG 窗口。窗口配置来源未确认，不能作为数据隔离证据。
- E3：前一验收轮生成的合成 DOCX/PDF 渲染及字体负例证据，仅证明本机 renderer 局部工作，未由 AI 成员使用。
- B1：获准的合成任务对 SenseNova 出现 4 次 300 秒无输出和后续重试，usage=0、无候选/交付文件；真实群内讨论没有继续到成员使用。
- B2：本轮 GUI 显示 1 条已保存 API 配置（Key 遮罩）；运行 PID/实际 Hive 打开路径未捕获，故本轮 GUI 数据隔离未证实。没有点击测试/编辑/删除/发送。
- B3：前次系统检查记录 Automation Mode disabled 且需认证、DevToolsSecurity disabled、Appium 未安装；未提权、未绕过。
- T1–T4：第三轮代码复审问题的当前回归代码/重点测试；是代码级旁证，不替代对应现场用例。

结果合计：45 blocked、7 partial、25 not_run、0 passed、0 failed（77 项）。

## 需求 R01–R16

| ID | 场景 | 结果 | 证据 | 未覆盖 / 原因 |
|---|---|---|---|---|
| R01 | 只发布一次后自主完成讨论、制作、逐人试用、返工和交付 | blocked | B1 | 请求未得到模型输出，未形成首版产物。 |
| R02 | 软件与文档共用工作模式且各自真实完成闭环 | blocked | B1、E3 | renderer 单测/样本不等于群内文档闭环。 |
| R03 | macOS App 优先并作为真实产物测试 | blocked | E2、B1 | 当前 DEBUG 可构建/启动，但没有群任务制作与使用。 |
| R04 | 每个 AI 成员独立使用当前产物 | blocked | B1 | 没有成员模型请求和可信使用收据。 |
| R05 | 不同角色按职责使用不同测试场景 | blocked | B1 | 没有真实试用团队/场景分配。 |
| R06 | 回复有人物风格、自然接话、依据和真实分歧 | blocked | B1 | 没有真实讨论 transcript。 |
| R07 | 每轮仅一位制作/修改执行者 | blocked | B1 | 没有进入制作阶段。 |
| R08 | 自动选人与用户指定执行者规则正确 | blocked | B1、T1 | 路由与断言回归有代码测试，无现场委派。 |
| R09 | 普通方案自主裁决，必要时才问用户 | blocked | B1 | 无真实讨论可统计询问次数。 |
| R10 | 每轮都有可用产物、版本和报告 | blocked | B1 | 本轮没有工作模式生成的产物。 |
| R11 | 门禁满足后自主交付 | blocked | B1 | 无候选、逐人收据或正式交付事件。 |
| R12 | 不设累计预算并准确显示真实总用量 | blocked | B1、E1 | 代码协议/用量回归通过，但没有可核对的真实 provider usage。 |
| R13 | 暂停、停止、继续与无进展空转行为正确 | blocked | B1、B3、T1 | 暂停持久化代码回归通过；没有活动现场任务及桌面会话。 |
| R14 | GitHub 技能真实导入、群/私聊复用并沉淀成功方法 | blocked | B1 | 没有真实群/私聊任务中的远端技能试用。 |
| R15 | 视觉使用前核验模型能力和图像实际送达 | blocked | B1 | 无视觉角色配置、图像探针或模型图像请求。 |
| R16 | 可见窗口真实操作且可暂停、恢复 | blocked | B2、B3 | CUA 只观察 DEBUG 设置页；生产 native.app 路线未操作。 |

## 软件场景 A01–A30

| ID | 场景 | 结果 | 证据 | 未覆盖 / 原因 |
|---|---|---|---|---|
| A01 | 一次发布完成真实 macOS 软件全流程 | blocked | B1 | SenseNova 未返回内容；没有可试用 App。 |
| A02 | 明确指定执行者后保持用户钉定 | blocked | B1、T1 | 没有群讨论或制作人派发。 |
| A03 | 缺模型/视觉/SDK/权限时说明阻塞并可原任务续接 | blocked | B1、B2 | 当前没有在经证明隔离的数据根中触发该状态机。 |
| A04 | 普通成员分歧由协调者自主裁决 | blocked | B1 | 无真实分歧记录。 |
| A05 | 仅目标冲突/授权不足时询问用户 | blocked | B1 | 无对话轮次，不能统计询问必要性。 |
| A06 | 只有一名成员使用时拒绝完成 | blocked | B1 | 未建立候选或完成门禁。 |
| A07 | 每位成员在自己的模型会话中操作独立场景 | blocked | B1 | 没有成员级模型/工具调用。 |
| A08 | 替换参与人/场景/receiptId 被拒绝 | not_run | E1 | 未构造现场收据伪造用例。 |
| A09 | 测试 JSON/伪造截图不能通过正式门禁 | not_run | E1 | 未触发产品交付门禁。 |
| A10 | 候选变化后旧认可和收据失效 | not_run | T1 | 未形成可变更的候选版本。 |
| A11 | 损坏或缺执行文件的 App 不得交付 | not_run | E2 | 当前有效包验收通过；损坏包产品流程未运行。 |
| A12 | 同 bundleId 旧 App 不冒充当前新版本 | partial | E2 | 当前 bundleId、版本和哈希已核对；未启动受控旧版制造冲突。 |
| A13 | 产品 App 缺陷发现、修复、重启持久化和成员回归 | partial | E2 | 确认当前 DEBUG 启动；没有群角色操作 App 或验证支出业务规则。 |
| A14 | Flutter 无 identifier 控件按生产 selector 操作或阻塞 | blocked | B3 | AppKit/AX 树与生产 native tool 未做 GUI 实操。 |
| A15 | 并发群任务与用户切焦点时桌面锁正确 | not_run | B3 | 无原生 session 或两个活动任务。 |
| A16 | 文档问题能定位、修订、重渲染并复核 | partial | E3 | 有本机真实渲染，不含 AI 成员检查/编辑/逐人复测。 |
| A17 | 长文档、字体/渲染器/视觉能力缺失边界正确 | partial | E3、T3 | 字体负例与局部渲染可复核；长文档/产品视觉阻塞未测。 |
| A18 | 不同性格角色有自然、有依据的异议 | blocked | B1 | 没有 AI 对话。 |
| A19 | 产品区分 GitHub 下载与内置技能模板来源 | blocked | B1 | 没有真实工作模式任务触发下载/导入。 |
| A20 | 技能注入、越权、路径穿越等产品负例被拒绝 | not_run | E1 | Gateway 测试不是 App 中导入和执行负例。 |
| A21 | 自建技能先试用成功，再激活并复用 | not_run | E1、T2 | 只验证策略/存储代码路径，未走完整 runner 生命周期。 |
| A22 | 同一技能在真实群聊和私聊中复用 | blocked | B1 | 没有可用的隔离群/私聊模型运行。 |
| A23 | provider usage、重试、未知 token 和任务总量账本准确 | not_run | B1、E1 | 本地请求协议回归通过，但没有真实 usage 可对账。 |
| A24 | 有进展长任务与重复失败空转保护均正确 | blocked | B1 | 没有持续执行的真实任务观察窗口。 |
| A25 | 暂停/停止/继续/退出不发新操作或盲目重放 | blocked | B3、T1 | 持久暂停代码回归通过；无生产桌面操作可注入。 |
| A26 | 执行中和试用中连续修改、附件 FIFO 不丢失 | blocked | B1 | 没有执行/试用中的现场任务。 |
| A27 | 删除后迟到模型/工具结果不能复活任务 | not_run | E1 | 未在隔离产品运行中注入迟到返回。 |
| A28 | 旧完成、旧未完成、未知 schema 恢复策略正确 | not_run | E1 | 未运行产品启动恢复/迁移场景。 |
| A29 | all/configurationOnly/conversation 备份、恢复 remap 与重授权 | not_run | E1 | 未对可证明隔离的真实工作模式数据备份。 |
| A30 | 附件投递失败时保留完成结果且只允许重发 | not_run | B1 | 没有候选或正式附件投递。 |

## 原生负例 N01–N14

| ID | 场景 | 结果 | Review 关联 | 未覆盖 / 原因 |
|---|---|---|---|---|
| N01 | nativeBundle 合同提案经真实讨论进入制作 | blocked | F02、R03 | 无模型响应，未形成 proposal。 |
| N02 | 只有 .app 时自动打包候选并审查/试用 | blocked | F03、T04 | 真实 bundle 单测通过，但没有产品候选发布。 |
| N03 | 仅视觉可见遮挡真实送达模型并被发现 | blocked | F05、F08 | 没有图像模型请求或传输证据。 |
| N04 | UI 可操作但业务计算错误时不得误通过 | blocked | F04、T01 | 原生断言代码测试通过；没有成员现场操作错误样本。 |
| N05 | Flutter 控件缺 identifier 时生产工具操作或明确阻塞 | blocked | F06 | 无生产 selector/Automation Mode GUI 操作。 |
| N06 | ZIP 未变但运行解包副本变化时证据失效 | not_run | F07、T1 | 未启动受控 App 并改变运行副本。 |
| N07 | 当前使用收据依赖页图损坏后完成门禁拒绝 | not_run | F11 | 没有产品收据和当前证据文件。 |
| N08 | 假 .env/dev_credentials.hive 不泄露且不进入候选 | partial | F01 | 精确 DEBUG 包的 signed fixture archive 测试拒绝假凭据；无群聊消息/候选全链路。 |
| N09 | 同 bundleId 旧版冲突被识别且不误用 | not_run | A12 | 未运行旧版冲突场景。 |
| N10 | 损坏 App、外链、错误 bundleId 和非法 archive 被拒绝 | not_run | F01、F03 | 只通过受控 archive 测试；生产候选门禁 fixture 未全部现场执行。 |
| N11 | 并发请求和焦点切换不会向错误窗口输入 | blocked | B3 | 无桌面锁、Appium 和真实产品任务。 |
| N12 | 缺权限先 blocked，补权限后同一任务续接 | blocked | F09、B3 | 系统权限未授权，未启动并恢复原生任务。 |
| N13 | 暂停后无新动作、文件保留、继续不盲重放 | not_run | F07、F09、T1 | 协调器有自动化回归；没有原生副作用任务。 |
| N14 | stop/exit/delete 清理本任务资源并隔离迟到返回 | blocked | F13、B3 | Appium 未安装且没有本次拥有的生产 session。 |

## 文档负例 D01–D07

| ID | 场景 | 结果 | Review 关联 | 未覆盖 / 原因 |
|---|---|---|---|---|
| D01 | 两份同名异内容文档分别被读取和核对 | blocked | F08、R04 | 文档索引代码有回归，未由群内角色读取两份输入。 |
| D02 | 遗漏末页或正文块不得完成 | blocked | F05、F08 | renderer 可生成页图，但没有模型逐页传输/覆盖证据。 |
| D03 | 字体替代必须明确并按策略阻塞/未验证 | partial | F12、T03 | 字体解析负例和混合样式回归通过；缺产品角色判断与最终门禁。 |
| D04 | 缺视觉模型不能偷偷换模型或以文字冒充 | blocked | F05 | 未在工作模式触发视觉能力预检。 |
| D05 | 缺 renderer 或超过容量必须报告未验证 | not_run | 无 | 未注入 renderer 缺失和页数/容量边界。 |
| D06 | 冻结源变化后旧页图/摘要/收据失效 | not_run | F07、F08 | 未创建当前产品文档收据后修改源文件。 |
| D07 | 没有图像传给模型不能手写 evidence 通过 | blocked | F05、F11 | 没有模型图像请求与生产使用收据。 |

## 技能负例 K01–K10

| ID | 场景 | 结果 | Review 关联 | 未覆盖 / 原因 |
|---|---|---|---|---|
| K01 | 内置模板与真实 GitHub import 来源区分 | blocked | F15、F17 | 没有群任务或真实远端导入。 |
| K02 | 固定 SHA 后仓库更新不漂移、资源缺失时拒绝 | blocked | 无 | 未对真实公开仓库执行生产导入。 |
| K03 | 根 pack.json/usage.json 与应用元数据隔离并备份往返 | not_run | F14 | Gateway/parser 回归不替代 App import/backup。 |
| K04 | 无脚本 references/assets 按真实义务验证 | partial | F16、T2 | 有策略与资源存储代码测试；没有真实技能任务试用/激活。 |
| K05 | allowed-tools、注入、路径穿越和越权读取被拒绝 | not_run | F01、F14 | 未把远端包导入产品或运行负例。 |
| K06 | 资源/磁盘故障返回可恢复错误且队列可继续 | not_run | F13 | 未对产品技能队列做现场故障注入。 |
| K07 | 自动创建技能必须先真实成功试用复测再激活 | blocked | F17、T2 | 无真实模型任务完成或技能验证证据。 |
| K08 | 同名但运算符/大小写语义不同的方法不合并 | not_run | F18 | 代码级去重测试不等于真实技能沉淀。 |
| K09 | 缺网络/SDK/权限/许可不能被 skill.create 伪装补齐 | not_run | F17 | 未触发远端许可和权限场景。 |
| K10 | 恢复后资源来源可查且本机执行权重新授权 | not_run | F19 | 未执行隔离备份恢复和本机权限重新绑定。 |

## F01–F19 关联与当前代码证据

| Review ID | 现场映射 | 本轮代码/测试观察 | 现场状态 |
|---|---|---|---|
| F01 | N08、N10 | 当前 archive 路径安全扫描存在；精确 DEBUG 包假凭据 fixture 通过 | N08 partial |
| F02 | N01 | 合同动作允许 nativeBundle 的代码仍在 | blocked |
| F03 | N02、N10 | 候选路径处理有源码和包测试 | blocked / not_run |
| F04 | N04 | 断言不再把动作能力覆盖等同业务通过；原生断言基线回归通过 | blocked |
| F05 | N03、D02、D04、D07 | 原生截图进入模型图像内容的路径存在 | blocked |
| F06 | N05 | identifier 缺失时生成受控 selector 的路径存在 | blocked |
| F07 | N06、N13、D06 | 运行 App 冻结校验路径存在 | not_run |
| F08 | D01、D02、D06 | 证据按路径/摘要绑定的代码存在 | blocked / not_run |
| F09 | N12、N13 | blocked 后可续接的代码路径存在；暂停持久化新回归通过 | blocked |
| F10 | A02 | explicitExecutorId 钉定边界代码存在 | blocked |
| F11 | N07、D07 | 证据引用逐条读取/核对的路径存在 | not_run / blocked |
| F12 | D03 | 混合直接字体与引用样式字体解析回归通过 | partial |
| F13 | N14、K06 | 技能队列业务异常和内部 Future 收尾测试通过 | blocked / not_run |
| F14 | K03、K05 | 保留元数据路径拒绝回归有代码覆盖 | not_run |
| F15 | K01 | 激活资源包 ID 与读取指引进入提示的代码存在 | blocked |
| F16 | K04 | 无脚本引用资源路径的策略与存储测试覆盖 | partial |
| F17 | K01、K07、K09 | 草稿不直接激活；生产策略与存储代码测试存在 | blocked |
| F18 | K08 | 运算符/大小写规范化代码回归存在 | not_run |
| F19 | K10 | 缺少历史证据的备份 manifest 可显式标缺；没有证据文件跨设备恢复 | not_run |

第三轮复审 T01–T04 的当前修复代码分别位于 macos_native_app_automation.dart、default_work_task_runner_context.dart/work_mode_policy.dart、binary_document_parser.dart、default_work_task_runner_production_delivery.dart。重点测试包含稳定业务断言、草稿策略、混合字体和冻结候选重发；它们不改变以上现场矩阵结果。
