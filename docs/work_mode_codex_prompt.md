# Codex 任务提示词：为 chat_group 新增「工作模式（Work Mode）」

> 把下面的内容整体复制给 Codex（或任何编码 Agent）。本提示词已对齐仓库真实代码（Flutter 3.24 fork、Riverpod + Hive），可直接引用文件路径与符号。

---

## 0. 任务一句话

把现有的「自治执行」从"靠自然语义自动识别工作流"改成**显式的「工作模式」开关**：开启后，当前群/私聊里的对话即视为该 AI 角色在"干活"——AI 依据自身角色信息（systemPrompt / role / memorySummary / skillIds / toolPermissions）自主规划工作、**强制自动调用 SKILL**、持续往聊天框回贴进度、**最终把生成的文件作为附件贴回聊天框**；关闭时则回到普通聊天模式（纯对话，不触发任何工作流）。

---

## 1. 背景与现状（必读，已核实）

| 现状项 | 真实位置 | 说明 |
|---|---|---|
| 自治开关 UI | `lib/features/chat_group/widgets/compact_conversation_controls.dart`（`CompactConversationControls`，`Key('autonomy-toggle')`，图标 `Icons.engineering_rounded`） | 群聊有"自动发言"+"自治执行"，私聊只有"自治执行"，`onPressed: () => onAutonomousChanged(!autonomousEnabled)` |
| 开关回调 | `lib/features/chat_group/chat_room_page.dart` → `_toggleAutonomousExecution(bool)`（约 3694 行）→ `AutonomousConversationConfigService.setEnabled(...)` | 持久化开关 |
| **问题根源：自然语义判定** | `lib/features/autonomous/autonomous_trigger_detector.dart`（`AutonomousTriggerDetector.detect`） + `lib/features/agentic/agentic_task_classifier.dart`（`requiresAgenticWork`） | 靠正则/关键词判定"是否该干活"，误判多、行为不稳定——**本次要去掉这层自由判定** |
| 自治执行入口 | `chat_room_page.dart` → `_maybeRunAutonomousTask`（约 766 行）→ `_executeAutonomousTask`（约 863 行） | 内部 `LocalAgentBridgeLauncher().restart(...)` + `_generateAgenticReply(..., autoApproveTools: true)` |
| 角色驱动的工作引擎 | `lib/features/agentic/agent_runtime.dart`（`AgentRuntime.run`，6 步上限 `maxToolSteps=6`、超时 `completionTimeout=120s`） | 真正规划+调工具+写文件 |
| SKILL 解析/匹配 | `lib/features/agentic/character_skill_resolver.dart`（`CharacterSkillResolver.resolveFor` / `defaultsFor`，用 `role/systemPrompt/personalityTags`）+ `lib/features/agentic/expert_skill_catalog.dart` | 角色 → 默认技能与权限；技能以 `CharacterSkill` 存进 Hive（`AICharacter.skillIds` / `toolPermissions`） |
| 文件落盘 | `lib/features/agentic/tools/workspace_file_tool.dart`（`WorkspaceFileTool.write` → 桥接 `POST /workspace/write`）→ 工作区根 = `autonomous_conversation_config_service.dart` 默认 `browser://agentic_output/conversations/$folder` | 产物目录 |
| 进度回贴 | `chat_room_page.dart` → `AgentRuntime.onProgress` → `_persistAgentProgress`（约 1873 行）→ `_upsertAgentProgressMessage`（约 1895 行，固定 id `agent-progress:${task.id}`） | 持续进度消息 |
| 结果/文件回贴 | `chat_room_page.dart` → `_attachmentsForAgentToolResult(...)`（约 1601 行）→ 文件作为 `MediaAttachment` 附加到 `Message.media` → `_appendMessage` | 最终文件贴聊天框 |
| 角色信息字段 | `lib/core/models/ai_character.dart`（`AICharacter`：`id/name/role/systemPrompt/memorySummary/skillIds/toolPermissions/agenticEnabled`） | 工作模式的内容来源 |

**结论**：代码骨架（执行引擎、技能匹配、文件回贴、进度回贴）都已齐备。本次改造的**核心不是重写引擎，而是把"触发条件"从自然语义判定换成显式开关，并在工作模式下强制走技能+产出+回贴闭环**。

