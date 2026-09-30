# 工作模式：分块写入与截断抢救（设计）

- 状态：设计待评审
- 日期：2026-09-30
- 范围：`lib/features/work_mode/`、`lib/features/agentic/`
- 相关红线：审批范围语义、工作模式连续修改、导出/备份内容

## 1. 背景

### 1.1 现象

任务面板反复出现「模型输出被上限截断，改用精简指令重试。第 N 次协议重试」。文案来自 `_protocolRetryTitle`（`work_agent_loop_retry.dart:301`），判据是 `_responseHitsOutputLimit`（同文件 `:283`）：供应商回 `finish_reason=length`（`truncated`），或「本次已输出 token ≥ 请求的 max_tokens 的 95%」（余量取 1/20，见 `_outputBudgetMarginDivisor`）。

### 1.2 现场证据

取自调试 App 的真实事件日志（`~/Library/Application Support/com.example.chatGroup/work_mode_agent/events/*.jsonl`）：

| 时间 | 任务 | 事件 | 已输出 / 请求 | 正文长度 |
|---|---|---|---|---|
| 2026-09-30 19:35 | e3714bb4 | 第 2 次协议重试 | 20480 / 20480 | 53,866 字符 |
| 2026-09-30 18:46 | e3714bb4 | 第 2 次协议重试 | 20480 / 20480 | 55,052 字符 |
| 2026-09-30 16:15 | d5442d40 | 第 1 次协议重试 | 20480 / 20480 | 58,761 字符 |
| 2026-09-24 全天 | 1552aaab | 共 6 次（含第 3 次） | 无该字段（旧构建） | 无该字段 |

全量日志中带 `safeMetadata.truncated` 的事件共 10 条，分布在 4 个任务里。任务内容为「重写三国杀（HTML 游戏）」「多城市旅游攻略转 PDF」这类**单文件大产物**。

`completionTokens` 恰好等于 `requestedMaxTokens`，说明模型把输出预算用满后被上游切断，断口落在 AgentDecision JSON 中间；解析必然失败，整条动作作废，一个字都没有落盘，只能重生成。

### 1.3 预算从哪来

20480 是能力表里的**声明值**，不是厂商硬限：`app_settings` 的 `custom_model_capabilities_v1` 给 `custom/sensenova-6.8-flash-lite` 声明 `maxOutput = 20480`，经 `workModeRequestOutputTokens`（`default_work_task_runner_model_io.dart:13`）取「声明值 / 上下文窗口一半 / 绝对天花板 32768（`:29`）」三者最小得到。抬声明值只是把失败点往后挪，产物更大照样撞，而且每次失败更贵。

### 1.4 现有兜底为什么不够

截断后唯一的手段是话术：下一次决策的 context 多一个 `truncatedOutputHint`（`work_agent_loop_retry.dart:360`），内容是 `_truncatedOutputChunkingAdvice`（`:10`）——「每段各写独立文件、每次 ≤3000 字、最后一次用 `command.run` 合并」。问题有三：

1. 这段提示是作为 `公开任务检查点：{...}` 大 JSON blob 的一个字段发出的（`work_agent_loop_checkpoint.dart:306`），显著性极低，模型经常不照做（同一任务撞 2 次、9/24 那个任务撞 6 次）。
2. 工具集里**没有追加写**：写文件只有整文件覆盖（`stage02_workspace_file_tool.dart:321` `write`），要分批写长文件只能「多写几个分段文件 + 合并」，而合并那一步要么跑 `command.run`（shell，需单独审批），要么不可行——比「一把写完」贵得多。
3. 截断发生时已经烧掉的 2 万 token 全部作废。

## 2. 目标与非目标

**目标**

1. 长产物写入天然分多次小动作：每次决策的输出都远低于上限。
2. 合并成为受治理的工具动作，不再依赖 shell 审批（真正需要转换的 docx 除外）。
3. 被截断的输出不再全损：已生成的前缀落盘，模型只补写余下部分。

**非目标**

- 不把抢救内容直接覆盖到交付物路径（会先毁掉旧版本，用户已否）。
- 不改动去重键语义；不引入 `expectedSha256` 前置校验（模型拿不到哈希，见 §4.4）。
- 不动会话占用、排队、审批范围的既有红线。
- 不把 docx/xlsx 转换工具化：转换仍需 `command.run`。
- 不为抢救开设置项：抢救落盘照走既有审批。
- 不改 Hive 模型、不新增 box、不涉及备份/导出字段。

## 3. 工具契约：`workspace.patch` 四种形态

`workspace.patch` 已有两种互斥形态（整文件写 / 精确补丁），本次在其中增加两种：

