# Bug 修复 / 功能增强提示词：Agentic 角色技能系统完善

> **用途**：将以下提示词复制到 Codex / Claude Code / 其他 AI 编程助手中执行。
> **前提**：执行前必须 99% 理解需求，有疑问先提问，不要猜测。

---

## 项目背景

这是一个 Flutter AI 群聊模拟器（`chat_group`），AI 角色由多个 LLM 提供商驱动（DeepSeek/Qwen/Zhipu/Moonshot/Baidu/自定义 OpenAI 兼容端点）。项目已有 Agentic 框架（`AgentRuntime`），但存在功能缺失和流程断裂问题。

**环境约束**：
- Flutter 3.24.0 fork（`3.24.0-1.0.pre.538`），Dart `3.6.0-134.0.dev`，**不能切换通道**
- 使用旧主题 API（`CardTheme`/`DialogTheme`），不支持 `Color.withValues`（3.25+ API）
- 第三方包版本需对齐 fork：新增依赖前必须在 fork 上 `flutter analyze` 验证
- `dependency_overrides` 已锁定 `file_picker`/`package_info_plus`/`wakelock_plus` 的版本范围
- macOS App 已关闭 App Sandbox（Agentic 桥接服务需要 `bind 127.0.0.1:54263`）

## 当前已有架构（不要重复造轮子）

### 已实现的 Agentic 组件

| 组件 | 文件路径 | 功能 |
|------|----------|------|
| `AgentRuntime` | `lib/features/agentic/agent_runtime.dart` | 多步骤工具执行引擎，最多 6 步，120s 超时 |
| `AgentPromptBuilder` | `lib/features/agentic/agent_prompt_builder.dart` | 构建规划/结果整理提示词 |
| `AgenticTaskClassifier` | `lib/features/agentic/agentic_task_classifier.dart` | 判断用户消息是否需要 Agentic 链路 |
| `CharacterSkillResolver` | `lib/features/agentic/character_skill_resolver.dart` | 根据角色文本自动匹配默认技能 |
| `ExpertSkillCatalog` | `lib/features/agentic/expert_skill_catalog.dart` | 6 个内置专家模板 |
| `SkillDownloadService` | `lib/features/agentic/skill_download_service.dart` | 从模板实例化技能 |
| `SkillGenerationService` | `lib/features/agentic/skill_generation_service.dart` | 解析 LLM 生成的技能 JSON |
| `ToolRequest` | `lib/features/agentic/tool_request.dart` | 工具请求解析（多格式兼容） |
| `LocalAgentBridgeServer` | `lib/features/agentic/tools/local_agent_bridge_server.dart` | 本地 HTTP 桥接（端口 54263） |
| `WorkspaceFileTool` | `lib/features/agentic/tools/workspace_file_tool.dart` | 文件读写/命令执行 |
| `BrowserContextTool` | `lib/features/agentic/tools/browser_context_tool.dart` | 浏览器上下文 |
| `ChatApiService` | `lib/services/chat_api_service.dart` | LLM 调用（流式/非流式） |
| `ChatRoomPage` | `lib/features/chat_group/chat_room_page.dart` | 聊天主页面，`_runAiRound`/`_generateAgenticReply` |

### 已有的 7 种工具

`workspace.list` / `workspace.read` / `workspace.patch` / `command.run` / `browser.context` / `skill.create` / `skill.download`

### 已有的重试逻辑（需要增强）

| 场景 | 当前 | 目标 |
|------|------|------|
| 普通流式回复失败 | 2 次 | **5 次** |
| Agent 规划阶段 | 2 次 | **5 次** |
| Agent 格式解析失败 | 1 次 | **3 次**（含格式纠正） |

### 已有的上下文管理（需要增强）

| 机制 | 当前 | 问题 |
|------|------|------|
| 群聊历史消息 | 最近 20 条 | **无自动摘要+清空重启机制** |
| Agentic 对话历史 | 最近 12 条 | **上下文满了直接截断，丢失核心信息** |
| 群聊记忆摘要 | ≥8 条触发，每 10 分钟更新 | **仅在群聊维度，Agentic 任务无独立摘要** |
| 角色记忆进化 | 消息 ≥2 条触发 | 存在但 Agentic 任务完成后未触发 |

---

## 需要修复/增强的问题

### 问题 1：AI 角色无法自动发现和使用匹配职业技能

**现状**：`CharacterSkillResolver.defaultsFor()` 根据角色文本关键词匹配默认技能，但匹配规则简单（仅检查"代码/code/flutter"等关键词），且生成的技能 instructions 较粗略。

