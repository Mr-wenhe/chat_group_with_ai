# Agentic 技能显示与文件附件交付修复方案

> 状态：Proposed
> 日期：2026-07-13
> 范围：角色“行动能力”显示、专家 Skill 安装、Agentic 文件交付、附件一致性、追问续写与 API 错误可观测性

## 1. 背景与问题

当前 Agentic 体验出现了两类直接影响交付可信度的问题：

1. 角色编辑页的“推断技能”“可安装专家 Skill”“行动 N”混用不同语义。用户无法判断哪些能力已真实安装、哪些只是本轮可推断流程，且数字不会随着开关或权限改变。
2. 文件任务把“工作区写入成功”“附件复制成功”“聊天消息显示成功”视为同一件事。它们实际上是三个独立步骤，导致“请查看附件”但没有附件、后续补充资料被当作普通聊天并贴出 HTML 的问题。

截图暴露出的具体失败模式：

| 现象 | 已确认原因 | 受影响代码 |
|---|---|---|
| “行动 3”难以理解且看起来不变 | 数字等于推断技能数 + `skillIds` 数量，不统计工具权限或开关 | `action_skill_count.dart` |
| 编辑页看不到 Superpowers / Planning With Files | 页面只展示按角色资料推荐的模板，而不是完整内置目录 | `ai_character_form_page.dart`、`skill_download_service.dart` |
| “文件已写入，请查看附件”但消息无附件 | 附件复制异常被 `catch` 后仅 `debugPrint`，文本已提前声称附件存在 | `chat_room_page.dart` 的 `_attachmentsForAgentToolResult` |
| 用户补充主页资料后被贴出 HTML | 分类器只看当前消息；补充资料不含文件任务关键词，走普通流式聊天 | `chat_room_page.dart` 的 `_generateAiReply` |
| API 500 显示为 `Instance of 'ResponseBody'` | SSE 异常路径未异步读取 `ResponseBody`，丢失真实错误体 | `chat_api_service.dart` |
| 生成 `star.html` / 星空页面却不符合主页需求 | 只验证路径安全和基本文件可读，不验证产物是否满足用户请求；Prompt 中存在星空场景文件名示例 | `agent_runtime.dart`、`agent_prompt_builder.dart` |
| 进度停在“正在规划任务，接下来会持续汇报” | 规划阶段没有心跳或阶段级超时；模型请求最多等待 120 秒，进度回调只在审批或工具完成后才触发 | `agent_runtime.dart`、`chat_room_page.dart` |

## 2. 目标与非目标

### 目标

- 用户能分清“推断能力”“已安装 Skill”“工具权限”和“当前可调用工具”。
- 内置 Skill 目录完整可见，推荐项只是排序/标识，不再决定可见性。
- 手动安装一个模板后，角色拥有真实、可持久化、可注入 Prompt 的 `CharacterSkill`。
- 只有 `MediaAttachment` 创建成功，聊天文本才可以说“查看附件”。
- 用户在同一轮文件任务后补充资料时，系统将其识别为对现有产物的更新，而不是普通闲聊。
- API/桥接失败显示可读、可定位的错误，绝不显示 `Instance of 'ResponseBody'`。
- Agent 任务必须在可见时间内持续更新进度，或者明确进入失败、重试、等待批准或可恢复状态；不能无限停留在“规划中”。

### 非目标

- 本次不引入第三方插件市场、MCP 动态插件安装或云端文件同步。
- 本次不重写整个 `ChatRoomPage`；实现应遵循已存在的页面拆分计划。
- 本次不允许普通聊天自动写文件。续写只针对明确或已激活的产物任务。

## 3. 决策一：重定义技能显示与安装语义

### 3.1 现状

当前“行动 N”的公式是：

```text
行动数 = CharacterSkillResolver.defaultsFor(character).skills.length
       + character.skillIds.length
```

推断技能来自姓名、职业、标签和 System Prompt；它们不一定持久化，也不会因为勾选工具权限而改变。编辑页勾选模板只保存模板 ID 到 `AICharacter.skillIds`，但不会在该路径创建 `CharacterSkill` 记录。

另外，`CharacterSkillBox` 是全局 Hive box，而 `ExpertSkillTemplate.instantiateFor` 目前使用模板 ID 作为 skill ID。多个角色安装同一个模板时存在同键覆盖风险。

### 3.2 决策

