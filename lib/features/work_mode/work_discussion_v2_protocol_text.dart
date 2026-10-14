import 'work_public_update_stream.dart';

/// 群讨论 v2 协议提示词的文本。
///
/// 与 `WorkDiscussionV2Turn` 分开：这四千余字符是发给模型的提示词，而那个类是
/// 协议解析与字段校验。混在一个文件里既让文件越过仓库的 500 行界限，也让"改提示
/// 词"和"改校验"变成同一处的编辑。
class WorkDiscussionProtocolText {
  static const head = '''只返回严格 JSON object，不输出 Markdown 或私有推理。
全部顶层字段必须出现：schemaVersion:2、action、public_update、issue_id、next_member_id、issues、resolutions、proposal、approval、decision、tool。无内容字段用空字符串、空数组或 null。
完整顶层结构示例（内容需按你的真实判断填写）：{"schemaVersion":2,"action":"respond","public_update":"本轮公开意见","issue_id":"","next_member_id":"","issues":[],"resolutions":[],"proposal":null,"approval":null,"decision":null,"tool":null}。不增加其他顶层字段，不把公开说明放在 JSON 外。
字符串值内部禁止出现未转义的半角双引号；需要引用用户原话或术语时改用「」或全角引号，确实要用半角引号时必须写成 \\" 转义，否则整段 JSON 会因语法错误被判废。
action: respond/investigate/propose/approve/decide/silent。respond 与 silent 时 proposal/approval/decision/tool 全部为 null；propose 只填 proposal，approve 只填 approval（包括本人不认可 approved:false），decide 只填 decision，investigate 只填 tool，其余三个为 null。public_update 是自然公开回应，不展示合同 JSON，不写理解百分比，不出现版本整数、approved:true|false、阶段名或 proposal 摘要等协议标识，不出现 artifactContract、requiredCapability、V-08 这类内部标识符，也不排 ①②③④ 式清单——那些值只填进对应字段，缺陷与补丁要求写进 issues 或详情，气泡只给你的判断和依据。公开气泡目标是 ${WorkPublicUpdateStream.bubbleTargetCharacters} 字以内（一到三个短句），按目标写而不是写到它的边上；超出部分会被截断并标注，完整正文转存为详情附件，所以只写当前结论、依据或异议，明细交给 issues 与详情。
本轮只推进上下文 turnFocus 指明的一项工作，不在一次回应中模拟整场会议、完整开发和未来验收。它是注意力提示，不是批准或工具授权；真实缺陷与分歧必须继续记录。outputGuidance 指定正文优先的建议预算，不保证服务端预留；先保证完整最终 JSON，不反复推演同一方案。
recentDiscussion 与 recentChatMessages 是有界聊天预览，可能截断，不能据此判定方案内容缺失；审查完整提案使用 collaboration 中的权威方案与关联问题。准备提交的命令必须写入完整 proposal.artifactContract.verificationCommands，不能只口头列在 public_update 中让其他成员从预览猜测。effectiveTools 表示角色与任务允许的权限，不保证工具已注册、依赖已安装或讨论阶段允许执行；browserContext 权限不能证明浏览器运行时可用，commandRun 权限不能证明 jsdom 已安装。
issues 是本轮全部新问题，每项 {id,kind:"defect|idea|decision",target,problem,evidenceRef,retestCondition}。问题、依据、解决条件必须具体；evidenceRef 引用当前真实证据或你的响应，不伪造代码读取。
新问题仅依据本轮本人意见时，issues.evidenceRef 填空字符串，运行时收到真实回应后才绑定响应 ID；不能填 self、current-response、userRequest 等占位符或自造引用。引用旧工具或用户答复时逐字复制 evidence 中真实键或 collaboration.decisions.responseRef。resolutions 必须引用已有真实证据，不引用尚未取得 ID 的当前回应。
resolutions 是 {id,resolution,evidenceRef} 数组，只引用真实工具/成员回应/用户答复，不因模型自称完成删除问题。
调查：action=investigate，issue_id 指向已有 open 问题，tool={name,arguments}。只允许 workspace.list/read/search/document；调查结果回台账后再讨论，禁止 command.run、写文件、安装、写探针或浏览器。工具能力与权限以运行时为准。
proposal={scope,plan,artifactContract:{type,format,location,revisionTarget,files:[相对路径字符串]},workItems:[{id,ownerId,dependencies,kind:"material|produce"}],acceptances:[{id,method,requiredCapability}]}。workItems 只允许 id/ownerId/dependencies/kind 四个字段，kind 可省略或为 material/produce；acceptances 只允许 id/method/requiredCapability 三个字段。不要把执行状态、说明文字或额外字段放进这些对象，运行时会生成状态字段。files 必须是相对路径字符串数组，不是对象数组。只协调成员可建立/修改当前方案，不默许原型；制作和测试工作项这里只规划，不声称已经执行。仅要求软件需求文档时不得扩展交付成软件。工作项、验收的 requestRevision 必须匹配当前需求；用户裁决/补充后旧版工作项必须由协调成员重新形成 proposal，不能只重新签字。
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
verificationCommands 必须放在 proposal.artifactContract 内，不能成为 proposal 的第六个字段。它必须是非空字符串数组；每项都是 command.run 的紧凑 JSON 参数字符串，只能包含 executable 与 arguments，键顺序固定为 executable、arguments，例如元素文本为 {"executable":"node","arguments":["verify.js"]}。不得把元素写成对象，不得在命令字符串内添加编号或环境字段；V-01 等用例编号、每条命令的运行环境及其映射写在 plan 中。每条字符串不超过 1024 字符。proposal 本身只包含 scope、plan、artifactContract、workItems、acceptances。
已有方案非空时，补充原来没有的 verificationCommands 也属于验收修改；必须先登记 kind=idea 的问题，完整 proposal 用 issue_id 关联它，再由全员确认后采纳。可在同轮 issues 登记该提案问题并提交关联 proposal，但不能自称已被认可。既有 acceptances 的 id、method、requiredCapability 必须逐字保留；更新需求版本不意味着允许改写验收口径。任何新增或修改同样要关联提案。
新增范围作为 kind=idea 的问题，全体成员对该提案明确认可后再更新范围、计划和验收；有分歧用 decide 交用户。保留用户原始范围和所有禁止事项，不能扩大工具授权。
''';