**目标**：
- AI 角色在收到用户消息时，能根据**用户意图 + 角色职业/技能标签**自动选择最匹配的技能
- 如果没有匹配的内置技能，AI 角色应能**主动调用 `skill.create` 工具**为自己生成新技能（如文档技能、代码审查技能、写代码技能等）
- 如果 `skill.create` 不可用（角色没有 `skillCreate` 权限），应**自动补充权限**（已有 `_ensureAgenticTaskPermissions`，需扩展其触发条件）

### 问题 2：缺少内置的 create-skills / superpowers / planning-with-files 技能

**现状**：`ExpertSkillCatalog` 有 6 个模板（Flutter Reviewer/Product Strategy/Browser Research/Writing Voice/Support Coach/Expert Builder），但**没有**以下技能：
- `create-skills`（技能创建器）
- `superpowers`（通用增强工作流）
- `planning-with-files`（文件化规划）

**目标**：
- 在 `ExpertSkillCatalog` 中新增上述 3 个内置技能模板
- 每个技能有清晰的 `instructions`（步骤化指导）、`requiredPermissions`、`domain` 分类
- 技能描述要让 LLM 能正确匹配用户意图

### 问题 3：上下文满了直接截断，核心信息丢失

**现状**：聊天历史和 Agentic 对话历史都是简单截断（20 条 / 12 条），没有"上下文满 → 自动摘要 → 清空重启"的机制。也没有将压缩后的上下文沉淀为角色长期记忆的能力。

**目标**：
- 新增 `ContextWindowManager`，**当对话累计上下文达到约 200k token 时**触发压缩：
  1. 调用 LLM 对当前上下文进行**核心内容提炼**（保留关键事实、决策、待办、角色关系、用户偏好、未完成的任务）
  2. 将提炼后的摘要**写入该 AI 角色的永久记忆**（`AICharacter.memorySummary` / 分层 `CharacterMemory` 的 facts/relationshipNotes/personaGrowth 三层），使其成为跨会话持久化的角色记忆——下次聊天自动加载，无需从上次上下文接续
  3. 压缩后的摘要同时注入当前 `system` 消息，清空旧的对话历史，从摘要 + 下一条用户消息重新开始
  4. **整个过程不能中断用户对话**（异步执行，或在下一条消息发送前完成）
- 上下文摘要应区分群聊和私聊：
  - 群聊：包含角色关系、话题进展、关键决策、群体记忆
  - 私聊：包含角色记忆、用户偏好、对话焦点、跨聊天长期记忆
- Agentic 任务执行期间的上下文也应管理：多步骤工具调用产生的中间结果过长时，自动压缩，压缩结果同样沉淀进角色永久记忆
- 200k 阈值应可配置（常量 `kContextCompressThresholdTokens = 200000`），便于后续调参

### 问题 4：LLM 报错重试次数不足

**现状**：普通回复重试 2 次，Agent 规划重试 2 次，格式纠正 1 次。

**目标**：
- **所有 LLM 调用统一重试 5 次**（普通聊天回复 / Agentic 规划 / Agentic 结果整理 / 技能生成 / 上下文摘要）
- 重试策略：
  - 第 1 次：立即重试
  - 第 2 次：延迟 500ms
  - 第 3 次：延迟 1500ms
  - 第 4 次：延迟 3000ms，降 temperature 到 0.6
  - 第 5 次：延迟 5000ms，降 temperature 到 0.4，切换为非流式
- 仅对瞬态失败重试（网络错误/429/502/503/504/超时），4xx 客户端错误不重试
- 5 次全部失败后，向用户输出友好的错误提示（包含失败原因和建议操作），**不崩溃**

### 问题 5：Agentic 流程在中间步骤中断后无法恢复

**现状**：`AgentRuntime.run()` 在执行到第 6 步或超时后直接返回 `failed`，之前已执行的工具操作（如已写入的文件）不会回滚也不会提示。

**目标**：
- Agentic 任务执行过程中如果 LLM 报错，**先重试 5 次**（见问题 4）
- 5 次重试全部失败后，**保留已完成的工具操作结果**（如已写入的文件），并生成"部分完成"报告
- 用户可以选择"继续执行"或"放弃"
- **期间不能中断**：即使用户退出聊天页面再回来，Agentic 任务的状态应能恢复（可通过 Hive 持久化任务状态）

### 问题 6：Agentic 任务完成后输出文件内容验证

**现状**：`_executeWorkspacePatch()` 写文件后读回内容生成确认信息，但不会验证文件内容是否正确（如 HTML 是否结构完整、代码是否能通过 analyze）。

**目标**：
- 文件写入后，根据文件类型进行基本验证：
  - `.dart` → 运行 `flutter analyze`（已有 `command.run` 工具）
  - `.html` → 检查标签是否闭合
  - `.md` → 检查标题层级是否合理
  - 其他 → 检查文件非空且大小合理