将 UI 和数据模型区分为三类：

| 类别 | 定义 | 是否持久化 | UI 展示 |
|---|---|---|---|
| 推断工作流 | 从角色资料即时推导的基础提示流程 | 否 | “推断能力（只读）” |
| 已安装 Skill | 绑定到角色、可跨会话复用的完整 `CharacterSkill` | 是 | “已安装 Skill” |
| 内置模板目录 | 应用预置的可安装模板 | 模板本身否；安装实例是 | “全部内置 Skill” |

`行动 N` 改为明确的双计数，而不是一个混合数字：

```text
行动：3
推断 2 · 已安装 1
```

若 UI 空间不足，角色卡片显示 `行动 3`，编辑页必须显示上述拆分说明与详情。

### 3.3 数据模型与迁移

为避免多个角色的模板 Skill 发生 Hive key 冲突，新增稳定的模板来源字段：

```dart
class CharacterSkill {
  // 新增 HiveField，允许旧数据为空。
  String? templateId;
}
```

安装后：

```text
CharacterSkill.id         = UUID（每个角色唯一）
CharacterSkill.characterId = 当前角色 ID
CharacterSkill.templateId = 'general.superpowers'
AICharacter.skillIds      = [CharacterSkill.id, ...]
```

迁移规则：

1. 对历史 `skillIds` 中命中的 `ExpertSkillCatalog` 模板 ID，按当前角色创建独立实例；
2. 用新 UUID 替换角色的旧模板 ID；
3. 保留历史非模板 Skill ID；
4. 若全局 box 中存在同模板 ID 的旧记录，仅把它作为模板数据来源，不把它共享给多个角色；
5. 迁移幂等：重复启动不应重复创建实例。

### 3.4 UI 行为

角色编辑页调整为：

```text
行动能力开关
├─ 推断能力（只读，说明由角色资料自动得出）
├─ 已安装 Skill（可移除）
├─ 全部内置 Skill（可安装；推荐项带“推荐”标记）
└─ 工具权限（独立开关）
```

`Superpowers Workflow` 和 `Planning With Files` 必须始终在“全部内置 Skill”可见；对当前角色不匹配时只是不标记为推荐，不能消失。

新建 `CharacterSkillInstallationService` 负责：

- `installTemplate(character, templateId)`；
- `uninstallSkill(character, skillId)`；
- `installedSkillsFor(character)`；
- `migrateLegacyTemplateSkillIds(character)`。

编辑页不再直接拼接 `skillIds`，而在保存角色后调用 installation service 同步选择状态。

## 4. 决策二：把文件写入和附件交付建模为一个可验证结果

### 4.1 根因

当前 `workspace.patch` 成功后，`AgentRuntime` 立即生成“请查看附件”的交付文本。随后页面才尝试把工作区文件复制到角色媒体目录。复制失败被吞掉后，消息仍保留“附件已生成”的文字。

这使应用把三个不同状态混为一谈：

```text
工作区文件写入成功
      ≠
聊天附件创建成功
      ≠
用户已获得可打开的交付物
```

### 4.2 决策

引入 feature 内部结果模型，统一管理产物状态：

```dart
class ArtifactDeliveryResult {
  final List<ArtifactFile> workspaceArtifacts;
  final List<MediaAttachment> attachments;
  final List<ArtifactDeliveryFailure> failures;

  bool get hasDeliveredAttachment => attachments.isNotEmpty;
  bool get hasWorkspaceArtifact => workspaceArtifacts.isNotEmpty;
}
```

消息文案必须由最终 `ArtifactDeliveryResult` 决定：

| 最终状态 | 用户可见文案 | UI 行为 |
|---|---|---|
| 文件 + 附件均成功 | “已生成 `page.html`，请查看附件。” | 展示附件卡片 |
| 文件成功、附件失败 | “文件已写入工作区，但附件创建失败；可重试附件回贴。” | 展示失败状态和“重试附件”按钮 |
| 文件失败 | “未生成文件：<简洁原因>。” | 不声称附件存在 |
| 无文件任务 | 普通聊天文案 | 不展示交付承诺 |

### 4.3 执行顺序

```text
AgentRuntime.workspace.patch
  → 写入工作区
  → 读回并验证
  → 创建角色媒体副本
  → 构造 ArtifactDeliveryResult
  → 写入 Message.media
  → 生成最终用户文案
```

关键规则：

