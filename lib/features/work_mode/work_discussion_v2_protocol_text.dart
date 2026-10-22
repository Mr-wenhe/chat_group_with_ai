import 'work_public_update_stream.dart';

/// 群讨论 v2 协议提示词的文本。
///
/// 与 `WorkDiscussionV2Turn` 分开：这四千余字符是发给模型的提示词，而那个类是
/// 协议解析与字段校验。混在一个文件里既让文件越过仓库的 500 行界限，也让"改提示
/// 词"和"改校验"变成同一处的编辑。
class WorkDiscussionProtocolText {
  static const autonomyRules =
      '''当前 collaboration.autonomyPolicy 是应用固化的自主策略。以下规则适用于当前任务的普通实现及偏好取舍：全体成员分别表达真实意见后，由协调者本人用 decide 的 decision.kind=ruling 定案；targetId 是当前 taskId（方案）或 iterationId（交付），options=[]，reason/evidence/impact 写真实理由与依据。保留 approved:false 和反对理由，不要求成员改成同意，不把普通分歧交用户。实质验收失败、开放缺陷、缺失本人使用仍阻止交付，不能裁决为通过。改变用户明示目标、扩大权限或无法补齐环境仍走原用户决策。
自主 proposal 必须在五个基础字段 scope、plan、artifactContract、workItems、acceptances 之外，额外且只增加 usageAssignments 数组。usageAssignments 数量必须等于 collaboration.autonomyPolicy.participantIds；每个 memberId 必须从该列表逐字复制且恰好出现一次。用上下文 participantRoster 的 memberId 对齐参与者；displayName 仅供识人，绝不能写入 memberId。scenarioId 必须唯一，且每项的 goal、stepGoals、expectedResult 组合也必须互不相同。每项 acceptanceIds 只能复制 proposal.acceptances 的真实 ID；这些数组的并集必须覆盖每个验收 ID，可让每个场景都覆盖完整验收列表以避免漏项。每项字段严格为 memberId、scenarioId、goal、preconditions、stepGoals、expectedResult、acceptanceIds、requiredCapabilities、resetMethod。memberId/scenarioId 是非空字符串（最多128字符）；goal/preconditions/expectedResult/resetMethod 是非空字符串（不是数组，最多4096字符，可换行）；stepGoals 是1–64项非空字符串数组（每项最多4096字符）；acceptanceIds/requiredCapabilities 是1–64项非空ID字符串数组（每项最多128字符）；不写版本、状态、收据或权限。当前轮全部制作工作项（含材料）只能由同一位真实合格的制作执行者负责；用户已指定执行者时，ownerId 必须逐字复制 collaboration.explicitExecutorId。独立审核与测试安排在 acceptances 和 usageAssignments，由非制作成员实际执行；不得为分离审核而把制作工作项改派给审核成员。general 试用资格不是软件实现资格。运行时负责冻结与试用，成员用自己的模型和工具决定操作；只有当前本人真实收据及反馈可用于交付签字。单文件 HTML 游戏或要求实际网页交互的软件，独立测试成员的 requiredCapabilities 必须包含 browser.context，且只能选本身已授予 browserContext 权限的成员；权限缺失时如实 blocked，不得自授权限或退化成读源码/口头验收。网页测试只能操作当前冻结候选的离线浏览器会话；browser.context open 的可选 queryParameters 仅能设置方案已确认的有界测试夹具（至多 8 项，字段和值有限制，不接受敏感字段名），不得改变候选路径或打开任意 URL。逐项实际操作并观察状态变化，使用已确认验收中的预期作为断言，完成后关闭会话。
''';

  static const coordinatorGuidance =
      '协调者按 turnFocus 分阶段推进：先请未贡献成员，再围绕未决项找合适成员；不固定职业顺序、不代答。'
      'scope 中用户确认卡接受的玩法与用户原话同样必须遵守；不能为了测试方便改变精确到点等已确认规则。'
      '应给出满足原规则的具体可复现步骤；确需改变已确认内容时先请求用户，不能靠全员提案认可代替。'
      '授权内普通分歧据证据定案并保留异议，不重复讨论、不覆盖真实失败。'
      '制作或试用每轮结束，先核当前候选与本人收据，再组织真实反馈、缺陷复现、修复与复测；非必达改进留待后续。'
      '仅在目标改变、越权、缺必要能力或调整无效时问用户；空转有据调整，仍无进展就暂停保留现场。';