- 验证结果附加到 Agentic 回复中
- **必须自测**：实现完成后，在本地运行 App，发送一条 Agentic 消息（如"帮我写一个 HTML 页面"），验证整个流程跑通，生成的文件内容正确

---

## 实现要求

### 技术约束

1. **Flutter 3.24 fork 兼容**：不能使用 `Color.withValues`、`CardTheme` 的新 API 等 3.25+ 特性
2. **依赖管理**：新增 Dart 包前先在 fork 上 `flutter analyze` 验证，遇到 3.25+ API 报错就下调版本
3. **Hive 存储**：新增数据模型需注册 TypeAdapter，修改 `HiveType`/`HiveField` 后运行 `dart run build_runner build`
4. **Riverpod**：新增 Provider 使用注解方式，放在 `lib/features/*/providers/` 下
5. **中文注释**：所有新增代码使用中文注释
6. **方法拆分**：单个方法不超过 80 行，过长需拆分封装

### 实现步骤建议

#### Step 1：扩展内置技能目录
- 在 `ExpertSkillCatalog` 中新增 `create-skills`、`superpowers`、`planning-with-files` 三个技能模板
- 每个技能包含完整的 `instructions`、`requiredPermissions`、`domain`、`description`
- 更新 `recommendForText()` 的关键词匹配规则

#### Step 2：增强技能自动发现与创建
- 扩展 `CharacterSkillResolver`：当用户意图匹配不到现有技能时，返回"建议创建技能"的提示
- 在 `AgentPromptBuilder.buildToolPlanningPrompt()` 中注入"如果没有匹配技能，可以使用 `skill.create` 创建"的引导
- 确保 `_ensureAgenticTaskPermissions` 在检测到技能创建意图时自动补充 `skillCreate` 权限

#### Step 3：实现上下文窗口管理器（200k 阈值 + 沉淀角色永久记忆）
- 新建 `lib/features/agentic/context_window_manager.dart`
- 实现 `ContextWindowManager`：
  - `static const int kContextCompressThresholdTokens = 200000;` → 可配置阈值
  - `shouldSummarize(messages)` → 估算上下文 token 数是否达到阈值（用粗略规则：1 token ≈ 4 字符，或直接按字符数 / 4 估算）
  - `summarize(messages, character, groupId)` → 调用 LLM 提炼核心内容
  - `compact(messages, summary)` → 用摘要替换旧消息，清空历史
  - `persistToCharacterMemory(character, summary)` → 将摘要写入 `AICharacter.memorySummary` 及分层 `CharacterMemory`（facts/relationshipNotes/personaGrowth），**落库持久化**，成为角色跨会话记忆
- 在 `ChatRoomPage._buildApiMessages()` 和 `_buildDirectApiMessages()` 中集成（群聊/私聊均触发）
- 在 `AgentRuntime.run()` 中集成 Agentic 上下文压缩，压缩结果同样落库到角色记忆

#### Step 4：统一重试机制
- 新建 `lib/core/retry_handler.dart`
- 实现 `RetryHandler.executeWithRetry<T>()`：
  - 参数：最大重试次数（默认 5）、延迟策略、降级策略
  - 自动识别瞬态失败
- 将 `ChatApiService`、`AgentRuntime`、`ContextWindowManager` 中的 LLM 调用都改用 `RetryHandler`

#### Step 5：Agentic 任务状态持久化
- 新建 `AgentTaskState` Hive 模型，记录任务 ID、角色 ID、当前步骤、已执行操作
- 在 `AgentRuntime.run()` 的每一步执行后持久化状态
- App 重启后检测未完成的 Agentic 任务，提示用户是否恢复

#### Step 6：文件输出验证
- 在 `_executeWorkspacePatch()` 或 `_continueAfterToolResult()` 中增加文件验证逻辑
- 根据文件扩展名分发到对应的验证器

#### Step 7：自测验证（必须，使用 @电脑 / 控制电脑能力）
- **自测方式**：使用 Codex / AI 编程助手的**控制电脑能力（@电脑）**，即由 Agent 直接在本机执行命令、启动 App、读取输出完成端到端验证，而非仅静态分析
- 验证步骤：
  1. 运行 `flutter analyze`，确保零错误
  2. 运行 `flutter test`，确保所有测试通过
  3. 启动 App（`flutter run`），在私聊中发送 Agentic 消息（如"帮我写一个简单的 HTML 页面"），验证：
     - AI 角色正确识别为 Agentic 任务
     - AI 角色选择/创建匹配技能
     - 工具调用流程完整执行
     - 生成的文件内容正确（HTML 结构完整、可在浏览器打开）
     - LLM 报错时重试 5 次的逻辑生效
  4. 构造长对话（或多轮 Agentic 任务）使上下文逼近 200k token，验证自动压缩触发，且压缩摘要已写入角色永久记忆（重启 App 后记忆仍在）
  5. 启动一个 Agentic 任务，中途强制终止 App，重新打开后验证任务状态可恢复
  6. 在群聊中重复上述验证