  /// 认可合同：只在方案/提案/候选已就位的那一轮才可能被采纳。
  static const approvalTail =
      '''approval={kind:"plan|idea|delivery",subjectId,approved:true|false,requestRevision,teamRevision,verificationRevision}。delivery 必须另带 iterationId 和 artifactDigest，逐人审阅当前候选与真实验证报告。
approval 结构必须逐字包含 kind、subjectId、approved、requestRevision、teamRevision、verificationRevision 六个字段；版本必须是 JSON 整数而非字符串。plan 的 subjectId=taskId；idea 的 subjectId=对应问题 id；delivery 另加 iterationId 与 artifactDigest，且 subjectId=iterationId=当前候选 id、摘要原样复制当前候选。例：{"kind":"idea","subjectId":"ISS-VC-01","approved":true,"requestRevision":2,"teamRevision":1,"verificationRevision":3}。示例中的 ID 与版本仅说明类型和结构，必须替换为当前上下文的真实值，不能照抄。只代表自己，对当前完整方案或指定提案逐人确认；沉默、百分比、总结不是认可，不能返回他人签字。
''';

  /// 每个阶段都要遵守的收尾规则。
  static const tailCommon =
      '''decision={kind:"question|choice|dispute",targetId,reason,evidence,impact,options:[{id,label,impact}]}，用户偏好、未知规则与真实分歧走用户决策；不要把普通实现取舍推给用户。
next_member_id 可请求当前团队具体成员回应当前问题，不能用它调入群外成员。没有新增信息且无必要答复可以 silent。''';
}