---

## 2. 目标设计（要改成什么样）

### 2.1 普通聊天模式（工作模式 OFF，默认）
- 行为与现在完全一致：用户发言 → `_runAiRound` → 正常流式回复（`ChatApiService.streamChatMessage`）。
- **完全不触发** `AutonomousTriggerDetector`、`AgentRuntime`、文件生成、技能调用。

### 2.2 工作模式（Work Mode ON）
开启后，当前 conversation（群或 `dm:{characterId}`）进入"工作会话"：
1. **内容来源 = 角色信息**：AI 的工作目标/身份由 `AICharacter`（systemPrompt/role/memorySummary/skillIds/toolPermissions）决定，而不是靠用户一句话里的关键词触发。用户在聊天框里的发言是"工作指令/补充需求"，不是触发开关的开关词。
2. **强制使用 SKILL**：每轮工作都先经 `CharacterSkillResolver.resolveFor(character, userRequest)` 解析/匹配技能；若该角色没有合适技能则走 `forceSkillCreation` / `ExpertSkillCatalog` 推荐，保证"用技能干活"。**不要再用 `agentic_task_classifier.requiresAgenticWork` 来决定是否进工作流**——工作模式下直接进。
3. **生成对应输出文件**：工作的产物通过 `WorkspaceFileTool.write` 写入工作区（默认 `agentic_output/conversations/$folder`），文件类型由角色与任务决定（代码/文档/报告/网页等）。
4. **持续进度回复**：复用 `AgentRuntime.onProgress` → `_upsertAgentProgressMessage`，把规划、调工具、写文件的每一步以气泡形式持续回贴到聊天框。
5. **最终文件贴回聊天框**：工作结束，把生成的文件作为 `MediaAttachment` 经 `_attachmentsForAgentToolResult` → `_appendMessage` 贴到当前聊天框（保留现有"文件已生成：path（x KB）— 点击附件查看"样式）。
6. **可继续**：用户在聊天框继续发言（补充/修改需求），AI 在同一工作会话里继续干，直到用户明确结束或主动关闭工作模式。

**关键差异（vs 现状）**：现状是"AI 自己看用户说了啥，按关键词决定要不要干活，且常误判"；新设计是"用户显式打开工作模式 → 此后该角色的对话就是工作会话，稳定、可预期、必出文件"。

---

## 3. 实现要求（给 Codex 的具体指引）

### 3.1 UI：把"自治执行"按钮改成"工作模式"开关
- 文件：`lib/features/chat_group/widgets/compact_conversation_controls.dart`
- 行为：`CompactConversationControls` 新增 `bool workModeEnabled` 与 `ValueChanged<bool> onWorkModeChanged` 参数；把现有"自治执行"`IconButton`（`Icons.engineering_rounded`，`Key('autonomy-toggle')`）改为**工作模式开关**——群聊保留"自动发言"，把"自治执行"替换为"工作模式"切换（图标可用 `Icons.work_outline_rounded`，选中态 `Icons.work_rounded`，保持 36×36 `IconButton` 风格）。
- 私聊同样：把唯一的自治按钮换成工作模式开关。
- 在 `chat_room_page.dart` 的 `_buildConversationControls(...)`（约 3709 行）里接上 `onWorkModeChanged: _toggleWorkMode`，并把当前状态读出来传入。

### 3.2 状态持久化（按会话维度，复用现有机制）
- 文件：`lib/features/autonomous/autonomous_conversation_config_service.dart`（或就近新增 `WorkModeConfigService`）
- 用与 `AutonomousConversationConfigService.setEnabled/getEnabled` 相同的方式，按 `conversationKey`（群 = `groupId`，私聊 = `dm:{characterId}`）持久化 `workModeEnabled` 布尔值到 Hive（`app_settings` 或现有配置 box）。
- 提供 `setWorkMode(conversationKey, bool)` / `isWorkMode(conversationKey)`。
- 回调 `_toggleWorkMode(bool)`（仿 `_toggleAutonomousExecution`）写持久化并 `setState` 刷新控件与本地标志 `_workModeEnabled`。