- `_appendFilePreview` 不得在附件创建前写入“点击附件查看”；
- `_attachmentsForAgentToolResult` 不得吞掉异常。它应返回 failure record，包含相对路径和安全的错误分类；
- 文件副本失败后必须可基于 `AgentTask` 的已执行 `workspace.patch` 重试，不应再请求 LLM；
- UI 不显示绝对文件路径，不记录文件正文到普通日志。
- `AiAttachmentService` 生成的 `ai_reply_<timestamp>.md` 只能作为“把本轮文字整理成 Markdown”的普通附件，绝不能被当作“用户要求的完整 HTML/代码文件”交付；代码任务必须由 `workspace.patch` 的实际产物回贴。

### 4.4 产物匹配校验

对于“个人主页”等高风险创作任务，写入前建立最小 `ArtifactSpec`：

```dart
class ArtifactSpec {
  final String expectedPath;       // 未指定时默认 page.html
  final ArtifactKind kind;         // personalHomePage / report / sourceCode
  final List<String> requiredFacts;
  final List<String> requiredSections;
}
```

个人主页默认要求：

- HTML 文件路径为 `page.html`（除非用户明确给出路径）；
- 包含用户已提供的姓名/身份；
- 至少有 Hero、简介、经历/作品、联系或行动入口中的约定区块；
- 设计风格只允许影响视觉，不得替换用户身份和核心内容。

如果生成结果未满足 spec，不写入且要求模型基于缺失项重新生成；不接受“HTML 合法但主题跑偏”的产物。

## 5. 决策三：支持文件任务的追问续写，并阻止普通聊天贴代码

### 5.1 根因

`AgenticTaskClassifier` 只根据最新用户消息判断。用户在上一轮要求生成主页、下一轮只补充姓名/职业时，第二轮不含“生成/修改/HTML/文件”等关键词，会进入普通流式聊天。

普通聊天可以让模型输出 HTML，但不会触发工作区写入或附件交付。非 Agentic 代码清洗也只是保守的文本兜底，不是交付流程。

### 5.2 决策

新增轻量的 `ArtifactContinuation` 状态，挂在活跃会话而不是依赖模型记忆：

```dart
class ArtifactContinuation {
  final String conversationId;
  final String artifactPath;
  final ArtifactSpec spec;
  final DateTime updatedAt;
  final ArtifactContinuationStatus status;
}
```

状态机：

```text
文件任务开始 → collectingDetails / generating
生成成功       → delivered
AI 明确追问资料 → collectingDetails
用户补充资料   → 继续同一 ArtifactSpec，强制 Agentic 更新
```

只有以下情形可把无关键词的消息升级为文件续写：

- 最近一条 AI 消息明确请求主页/报告所需字段；
- 会话存在 `collectingDetails` 状态；
- 用户明确说“继续、修改、补充、按刚才的文件”等。

其它普通聊天绝不自动写文件。

普通流式分支若检测到大段文件内容，必须：

1. 有活跃 `ArtifactContinuation`：转交 Agentic 写入流程；
2. 无活跃任务：隐藏代码正文并提示“未进入文件交付流程，未创建附件”；
3. 不得让模型自行宣称“我附上了”。

## 6. 决策四：修复 HTTP 500 错误可读性

SSE 请求使用 `ResponseType.stream`。HTTP 500 时的响应是 `ResponseBody`，当前 `toString()` 只得到类型名。

修复要求：

- 对非 200 的 `ResponseBody.stream` 异步读取，限制为前 4 KB；
- 尝试 JSON 解码 `error.message`、`message`、`detail`，否则返回截断纯文本；
- 将用户可见错误统一为 `模型服务返回 500：<安全摘要>`；
- 调试日志记录 provider、model、status、request id、body 摘要，不记录 API key、完整 prompt 或附件正文；
- 为 SSE 500/429/400 建立 MockDio 测试。

## 7. 决策五：保证 Agent 任务活性，避免规划阶段卡住

### 7.1 根因

截图中的“正在规划任务，接下来会持续汇报执行进度…”是 Agent 任务创建后立即写入的进度消息。随后页面 await `AgentRuntime.run()` 的首次模型规划请求。

当前实现存在以下活性缺口：