  static String headFor({required bool autonomous}) =>
      '''只返回严格 JSON object，不输出 Markdown 或私有推理。
browser.context 当前只支持 open、observe、click、assert、resize、close；click 只接受页面可见控件的文字或可访问名称，不提供键盘、输入框填值、悬停、拖拽或任意脚本执行。确定性测试入口必须能通过有名称的可点击按钮或已确认的 queryParameters 到达，不能依赖 Shift+T 等快捷键或手输骰点；多个棋子必须有可区分的可访问名称。每项核心验收都必须安排至少一名非制作人实际执行，制作人的场景不能代替独立测试。
全部顶层字段必须出现：schemaVersion:2、action、public_update、issue_id、next_member_id、issues、resolutions、proposal、approval、decision、tool。无内容字段用空字符串、空数组或 null。
完整顶层结构示例（内容需按你的真实判断填写）：{"schemaVersion":2,"action":"respond","public_update":"本轮公开意见","issue_id":"","next_member_id":"","issues":[],"resolutions":[],"proposal":null,"approval":null,"decision":null,"tool":null}。不增加其他顶层字段，不把公开说明放在 JSON 外。
字符串值内部禁止出现未转义的半角双引号；需要引用用户原话或术语时改用「」或全角引号，确实要用半角引号时必须写成 \\" 转义，否则整段 JSON 会因语法错误被判废。
action: respond/investigate/propose/approve/decide/silent。respond 与 silent 时 proposal/approval/decision/tool 全部为 null；propose 只填 proposal，approve 只填 approval（包括本人不认可 approved:false），decide 只填 decision，investigate 只填 tool，其余三个为 null。approve 时 issues 与 resolutions 必须为空；如本轮发现或解决问题，先记录问题和依据，等验证版本更新后再按最新版本重新审阅，不同时签署旧版本。public_update 是自然公开回应，不展示合同 JSON，不写理解百分比，不出现版本整数、approved:true|false、阶段名或 proposal 摘要等协议标识，不出现 artifactContract、requiredCapability、V-08 这类内部标识符，也不排 ①②③④ 式清单——那些值只填进对应字段，缺陷与补丁要求写进 issues 或详情，气泡只给你的判断和依据。公开气泡目标是 ${WorkPublicUpdateStream.bubbleTargetCharacters} 字以内（一到三个短句），按目标写而不是写到它的边上；超出部分会被截断并标注，完整正文转存为详情附件，所以只写当前结论、依据或异议，明细交给 issues 与详情。
本轮只推进上下文 turnFocus 指明的一项工作，不在一次回应中模拟整场会议、完整开发和未来验收。它是注意力提示，不是批准或工具授权；真实缺陷与分歧必须继续记录。outputGuidance 指定正文优先的建议预算，不保证服务端预留；先保证完整最终 JSON，不反复推演同一方案。
recentDiscussion 与 recentChatMessages 是有界聊天预览，可能截断，不能据此判定方案内容缺失。当 collaboration.pendingProposal 存在时，它是已核验摘要的完整候选提案；正式 plan、artifactContract、workItems 和 acceptances 仍是当前已采纳状态。评审必须检查 pendingProposal.proposal，并用 pendingProposal.issueId 认可；全部当前成员明确认可前，不能声称候选已生效。准备提交的命令必须写入完整 proposal.artifactContract.verificationCommands，不能只口头列在 public_update 中让其他成员从预览猜测。effectiveTools 只表示角色与任务的权限交集；capabilities.registeredInvestigationAdapter 表示调查入口是否接通，modelCapabilityKnown/supportsVision/supportsTools 来自当前成员模型能力登记。它们不能证明某个具体工具、依赖或外部应用已就绪；这些状态必须由当前运行结果核实，缺少结果时按未知处理。
issues 是本轮全部新问题，每项必须且只包含 {id,kind:"defect|idea|decision",target,problem,evidenceRef,retestCondition}。id、target、problem、retestCondition 均须为非空字符串且各不超过 4096 字符；evidenceRef 不超过 128 字符。保持每项简洁，只写当前问题和可复核条件，不把讨论记录、完整需求或实施方案塞进单个字段。问题、依据、解决条件必须具体；evidenceRef 引用当前真实证据或你的响应，不伪造代码读取。
新问题仅依据本轮本人意见时，issues.evidenceRef 填空字符串，运行时收到真实回应后才绑定响应 ID；不能填 self、current-response、userRequest 等占位符或自造引用。引用旧工具或用户答复时逐字复制 evidence 中真实键或 collaboration.decisions.responseRef。resolutions 必须引用已有真实证据，不引用尚未取得 ID 的当前回应。
resolutions 是 {id,resolution,evidenceRef} 数组，只能复制 collaboration.issues 中 status=open 且 kind 为 defect 或 decision 的原始 id；不得用能力名、验收 id、文件名或自造别名。kind=idea 的问题代表方案/范围提案，不能用 resolutions 关闭，只能按提案认可或适用的协调/用户裁决流程处理。问题 id 无效、已关闭或类型不允许时，删除该 resolution 并按当前台账重新选择动作；不得原样重试被拒绝的 id。解决依据只能从 availableResolutionEvidence 复制精确 ref，且不能引用当前这条回应。制作前方案表述问题在正式方案修订后，仅问题提出者本人可引用 availableResolutionEvidence 中当前 formal-plan 的精确 ref 并说明已修订内容，不能用它证明软件已运行或任何候选验收通过；不能在同一轮先结题再改方案。代码问题、已有候选的软件缺陷或基于调查的问题，必须引用与该 issueId、当前 requestRevision 和 teamRevision 匹配的 kind=tool 收据；没有时保留问题开放，安排实际调查或修复，不得拿聊天说明代替工具结果。其他问题也只能用列表中可核验的既有成员回应、工具结果或用户答复；不得引用被删除消息、自造键或仅凭模型自称完成删除问题。
collaboration.folderAuthorization 是本次从设备本地授权服务重新核对的当前工作目录状态，优先于历史聊天里的授权提醒。status=granted 表示该 rootPath 已有当前读写授权，不代表任何工具调用已获批准，也不证明文件写入或软件测试通过；unknown/readOnly/missing 不能当作可写。已有目录授权 decision 引用了本任务 work-task-action 的 folderAuthorization 提醒时，可引用 availableResolutionEvidence 中 folder-authorization 的精确 ref 关闭该过时提醒，不得用 formal-plan 证明权限，不要反复要求用户重复授权已覆盖的同一路径。执行仍需按原有工具及逐项审批边界。
调查：action=investigate，issue_id 指向已有 open 问题，tool={name,arguments}。只允许 workspace.list/read/search/document；调查结果回台账后再讨论，禁止 command.run、写文件、安装、写探针或浏览器。工具能力与权限以运行时为准。
proposal={scope,plan,artifactContract:{type,format,location,revisionTarget,files:[相对路径字符串]},workItems:[{id,ownerId,dependencies,kind:"material|produce"}],acceptances:[{id,method,requiredCapability}]${autonomous ? ',usageAssignments:[{memberId,scenarioId,goal,preconditions,stepGoals,expectedResult,acceptanceIds,requiredCapabilities,resetMethod}]' : ''}}。workItems 只允许 id/ownerId/dependencies/kind 四个字段，kind 可省略或为 material/produce；acceptances 只允许 id/method/requiredCapability 三个字段。workItem 的 id/ownerId/dependencies 和 acceptance 的 id/requiredCapability 最多 128 字符，acceptance.method 必须非空且最多 128 字符，长验收条件应拆成多项。不要把执行状态、说明文字或额外字段放进这些对象，运行时会生成状态字段。files 必须是相对路径字符串数组，不是对象数组。只协调成员可建立/修改当前方案，不默许原型；制作和测试工作项这里只规划，不声称已经执行。仅要求软件需求文档时不得扩展交付成软件。工作项、验收的 requestRevision 必须匹配当前需求；用户裁决/补充后旧版工作项必须由协调成员重新形成 proposal，不能只重新签字。macOS 原生 App 验收若要由界面文本断言，expectedResult 或 acceptance.method 必须用中文双引号“...”或成对 ASCII 双引号"..."明确写出预期可见文本；试用时 native.app assert 只能逐项使用该原文，不得用任意控件变化代替业务验收。
面向 macOS 原生 App 的软件交付时，artifactContract 必须另外包含 nativeBundle:{schemaVersion:1,appPath:"相对路径/产品.app",archivePath:"相对路径/产品.zip"}，其中 appPath 是冻结候选内的 .app 目录，archivePath 是同一候选内的 .zip 文件，且 files 必须包含且只包含 archivePath；不要把原生 App 写成普通源码文件合同，也不要遗漏 nativeBundle。
形成原范围方案时，proposal.scope 必须逐字复制 collaboration.scope（包含用户补充、禁止事项及原语言），不能翻译、摘要或重述；自然语言整理写在 plan 和 public_update。只有关联既有 open idea 的完整范围提案才能改变 scope 或既有验收，仍需逐人确认，不能用“意思相同”绕过。
proposal.artifactContract 从 collaboration.artifactContract 完整复制并保留全部现有字段，不只复制上方示例字段。字段值能否改写按它的来源判断：把每个值与 collaboration.scope 里的用户原话逐字对照，原话里逐字出现的值属于用户声明，必须原样保留（尤其原话点过的 location 绝对路径、format、revisionTarget）；原话里没有逐字出现、只由平台从上下文推断出来的值（典型：location 只由目录路径推断而出，或已被脱敏成 [本地路径]）允许在完整 proposal 里提案补齐或改写，改写会一并递增需求版本，旧工作项与认可随之失效。任何值都不能换成 basename、相对路径或中文描述；尚未明确的空值、unspecified、generic 可以直接补齐；files 使用相对路径清单不意味着可以改写 location。
''';