### 3.3 编排逻辑（核心改造，最关键）
- 在消息处理入口（`chat_room_page.dart` 用户发言后的处理链，约 `_maybeRunAutonomousTask` 处）增加判定：
  ```dart
  if (_workModeEnabled && character.agenticEnabled) {
    // 工作模式：直接进工作流水线，跳过 AutonomousTriggerDetector / requiresAgenticWork
    await _runWorkModeTask(userRequest);
    return;
  }
  // 否则走原有 _runAiRound 普通聊天
  ```
- `Future<void> _runWorkModeTask(String userRequest)` 复用现有 `_executeAutonomousTask` / `_generateAgenticReply` 的执行体，但：
  - 传入 `autoApproveTools: true`（沿用现状）；
  - **构建工作规划提示词时，把 `AICharacter.systemPrompt/role/memorySummary/skillIds` 作为主体注入**（而非依赖用户消息里的关键词），让用户消息仅作为"本轮工作指令"；
  - 调用 `CharacterSkillResolver.resolveFor(character, userRequest)` 强制解析技能，并把解析到的技能清单纳入 AgentRuntime 的规划上下文（参考 `agent_runtime.dart` 中技能 handler 注入方式：`skillCreateHandler` / `skillDownloadHandler` 已在 `_agentRuntimeFor` 注入，约 1820/1824 行——工作模式要确保所有可用技能都被注入并鼓励调用）。
- **不要删除** `AutonomousTriggerDetector` / `agentic_task_classifier` 文件（别处或未来可能仍用），只是工作模式路径不再调用它们的"是否触发"判定。

### 3.4 强制 SKILL 使用
- 在 `_runWorkModeTask` → `AgentRuntime.run` 的规划 prompt 中，追加明确指令（中文）：
  "你正处于【工作模式】。请严格依据你的角色设定（见 systemPrompt/role/skillIds）开展工作，优先调用已配置的技能（SKILL）完成任务；若现有技能不足，应先创建/下载所需技能再执行。禁止把工作请求当成普通闲聊。"
- 确保 `CharacterSkillResolver.defaultsFor(character)` 在工作模式下一定被调用，使 `toolPermissions` 中的 `skillCreate`/`skillDownload` 生效。

### 3.5 工作模式下的技能权限策略（默认全开，仅敏感操作需请求）
- **所有技能默认按需启用**：工作模式开启后，该角色已安装/可匹配的技能**全部默认允许调用**，AI 应根据任务需要自行决定使用哪一个，无需逐一确认或二次开关。
- **仅三类敏感权限需要"请求用户确认"**（其余一律放行）：
  1. **读**（读取用户文件/目录内容）
  2. **写**（写入/覆盖/删除用户文件或工作区文件）
  3. **命令**（执行 shell / 运行命令 / 调用本地桥接执行进程）
- 实现指引（对齐现有 `AICharacter.toolPermissions` 与 `AgentRuntime` 的权限校验）：
  - 工作模式下，把角色的 `toolPermissions` 视为"已授予除读/写/命令之外的全部能力"；即默认白名单 = 全部技能 + 除 read/write/command 外的工具。
  - 当工作流准备执行**读 / 写 / 命令**类工具（对应 `AgentToolName` 中的文件读写、workspace patch、`/workspace/write`、shell 执行等）时，**不要直接执行**，而是先通过聊天框向用户发起一次"权限请求"气泡（说明将做什么、影响哪个文件/命令），**用户明确同意后再执行**；用户拒绝则跳过该步并说明原因，继续其余工作。
  - 该"请求-确认"机制仅在**工作模式 ON** 时启用；普通聊天模式不涉及（普通聊天本就不触达这些工具）。
  - 参考现有 `autoApproveTools: true` 的注入点（`_executeAutonomousTask` 内）：工作模式需把"自动批准"范围收拢为"非读/写/命令类"，敏感三类改为"需确认"。
- 在规划 prompt 中追加指令（中文）：
  "工作模式下所有技能默认可用，请按需调用。但凡涉及【读取用户文件】【写入/覆盖/删除文件】【执行命令】的操作，必须先在聊天框向用户发起一次明确的权限请求并获得同意，方可执行；其余操作可直接进行。"