- 单次模型 completion 允许等待 120 秒；
- 初始 `planning` 阶段没有 `onProgress` 心跳；进度只会在“等待审批”或“工具完成”后更新；
- `AgentTask` 记录了 `planning` / `runningTool` 状态，但没有 deadline、最后心跳时间或超时原因；
- 任务恢复弹窗只在重新进入会话时触发，当前页面内卡住时没有“继续、重试、停止”入口；
- 普通流式回复有“停止生成”，但 Agentic `run()` 没有统一的取消令牌和用户可见的中止状态。

因此，模型网关慢、SSE 不结束、规划 Prompt 过长或上下文压缩卡住时，UI 会一直显示承诺性的“会持续汇报”，但用户没有任何可操作反馈。

### 7.2 决策

把 Agent 执行改为具有明确时限和心跳的状态机：

```text
queued → planning → waitingApproval → runningTool → finalizing → delivered
                    ↘ cancelled / timedOut / failed / partiallyCompleted
```

每个状态必须有：`enteredAt`、`lastHeartbeatAt`、`deadlineAt`、`attempt` 与可恢复动作。建议新增：

```dart
class AgentRunState {
  final String taskId;
  final AgentRunPhase phase;
  final DateTime enteredAt;
  final DateTime lastHeartbeatAt;
  final DateTime deadlineAt;
  final int attempt;
  final String userFacingDetail;
}
```

`AgentTask` 同步保存最小检查点字段，保证应用重启后仍能判断任务是等待批准、可恢复还是已过期。新增 Hive 字段时必须遵循兼容迁移并运行代码生成。

### 7.3 交互与超时策略

建议默认策略：

| 阶段 | 进度更新 | 超时后行为 | 用户操作 |
|---|---|---|---|
| `planning` | 立即显示“正在分析任务”；每 5 秒更新耗时/尝试次数 | 45 秒后重试一次；仍失败则结束为 `timedOut` | 停止、重试、转普通回复 |
| `waitingApproval` | 显示具体工具、目标相对路径和审批原因 | 不自动执行；30 分钟后过期 | 批准、拒绝、取消 |
| `runningTool` | 显示当前工具和步骤 `n/6` | 工具独立超时并保留检查点 | 停止、从检查点重试 |
| `finalizing` | 显示“正在整理结果/回贴附件” | 30 秒后使用已验证工具结果生成确定性总结 | 停止、重试回贴 |
| `delivered` | 显示文件名、验证和附件状态 | 不适用 | 打开附件、重试附件 |

整体任务可设为 90 秒软上限；达到上限时不静默等待，而是根据已完成步骤进入 `partiallyCompleted` 并提供“继续执行”。具体时限应做成常量/配置，并和产品文档保持一致；当前说明中的“45 秒”与 Runtime 实际 120 秒等待不得继续不一致。

### 7.4 取消与收尾

- `AgentRuntime.run` 接收 `CancellationToken` 或等效对象；
- 取消模型规划、工具执行或最终整理时，必须取消底层请求、停止 watchdog，并将 `AgentTask` 持久化为 `cancelled` 或 `partiallyCompleted`；
- 所有 `try/finally` 分支都必须清理 `_isAiReplying`、运行中的角色锁和进度定时器；
- 超时、取消、网络错误都必须追加一条最终状态消息，不能只留下 progress message；
- 已完成写文件但最终整理超时时，使用确定性结果直接交付，并继续执行附件回贴，不再等待另一次 LLM 调用。

### 7.5 可观测性

每个任务以 `taskId` 贯穿日志与 UI，至少记录：

```text
taskId, phase, attempt, elapsedMs, provider, model,
toolName, relativePath, resultStatus, attachmentCount, errorCategory
```

不得记录 API key、完整 prompt、文件正文或绝对用户路径。开发模式可在进度卡片显示“已等待 12 秒 / 正在重试 1/1”，便于区分正常模型思考与真正卡死。

## 8. 实施顺序与 PR 切分

### PR 1：Skill 数据与 UI 语义

- 增加 `CharacterSkill.templateId` 及 Hive 迁移；
- 引入 `CharacterSkillInstallationService`；
- 编辑页展示全部内置目录、推荐标识、已安装列表；
- “行动”拆分显示推断/已安装；
- 修复多角色安装同模板的 Hive key 冲突。

### PR 2：文件附件交付可靠性

- 引入 `ArtifactDeliveryResult`；
- 将最终交付文案延后到附件创建后；
- 保留附件失败状态并提供重试；
- 增加 `ArtifactSpec` 的个人主页最小校验。