- **必须贴出**：测试过程中生成的文件路径和文件内容（要有正确内容，不能只贴路径）

---

## 验收标准

| # | 验收项 | 通过条件 |
|---|--------|----------|
| 1 | 内置技能扩展 | `ExpertSkillCatalog` 包含 create-skills/superpowers/planning-with-files 三个模板，`recommendForText()` 能正确匹配 |
| 2 | 技能自动发现 | AI 角色收到 Agentic 消息时，自动匹配或创建技能，不需要手动配置 |
| 3 | 上下文自动摘要+沉淀 | 对话累计上下文达 ~200k token 后自动摘要，摘要注入 system 消息且**写入角色永久记忆**（跨会话持久化），旧消息清空，对话不中断 |
| 4 | LLM 重试 5 次 | 所有 LLM 调用失败后重试 5 次，策略正确（递增延迟+降 temperature+切换非流式） |
| 5 | Agentic 不中断 | Agentic 任务执行中 LLM 报错后重试，不直接失败；App 退出再进入可恢复 |
| 6 | 文件验证 | 生成的文件经过验证，验证结果附加到回复中 |
| 7 | 自测通过 | `flutter analyze` 零错误，App 运行时 Agentic 流程跑通，生成文件内容正确 |
| 8 | 文件输出 | 测试生成的文件路径和内容已贴出 |

---

## 关键文件清单（修改/新增）

### 需要修改的文件

| 文件 | 修改内容 |
|------|----------|
| `lib/features/agentic/expert_skill_catalog.dart` | 新增 3 个内置技能模板 |
| `lib/features/agentic/character_skill_resolver.dart` | 增强技能匹配逻辑，引导技能创建 |
| `lib/features/agentic/agent_prompt_builder.dart` | 注入"无匹配技能时使用 skill.create"引导 |
| `lib/features/agentic/agent_runtime.dart` | 集成重试机制、上下文压缩、状态持久化 |
| `lib/features/chat_group/chat_room_page.dart` | 集成 ContextWindowManager、扩展重试 |
| `lib/services/chat_api_service.dart` | 统一使用 RetryHandler |
| `lib/features/agentic/agentic_task_classifier.dart` | 扩展触发关键词（文档/审核/写代码等） |

### 需要新增的文件

| 文件 | 功能 |
|------|------|
| `lib/core/retry_handler.dart` | 统一重试机制 |
| `lib/features/agentic/context_window_manager.dart` | 上下文窗口管理器 |
| `lib/features/agentic/file_validator.dart` | 文件内容验证器 |
| `lib/core/models/agent_task_state.dart` | Agentic 任务状态模型（Hive） |
| `test/agentic/context_window_manager_test.dart` | 上下文管理器测试 |
| `test/agentic/retry_handler_test.dart` | 重试机制测试 |

---

## 注意事项

1. **不要破坏现有功能**：普通聊天、流式回复、群聊自动聊天、私聊主动联系等已有功能必须保持正常
2. **不要升级 Flutter/依赖版本**：所有代码必须在 3.24 fork 上编译通过
3. **代码生成**：修改 Hive 模型后运行 `dart run build_runner build`
4. **中文注释**：所有新增代码使用中文注释，方法过长需拆分
5. **气泡不加描边**：聊天 UI 修改时，消息气泡不加 border 边框（用户审美偏好）
6. **自测是必须的**：不要只验证编译通过，必须运行 App 实测 Agentic 流程跑通

---

## 执行前确认

在开始执行前，请确认你对以下需求有 99% 的信心理解：

1. AI 角色在私聊/群聊中能自动发现和使用匹配职业技能
2. 无匹配技能时，AI 角色主动调用 `skill.create` 为自己生成技能
3. 内置 create-skills / superpowers / planning-with-files 三个技能
4. 上下文每累计约 200k token 自动压缩，压缩摘要注入 system 消息并**写入 AI 角色永久记忆（跨会话持久化）**，旧消息清空重启，对话不中断
5. LLM 报错统一重试 5 次（递增延迟 + 降 temperature + 切换非流式）
6. Agentic 任务执行中不中断，App 退出再进入可恢复（任务状态持久化，必须做）
7. 文件输出验证
8. 实现后必须自测：运行 App，发送 Agentic 消息，验证流程跑通，贴出生成的文件

**如有任何不理解的地方，请先提问，不要猜测。**
**执行完毕后，必须使用本地环境自测，确保整个流程跑通。**