### 3.6 进度与文件回贴（基本复用，确认连通）
- 进度：`AgentRuntime.onProgress` → `_persistAgentProgress` → `_upsertAgentProgressMessage` 已连通，**仅确认工作模式路径也走这条**（即 `_generateAgenticReply` 的 `onProgress` 回调要被传入）。
- 文件：工作结束后产物经 `_attachmentsForAgentToolResult` → `_appendMessage` 贴回聊天框，**确认工作模式产出的文件也走这条**（参考现有 `_generateAgenticReply` 末尾 `Message(..., media: attachments)` 写法）。

### 3.7 兼容性 / 回归
- 工作模式 OFF 时，行为必须与原版普通聊天 100% 一致（含流式、引用、@、停止生成等）。
- "自动发言"（idle auto-chat loop `_startAutoChat`）与工作模式互不耦合：工作模式开启不影响/不依赖自动发言；若二者同时开启，建议自动发言仍走普通闲聊、不触发工作流水线（除非产品另有要求，先保持隔离）。
- 不改动 `pubspec.yaml` 依赖；不改 `_getDataDir`/Hive 路径；不动 macOS entitlements。

### 3.8 测试与边界检查（必须交付，非空泛要求）

#### 3.8.1 单元测试（放在 `test/` 对应目录，推荐 `test/features/chat_group/`）
- **开关持久化**：`WorkModeConfigService.setWorkMode(conversationKey, true/false)` 后 `isWorkMode(...)` 返回一致值；覆盖群（`groupId`）与私聊（`dm:{characterId}`）两种 key；验证重读（新实例/重开 box）后状态保持。
- **分支路由**：构造 `_workModeEnabled` 为 true / false 两条路径，断言工作模式走 `_runWorkModeTask`、普通模式走 `_runAiRound`（可用 mock `AgentRuntime` / `ChatApiService` 验证调用次数与入参，确保普通模式**完全不调用** `AgentRuntime.run`）。
- **权限策略**：给定一条会触发"读/写/命令"的工具请求，断言工作模式下**先产生权限请求消息、且未直接执行**；给定非敏感工具请求，断言直接执行、无请求气泡。用户"拒绝"分支断言该步被跳过且后续步骤继续。
- **技能默认全开**：断言工作模式下 `CharacterSkillResolver.resolveFor` 被调用且返回的角色技能集合**包含全部已装技能**，而非按关键词筛选后的子集。

#### 3.8.2 Widget 测试
- `CompactConversationControls` 在 `workModeEnabled` 切换时正确渲染"工作模式"开关状态（`Key('work-mode-toggle')`），点击触发 `onWorkModeChanged(!value)` 且仅一次。
- `ChatRoomPage` 集成态（用 `pumpWidget` + mock provider）：开启工作模式后发出一条消息，断言聊天列表最终出现**进度气泡（至少 1 条）**与**带 `MediaAttachment` 的 AI 消息**；关闭模式则两者均不出现。

#### 3.8.3 边界检查清单（实现时必须处理，写进测试或至少代码注释覆盖）
- **角色无技能**：`AICharacter.skillIds` 为空时，工作模式仍应进入工作流并通过 `forceSkillCreation` / `ExpertSkillCatalog` 推荐兜底，不能空转或崩溃。
- **角色未开启 agentic**：`agenticEnabled == false` 时即使工作模式 ON，也**不**进入工作流水线（或明确提示"该角色未启用 Agentic"），避免调用未授权引擎。
- **空消息 / 纯空白输入**：工作模式下发空消息不触发工作流、不写文件、不产生异常气泡。
- **连续快速发言**：用户在 AI 工作流进行中继续发消息，应进入同一工作会话排队/续做，而非并发启动多个 `AgentRuntime`（用 `isolate`/锁或"同一 task 续跑"避免重入）；测试可断言"进行中再发消息不会新建第二个 runtime 实例"。
- **工作超时 / 步骤上限**：依赖现有 `AgentRuntime.maxToolSteps=6` 与 `completionTimeout=120s`，工作模式不得绕过；断言超过上限时优雅结束并回贴"已达步骤上限"说明，而非卡死。
- **文件落盘失败**：`WorkspaceFileTool.write` 抛错（如磁盘满/路径非法）时，工作模式应捕获并回贴错误进度，不崩溃、不丢已有聊天记录。
- **权限请求期间 App 切后台 / 用户离线**：用户未回应权限请求时，工作流应暂停等待，不默认放行敏感操作。
- **关闭工作模式中途**：工作流进行中用户关闭开关，应安全中止当前任务（停止后续工具调用、回贴"工作模式已关闭，任务中止"），不残留半截文件或孤儿进程。
- **多会话互不影响**：A 群开工作模式、B 群关，二者状态与运行实例隔离，断言互不影响。