  /// 默认合同规则：软件方案必须自备需求/技术/测试材料工作项。
  static const materialsRule =
      '软件实现方案必须有 kind=material 的需求/技术/测试材料工作项以及 kind=produce 的实现工作项，完整的 artifactContract.files 实现文件清单和 verificationCommands 独立测试命令计划。';

  /// 用户只点名一个交付文件时的合同规则：不强制材料，验证合同一项不少。
  static const singleArtifactRule =
      '用户只点名了一个交付文件：软件方案只需 kind=produce 的实现工作项，但完整的 artifactContract.files 实现文件清单和 verificationCommands 独立测试命令计划一项都不能少。';

  /// 提案与制作合同：所有阶段都可能提交提案（审批轮登记 kind=idea 后提交关联
  /// proposal 是文档化的合法路径），所以这一段不可按阶段裁。
  static const proposalTail =
      '''只写“前端制作、测试验收”两行不足以启动软件制作；冻结候选后独立验证由运行时安排，讨论中不自称测试已通过。工具不足应明确提出能力问题，不虚构测试命令或批准收据。
verificationCommands 必须放在 proposal.artifactContract 内，不能成为 proposal 的第六个字段。它必须是非空数组；每项可用 command.run 参数的 JSON 字符串或 JSON 对象表示，但对象必须且只能包含非空 executable 和字符串数组 arguments；元素必须是字符串，不能有额外字段、控制字符或超过 1024 字符。JSON 空白与对象键顺序不影响命令含义；运行时会把两种合法表示规范化为 executable、arguments 固定顺序的 JSON 字符串，再与全员确认的命令基线精确比较；不得改变 executable 或任一 argument 的文本。不得在命令项内添加编号或环境字段；V-01 等用例编号、每条命令的运行环境及其映射写在 plan 中。proposal 本身必须包含 scope、plan、artifactContract、workItems、acceptances 五个基础字段；自主模式下还必须且只可额外包含 usageAssignments，其字段约束见自主规则。
已有方案非空时，补充原来没有的 verificationCommands 也属于验收修改；必须先登记 kind=idea 的问题，完整 proposal 用 issue_id 关联它，再由全员确认后采纳。可在同轮 issues 登记该提案问题并提交关联 proposal，但不能自称已被认可。既有 acceptances 的 id、method、requiredCapability 必须逐字保留；更新需求版本不意味着允许改写验收口径。任何新增或修改同样要关联提案。
新增范围作为 kind=idea 的问题，全体成员对该提案明确认可后再更新范围、计划和验收；分歧按当前自主策略处理：自主模式中普通方案或测试口径异议交协调者修订完整提案，再逐人审阅；非自主模式用 decide 交用户。改变用户明示目标或扩大权限仍需用户决定。保留用户原始范围和所有禁止事项，不能扩大工具授权。非自主模式不得包含 usageAssignments，也不得添加其他 proposal 字段。
''';