| 形态 | 参数 | 语义 |
|---|---|---|
| 整文件写（现状） | `path` + `content` | 覆盖写 |
| 精确补丁（现状） | `path` + `expectedSha256` + `expectedFragment` + `replacement` | 片段替换 |
| **追加** | `path` + `content` + `append: true` | 文件不存在则创建；存在则读回当前文本、写回「旧文 + 新段」 |
| **合并** | `path` + `parts: [..]` | 按数组顺序拼接各分段，结果原子写入 `path`；单段即原子提升 |

实现位置：

- schema 与 handler：`default_work_task_runner_tools.dart:343`。handler 的 `content is String` 分支（`:374`）按 `append` 分流；新增 `parts` 分支。
- 实际写入：与 `write`（`stage02_workspace_file_tool.dart:321`）并列，复用同一条「同目录临时文件 + 原子替换」路径；追加 = 读旧文 + 拼接 + 同一路径写回；合并 = 依序读各分段 + 拼接 + 同一路径写回。
- 参数校验：`_validateWorkspacePatchArguments`（`agent_decision_parser.dart:615`）扩展互斥规则。
- 审批与快照：两者都挂在既有的 `mutationPipeline`（`default_work_task_runner_tools.dart:357`）上，`_mutationApprovalGate`（`default_work_task_runner_mutation_policy.dart:366`）原样生效，不新增审批通道。

### 3.1 校验规则

- 四种形态互斥：`append` 只与 `content` 同现；`parts` 与 `content`、`expectedSha256`、`expectedFragment`、`replacement` 全部互斥；`parts` 必须是非空字符串数组。
- `append: true` 缺 `content` → 报错（不能"追加空"）。
- 分段数量与总字节设上界（避免病态读取）；超界直接失败并说明。
- 合并按数组顺序拼接，**不排序、不去重**：顺序是模型的契约。

### 3.2 边界与既有语义

- **只吃 UTF-8 文本**，与 `workspace.read`（`stage02_workspace_file_tool.dart:147`）同界。追加/合并遇到二进制或敏感文件时，沿用既有的拒绝与审批口径（`sensitive_mutation_requires_approval`）。
- **变更路径读的是整文**：追加/合并走 `WorkspaceFileService.readTextForMutation`，不套用面向模型的 12000 字符输出上限，只受字节上限约束（超上限即拒绝，绝不在残缺内容上拼接）。这条边界与 `write` 略有不同：`append` 会把旧文整份读进本进程，因此它只在已获准写入该文件的变更审批下执行，且内容不回显给模型。
- **计划与路径**：追加是「存在则 modify、不存在则 create」，与整文件写一致；合并是「目标 create/modify + 只读各分段」。路径解析仍走 `_mutationPath`，`_isExactPatch`（`default_work_task_runner_context.dart:172`）的自动改名开关按新形态决定：追加允许自动改名（与整文件写同类），合并不允许（目标路径是交付物，改名会造出近似重复）。
- **修订钉定不变**：同名文件仍被钉到存储的交付物绝对路径（`_namesSameFile`，`default_work_task_runner_context.dart:184`）。分段文件名与交付物不同名，不会被钉——这正是要的：钉定只作用于交付物本身，脚本与分段各按普通规则解析（见 CLAUDE.md「工作模式连续修改红线」的 2026-09-30 现场）。
- **审批次数**：审批范围条目记录的是「路径 + 动作集合」，而追加序列第一次是 `create`、其余是 `modify`。所以新建文件的长产物弹 **2** 次审批（create 一次 + 首次 modify 一次），此后同一路径免费；修订既有文件（始终 modify）只弹 **1** 次。这是既有范围语义的结果，不是本设计新增的摩擦。
- **去重语义不变**：`_operationKey`（`work_agent_loop_safety.dart:387`）是「工具名 + 规范化参数」，逐字相同的追加会被判为重复并跳过（`_skipCommittedTool`，`work_agent_loop_actions.dart:625`），模型会收到「已跳过已提交的重复变更」。这是刻意取舍：拿「偶发合法重复被拦（可见、可改写法）」换「重复内容静默翻倍」。**本设计不改去重键**；若将来要支持"同内容追加两次"，那是一次独立的去重键改造。
- **合并覆盖已存在的目标**：修订场景下目标本来就存在，合并就是要替换它（走原子替换，与整文件写同类）；`overwrite:false` 时按既有口径拒绝并报 `targetExists`。
- **分段文件在合并后保留**：它们是可审计的中间产物，客户端不代删（删除需要审批，且会让"合并失败后重试"失去输入）。模型需要清理时自行 `workspace.delete`。
- **产物登记**：只有 `path`（最终产物）进 `declaredImpact` / `lastArtifactPaths`；分段文件不登记为交付物。

## 4. 截断抢救

### 4.1 触发