---

## 4. 验收标准（Definition of Done）

1. 群聊与私聊的聊天界面都出现「工作模式」开关，状态可持久化（重进会话/重开 App 后保持）。
2. **关闭工作模式**：发消息 = 普通聊天，绝不生成文件、绝不调用 AgentRuntime、绝无进度气泡。
3. **开启工作模式**：
   - 发一条普通指令（如"帮我写一份周报"），AI 不靠关键词"碰运气"，而是依据角色设定进入工作流；
   - **所有已装/可匹配技能默认按需可用**，AI 自行决定调用哪个，无需逐个确认；
   - 聊天框出现**持续进度气泡**（规划/调技能/写文件各阶段）；
   - **涉及读取用户文件 / 写入或删除文件 / 执行命令**时，AI 先在聊天框发起一次明确的权限请求并等待用户同意，用户拒绝则跳过该步继续其余工作；其余操作直接执行；
   - 工作结束，**生成的文件作为附件出现在聊天框**，可点击查看；
   - 继续发消息，AI 在同一工作会话继续干活。
4. **测试与边界全部覆盖**：
   - `flutter analyze` 无报错；`flutter test` 全绿。
   - 至少含：开关持久化单测、工作/普通分支路由单测（普通模式零调用 `AgentRuntime`）、权限请求单测（敏感三类先请求、其余直行、拒绝跳过）、技能默认全开单测、控件渲染 widget 测试、端到端 widget 测试（开模式出现进度+附件、关模式均无）。
   - 边界清单（3.8.3）逐项有测试或代码级覆盖：无技能兜底、未启用 agentic、空输入、并发重入、超时/步骤上限、落盘失败、权限未回应、中途关闭、多会话隔离。


---

## 5. 约束（必须遵守，否则 CI/本地编译失败）

- 本项目用 **Flutter 3.24 fork**，使用**旧主题 API**（`CardTheme`/`DialogTheme`，不要改成 `CardThemeData` 等新 API）。
- Dart SDK 约束 `">=3.5.0 <4.0.0"`，不要升级依赖。
- 新增第三方包前先确认不含 Flutter 3.25+ API（如 `Color.withValues`）；必要的小版本下调沿用 `dependency_overrides`。
- `pubspec.lock` 不入库；改完模型/provider 记得 `dart run build_runner build`。

---

## 6. 参考文件清单（Codex 优先阅读）

- `lib/features/chat_group/chat_room_page.dart`（编排核心）
- `lib/features/chat_group/widgets/compact_conversation_controls.dart`（UI 开关）
- `lib/features/autonomous/autonomous_conversation_config_service.dart`（状态持久化）
- `lib/features/autonomous/autonomous_trigger_detector.dart`（待绕过的自然语义判定）
- `lib/features/agentic/agent_runtime.dart`（执行引擎）
- `lib/features/agentic/character_skill_resolver.dart` + `expert_skill_catalog.dart`（SKILL 解析/匹配）
- `lib/features/agentic/agentic_task_classifier.dart`（旧判定，工作模式不再调用）
- `lib/features/agentic/tools/workspace_file_tool.dart` + `local_agent_bridge_server.dart`（文件落盘）
- `lib/core/models/ai_character.dart`（角色信息来源）
- `AGENTS.md`（项目约定总览）

---

## 7. 建议提交信息

```
feat(chat): 新增「工作模式」开关，替代自然语义自治触发

- 群/私聊加入工作模式开关（按会话持久化）
- 开启后依据角色信息强制走工作流水线：自动调用 SKILL、持续进度回贴、最终文件作为附件贴回聊天框
- 关闭时完全等同于普通聊天，移除对自然语义意图判定的依赖
```