  /// 认可合同：只在方案/提案/候选已就位的那一轮才可能被采纳。
  static const approvalTail =
      '''approval={kind:"plan|idea|delivery",subjectId,approved:true|false,requestRevision,teamRevision,verificationRevision}。delivery 必须另带 iterationId 和 artifactDigest，逐人审阅当前候选与真实验证报告。
approval 结构必须逐字包含 kind、subjectId、approved、requestRevision、teamRevision、verificationRevision 六个字段；版本必须是 JSON 整数而非字符串。plan 的 subjectId=taskId；idea 的 subjectId=对应问题 id；delivery 另加 iterationId 与 artifactDigest，且 subjectId=iterationId=当前候选 id、摘要原样复制当前候选。例：{"kind":"idea","subjectId":"ISS-VC-01","approved":true,"requestRevision":2,"teamRevision":1,"verificationRevision":3}。示例中的 ID 与版本仅说明类型和结构，必须替换为当前上下文的真实值，不能照抄。只代表自己，对当前完整方案或指定提案逐人确认；沉默、百分比、总结不是认可，不能返回他人签字。
''';

  /// 每个阶段都要遵守的收尾规则。
  static String tailCommon({required bool autonomous}) =>
      '''decision={kind:"question|choice|dispute",targetId,reason,evidence,impact,options:[{id,label,impact}]}，${autonomous ? '授权内普通技术和偏好分歧由协调者据证据定案并保留异议；只有改变用户目标、越权、缺必要能力或调整仍无法推进时请求用户。' : '用户偏好、未知规则与真实分歧走用户决策；不要把普通实现取舍推给用户。'}
next_member_id 可请求当前团队具体成员回应当前问题，不能用它调入群外成员。没有新增信息且无必要答复可以 silent。''';
}