在 `work_agent_loop.dart` 现有的截断分支（`:549` 判定、`:563` 置 `truncatedOutputRetry`）内，满足全部条件才抢救：

1. `_responseHitsOutputLimit(response)` 为真；
2. 响应正文能被解析为**动作 JSON 的前缀**，且 `action=tool`、`tool.name=workspace.patch`；
3. `tool.arguments` 含大字符串参数（`content` 或 `replacement`），且已生成部分非空。

任一不满足 → 不抢救，走今天的路径（话术 + 协议重试，`maxProtocolRetries=3`）。

### 4.2 提取

按 JSON 字符串规则解码前缀，直到被切断处：

- 尾部残缺转义丢弃：末尾的单个 `\`、以及不完整的 `\uXX` 序列一律不进入结果；
- 成对转义按 JSON 语义还原（`\n`、`\"`、`\\`、`\uXXXX`）；
- 结果视为**不可信文本**，只做落盘，不参与任何协议判定。

### 4.3 落盘

- 目标路径：由模型自己的动作目标派生——同目录、`stem.rescue-<内容 sha256 前 8 位><扩展名>`（如 `三国杀.rescue-3f9a2b1c.html`）。用内容哈希而不是 `partN`：模型自己的分段文件也在 `partN` 命名空间里，撞名会把两次尝试的内容拼进同一个文件；哈希后缀让"同内容同名、不同内容不同名"，无需探测文件是否存在，任务恢复后依然幂等。
- **执行方式**：以一次真实的工具请求执行，而不是直写文件——即由循环合成 `workspace.patch {path: <派生分段路径>, content: <抢救文本>, append: true, overwrite: false}`，走与模型工具调用**完全相同**的动作管线（`work_agent_loop_actions.dart`）。
  - 好处：审批（`_mutationApprovalGate`）、快照、事件、检查点、去重全部原样生效；新路径按既有规则弹一次确认，已批准路径不重复弹窗。
  - 需要审批时按既有语义暂停任务（`waitingForApproval` + `pendingToolRequestJson`），用户批准后按既有恢复路径执行，不新造审批面。
  - 审批与事件的文案必须标明来源为**截断抢救**，与模型主动请求区分开。
- 抢救动作**不进入模型的对话上下文**（不是模型的决策），只以提示形式告知结果。

### 4.4 为什么不做更严的前置校验

`workspace.read` 不返回 sha256，模型拿不到目标文件哈希，因此无法要求追加携带 `expectedSha256`（精确补丁形态能用它，是因为模型刚写过该文件、拿到了 `afterSha256`）。并发与晚到写入改由既有的原子替换与审批指纹兜住。

### 4.5 通知与续写提示

- 落盘成功后发一条公开事件，例如「已抢救被截断的输出：N 字已写入 `<分段路径>`，请继续追加余下内容」；`safeMetadata` 记 `salvagedCharacters`、`partPath`、`truncatedTargetPath`（`truncated` 一并保留，便于与 §1.2 的表对账）。
- 下一次决策的提示把 `_truncatedOutputChunkingAdvice` 换成**具体指令**，并**提升为独立 message**（不再混在大 JSON blob 里）：已写入哪个文件、多少字、抢救内容的末尾若干字符、下一步用 `append` 继续写哪个文件、收尾用 `parts` 合并到哪个目标、以及"不要重写已写入的前缀"。
- 提示里的"末尾若干字符"是有界的（几百字量级），用来让模型无缝续写，不把 2 万 token 的已生成内容回灌进 prompt。

### 4.6 抢救失败

派生路径被拒（不在授权目录）、审批被拒、写入失败时：不阻断任务，发一条带原因的公开事件，退回话术路径（照旧协议重试）。抢救只是止损，不能成为新的失败源。

## 5. 提示词契约改写

- `agent_prompt_builder.dart:48` 那段「约 8k token + 独立分段文件 + pandoc 合并」整段重写：
  - 分块配方换成新语义——`append` 逐段追加到分段文件（每段 content ≤3000 字），全部写完用 `parts` 合并成目标；
  - 「约 8k token」是过时口径（真实为能力表派生的上限，本机为 20480），改成不给死数字的可执行规则（字数 + "上限由工具层强制"），避免写死假值；
  - 明确「合并不再需要 `command.run`」，但 docx/xlsx 等转换仍要 `command.run`。
- `document_skill_templates.dart:50` 同一句契约同步改写。
- `_truncatedOutputChunkingAdvice`（`work_agent_loop_retry.dart:10`）同步到新配方。
- `_outputBudgetMarginDivisor` 与 `_truncatedOutputDetail` 的注释按新口径复核。

## 6. 与既有约束的核对