### PR 3：追问续写与代码泄漏收敛

- 持久化 `ArtifactContinuation`；
- 让资料补充进入现有产物更新；
- 非 Agentic 文件正文不再直接展示；
- 为“主页首次请求 → 资料补充 → 更新同一文件”添加端到端测试。

### PR 4：API 错误诊断

- 正确读取 SSE 错误体；
- 提供安全的用户错误文案和诊断日志；
- 覆盖 500、超时、桥接不可用与附件失败。

### PR 5：Agent 任务活性与取消

- 引入 `AgentRunState`、watchdog 和阶段级 deadline；
- 为规划、审批、工具、整理、附件回贴建立明确阶段与最终状态；
- 新增停止、重试、继续执行入口；
- 任务超时后从检查点恢复，不重新执行已完成工具；
- 为“规划请求不返回”“工具不返回”“附件回贴失败”增加 Widget 与集成测试。

## 9. 验收测试

### 技能显示

- 数据科学家角色显示“推断 3 · 已安装 0”，而不是含糊的“行动 3”；
- 所有 9 个内置模板均可浏览；
- Superpowers 与 Planning With Files 在不匹配角色资料时仍可手动安装；
- 安装任意模板并保存后，已安装数量增加且重启后仍保留；
- 两个角色安装同一模板后，分别拥有独立 `CharacterSkill`，不会覆盖；
- 删除已安装模板不会改变推断能力数量。

### 文件与附件

- 成功写入 `page.html` 后，消息必须有 `MediaAttachment` 才显示“查看附件”；
- 媒体复制失败时，消息显示“附件创建失败”，不得显示“已附上”；
- 点击“重试附件”不调用 LLM，直接从工作区读回并回贴；
- “炫酷个人主页”不得被接受为未包含用户身份/页面区块的星空场景；
- 无活跃产物任务时，普通聊天输出 HTML 不会伪装成附件交付；
- 主页任务追问姓名、职业、配色后，更新同一个 `page.html` 并生成新附件。

### 错误处理

- SSE HTTP 500 显示服务端摘要，不出现 `Instance of 'ResponseBody'`；
- API 失败前不创建“文件已生成”消息；
- 本地桥接写入失败与模型 API 失败使用不同、可行动的提示。

### Agent 任务活性

- 开始任务后，`planning` 在 5 秒内至少显示一次可验证的状态更新；
- 模型规划超过阶段 deadline 时，任务显示重试或超时结果，不会永久停在“正在规划”；
- 用户可在规划、工具执行、最终整理阶段停止任务；
- 停止后 `_isAiReplying`、角色运行锁和 progress timer 均被释放，下一条消息可以发送；
- 已完成一个工具后超时，重进会话可从检查点继续，且不重复执行该工具；
- 写文件完成、LLM 最终整理超时时，仍能生成确定性交付消息并继续附件回贴；
- 用户要求“将完整 HTML 写入附件”时，不得用 `ai_reply_*.md` 的短摘要冒充 HTML 交付物。

## 10. 风险与约束

- `CharacterSkill` 增加 HiveField 后必须运行 `dart run build_runner build`，并验证旧 Hive 数据迁移；
- 产物续写状态必须有过期时间，避免数天后的普通聊天意外修改旧文件；建议 30 分钟无操作或用户明确结束后失效；
- 附件副本和工作区文件是双写，不能提供真正跨目录事务，因此必须保存可重试证据；
- 创意页面的视觉质量不适合完全靠结构验证；`ArtifactSpec` 只验证用户事实和必要结构，不评判审美；
- API 错误体可能含敏感上下文，日志和用户提示必须截断与脱敏。
- watchdog 只能解决“无限等待/无反馈”，不能替代 API 服务本身的稳定性；必须保留真实错误分类，避免把所有失败误报为超时。

## 11. 完成定义

完成后，用户应能明确看到：哪些能力是推断的，哪些 Skill 已安装；能主动安装任意内置模板；并且每一次“文件已生成/已附上”的承诺都对应一个可见、可打开、可重试的附件。用户补充上一轮文件所需资料时，应用更新该文件，不再把 HTML 粘贴到聊天气泡中。每个 Agent 任务都会持续更新到终态；模型、工具或附件任一步骤超时后，用户能得到明确原因和停止、重试或继续执行的选择，不会永久停在“正在规划”。