| 约束 | 本设计的处理 |
|---|---|
| 审批范围语义（同任务内已批准路径不重复弹窗、新增路径必须补充审批） | 追加/合并/抢救全部走 `_mutationApprovalGate`，不绕过 |
| 快照与撤销 | 追加是 modify 计划、合并是 create/modify 计划，均走既有快照；无快照能力时按既有 `waitingForApproval` 要求显式批准 |
| 工作模式连续修改红线（排队、修订钉定只作用同名文件） | 不改调度；钉定规则原样，分段名不被钉 |
| 重复变更去重 | 键不变；后果已在 §3.2 写明 |
| 交付守卫 / 产物路径 | 合并后的目标才可能成为交付物；分段不登记 |
| 敏感文件 | 追加需读旧文，按既有敏感读/写口径要求批准 |
| 数据清除 / 任务删除闸门 | 不涉及：不新增持久化键、不改事件存储写入路径 |
| 导出/备份 | 不涉及：不新增字段 |

## 7. 失败路径与用户可见行为

| 情形 | 行为 |
|---|---|
| 追加/合并路径越界或未授权 | 既有 `pathRejected` / 审批弹窗，文案照旧 |
| 追加到敏感文件且未批准 | 既有敏感审批 |
| 逐字相同的追加 | 跳过 + 「已跳过已提交的重复变更」（模型可见） |
| 合并时某分段读不到 | 失败并点名缺失分段，不改动目标文件 |
| 抢救无法提取前缀 | 不抢救，走话术 + 协议重试 |
| 抢救落盘失败/被拒 | 事件说明原因，退回话术路径，任务不因抢救失败而失败 |
| 协议重试用尽 | 照旧失败（`maxProtocolRetries=3`） |

## 8. 测试计划

- **参数校验**：四形态互斥矩阵、`append` 缺 `content`、`parts` 空数组/非字符串/超界（`test/work_mode/agent_decision_parser_test.dart`）。
- **追加语义**：不存在→创建；存在→追加且旧内容保持（含 CJK、末尾无换行、空文件）；`overwrite:false` 与已存在文件冲突；敏感文件未批准被拒；逐字相同追加被判重复跳过。
- **合并语义**：单段原子提升；多段顺序拼接；目标已存在时的替换；分段缺失/顺序异常（不排序）；分段含敏感内容未批准。
- **抢救提取**：截断点在字符串中间、在转义序列中间（半个 `\`、半截 `\uXX`）、在 JSON 结构处（无大字符串参数）、`replacement` 形态、正文完全不可解析 —— 均应给出确定结果。
- **循环集成**：截断 → 抢救落盘 → 续写提示 → 模型 append → merge → 交付成功；抢救被拒 → 退回话术 → 协议重试用尽失败。
- **回归**：整文件写与精确补丁两条现状路径的行为与文案不变。
- 依 CLAUDE.md 的测试环境规则：Hive 写操作包 `tester.runAsync()`，单用例超 30 秒视为疑似死循环。

## 9. 影响文件（预估）

- `lib/features/work_mode/default_work_task_runner_tools.dart`（schema + handler 分支）
- `lib/features/work_mode/stage02_workspace_file_tool.dart`（追加/合并实现）
- `lib/features/work_mode/agent_decision_parser.dart`（校验与错误文案）
- `lib/features/work_mode/work_agent_loop.dart`、`work_agent_loop_retry.dart`（抢救触发、提示、事件）
- `lib/features/work_mode/work_agent_loop_checkpoint.dart`（续写提示提升为独立 message）
- `lib/features/agentic/agent_prompt_builder.dart`、`document_skill_templates.dart`（契约）
- 对应测试与 `CLAUDE.md` 的「分块写」契约段

## 10. 已考虑并放弃的方案

| 方案 | 放弃原因 |
|---|---|
| 抢救内容直接覆盖交付物路径 | 修订类任务会在第一段就毁掉旧版本，中途失败只剩半截产物 |
| 抢救只回灌提示、不落盘 | 模型必须重吐一遍已生成内容，等于省不下第二遍 |
| 新增 `workspace.append` / `workspace.merge` 两个工具 | 用户选择不扩工具表 |
| `workspace.patch` 加 `append` 但把合并仍留给 `command.run` | 合并要走 shell 审批，比"一把写完"更贵，模型自然不选分块 |
| 抬高能力表 `maxOutput` 声明值 | 只是把墙往后挪；产物更大照样撞，且每次失败更贵 |
| 要求追加携带 `expectedSha256` | 模型无法获得哈希，该要求会让这条路走不通 |

## 11. 开放问题

- 抢救是否覆盖**修复请求**（repair）本身被截断的情形：v1 只处理主决策响应，repair 截断维持现状；若线上仍高频，再评估。
- 是否把同一套机制推广到 `workspace.document` 的大内容写入：v1 只覆盖 `workspace.patch`。
