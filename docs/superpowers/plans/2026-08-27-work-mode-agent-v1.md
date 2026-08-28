# Work Mode AI Agent V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkboxes (`- [ ]`) for tracking. Every coding task must also read and obey `/Users/fengye/.codex/skills/ponytail/SKILL.md` before editing.

**Goal:** 把当前页面内、易中断、弱连续性的工作模式，升级为 App 级、可持续追问、可授权多目录、可审批写入、可撤销、可观察执行过程的桌面 AI Agent，并首先交付完成 macOS 实机验证的本地安装包。

**Architecture:** 复用现有 `ChatApiService`、`AgentTask`、Hive、文档解析、视觉能力注册表和搜索链；将任务所有权从 `ChatRoomPage` 上移到 App 根部的 `WorkTaskCoordinator`。所有文件和命令动作经统一策略层、审批层、锁和快照层执行，执行事件写入持久化事件流，再由非模态全局面板订阅展示。V1 直接使用 Dart `dart:io`/`Process`，不依赖额外守护进程、数据库、容器或本地服务。

**Tech Stack:** Flutter 3.24 fork / Dart >=3.5、Riverpod、Hive、Dio、`dart:io`、现有 `file_picker`、现有 PDF/DOCX/XLSX 解析与视觉模型能力；只有可见内嵌浏览器验证通过时才加入 `desktop_webview_window`，HTML 解析仅在确有需要时把已传递依赖 `html` 声明为直接依赖。

**Source specifications:**

- `docs/work_mode_agent_v1_requirements.md`
- `docs/work_mode_agent_v1_technical_design.md`
- Repository `AGENTS.md`

---

## 0. 全程执行规则（Ponytail 门禁）

下面规则适用于每一个任务和每一次提交，不是最后才做的清理项。

1. **先复用再新增。** 开始任务前先用 `rg` 找现有能力；能扩展现有服务时不建立平行实现。
2. **标准库优先。** 文件、目录、进程、快照复制优先使用 `dart:io`；不为抽象而引入包。
3. **先写失败测试。** 非平凡逻辑必须先出现能说明行为的失败测试，再写最小实现使其通过。
4. **修根因。** 不以更多正则、XML 标签回退或静默吞错修补 Agent 协议；模型输出只走单一 JSON 协议和一次受控修复。
5. **少文件、短函数。** 新文件只在职责明确且现有文件放不下时创建；单函数约 50 行、单文件约 500 行，超出即按职责拆分。
6. **不碰用户现有改动。** 当前 `lib/features/agentic/character_skill_resolver.dart`、`expert_skill_catalog.dart` 及相应测试和两个未跟踪模板文件属于用户改动，除非该任务明确需要且先完成逐行冲突检查，否则不修改。
7. **保留安全和错误语义。** 不绕过审批、路径校验、凭据保护、取消传播、错误提示；失败必须可见、可恢复或明确终止。
8. **不手改生成文件。** Hive/Riverpod 生成内容只通过 `dart run build_runner build` 生成。
9. **每步有证据。** 每一任务记录测试命令、结果、改动文件和尚未覆盖项；不得用“测试通过”替代规格核对。
10. **依赖闸门。** 新包必须先做独立兼容性试验；试验失败就删除该依赖和相关临时代码，不留双实现。

每个任务完成前执行：

```bash
git diff --check
flutter analyze
```

预期：两个命令退出码均为 0。若全量 `flutter analyze` 被用户已有改动阻塞，必须保存错误证据并运行本任务涉及文件的最小可执行测试，不得伪称通过。

---

## Stage 01：App 级任务内核与非模态执行面板

### Task 01：冻结基线并建立规格追踪测试

**目的：** 在任何重构前固定当前正常聊天、自动聊天和主动私聊行为，防止工作模式改造污染普通模式。

**Files:**

- Create: `test/work_mode/work_mode_v1_spec_guard_test.dart`
- Read only: `lib/features/chat_group/chat_activity_policy.dart`
- Read only: `lib/features/chat_group/chat_room_agentic_round_support.dart`
- Read only: `lib/features/direct_chat/direct_chat_foreground_watcher.dart`

**怎么做：**

- [ ] 1. 将 FR-01 至 FR-09 转成测试名称清单；本文件只先实现不会依赖新代码的隔离门禁。
- [ ] 2. 添加测试：普通聊天不进入工具运行时；自动聊天在工作模式开启时暂停；关闭工作模式后恢复原策略；主动私聊不创建工作任务。
- [ ] 3. 运行测试并保存当前通过基线。

```bash
flutter test test/work_mode/work_mode_v1_spec_guard_test.dart
```

预期：PASS。该任务属于“行为冻结”，不是先红后绿；后续每个 Stage 都向同一规格测试补充对应断言。

- [ ] 4. 记录当前全量分析和现有工作模式测试结果。

```bash
flutter analyze
flutter test test/work_mode test/agentic/chat_room_agent_task_recovery_test.dart test/chat_room_page_lifecycle_test.dart
```

**完成条件：** 普通模式隔离行为有自动化证据，现有失败（若有）已单独登记，不归因于后续改造。

**Commit:** `test(work-mode): freeze v1 isolation baseline`

---

### Task 02：扩展 `AgentTask` 为可恢复的 App 级任务记录

**目的：** 让任务在离开聊天页和重启 App 后仍知道对话、队列、角色、动作计数、时间和恢复点。

**Files:**

- Modify: `lib/core/models/agent_task.dart`
- Generate: `lib/core/models/agent_task.g.dart`
- Modify: `lib/core/database/database_service.dart`
- Create: `lib/features/work_mode/work_mode_v1_migrator.dart`
- Create: `test/work_mode/work_mode_v1_migrator_test.dart`
- Modify: `test/work_mode/work_mode_task_recovery_test.dart`

**怎么做：**

- [ ] 1. 先写失败测试，覆盖：新任务默认 100 个动作、60 分钟软上限；排队追问保持顺序；中断状态只允许用户手点继续；旧版 `workModeTask=true` 记录在首次 V1 迁移时清理，普通 `AgentTask` 不被清理。
- [ ] 2. 在 `AgentTask` 追加 Hive 字段，不改变已有字段编号；至少保存：`queuedUserRequests`、`contextSummary`、`assignedCharacterIds`、`startedAt`、`actionCount`、`softLimitReached`、`resumeRequired`、`executionStateJson`、`lastArtifactPaths`。列表写入时复制，避免共享可变引用。
- [ ] 3. 增加明确的状态 `queued`、`paused`、`interrupted`，并更新 `canResume`、`isTerminal`；App 被关闭或进程丢失时将非终态运行记录恢复成 `interrupted + resumeRequired=true`，绝不自动续跑。
- [ ] 4. 编写 `WorkModeV1Migrator`：用 `app_settings['work_mode_agent_schema_version']` 做幂等门闩；版本缺失时只清理旧工作任务和旧 `WorkModeWorkspace`，保留普通任务、聊天、角色、消息和设置。
- [ ] 5. 生成 Hive adapter。

```bash
dart run build_runner build
```

- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_mode_v1_migrator_test.dart test/work_mode/work_mode_task_recovery_test.dart
```

预期：先因字段/迁移类不存在而 FAIL；实现后 PASS。

**核心约束：** 不新建第二套任务数据库；复用 `agent_tasks` box。`executionStateJson` 只保存非敏感运行元数据，不保存 API Key 或完整私密文件内容。

**完成条件：** 任务状态可以持久化并区分排队、暂停、意外中断、终态；旧工作任务清理是幂等且范围精确的。

**Commit:** `feat(work-mode): persist resumable app-level task state`

---

### Task 03：建立持久化、可流式消费的任务事件流

**目的：** 为独立执行面板提供“正在做什么、哪一步、工具输出、结论”的唯一事实来源，不暴露模型私有推理。

**Files:**

- Create: `lib/features/work_mode/work_task_event.dart`
- Create: `lib/features/work_mode/work_task_event_store.dart`
- Create: `test/work_mode/work_task_event_store_test.dart`

**怎么做：**

- [ ] 1. 先写失败测试：事件序号单调；重启可重放；并发追加不丢事件；截断的最后一行被忽略并记录安全错误；事件内容上限生效。
- [ ] 2. 定义少而稳定的事件类型：`queued`、`planning`、`stepStarted`、`toolOutput`、`approvalRequired`、`paused`、`stepCompleted`、`failed`、`completed`、`undoCompleted`。
- [ ] 3. 事件字段只包含 `taskId`、`sequence`、`timestamp`、`kind`、`title`、`detail`、`progressCurrent`、`progressTotal`、`safeMetadata`；禁止保存 API Key、Authorization header、整段模型推理。
- [ ] 4. 使用 App Support 下 `work_mode_agent/events/<taskId>.jsonl`；单任务写入串行化，追加后 flush；读取时逐行 JSON 解码，最后一行损坏时保留之前记录。
- [ ] 5. `detail` 和工具输出做长度上限及凭据模式脱敏，原始完整 stdout 只保存在内存滚动窗口，不写 Hive。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_task_event_store_test.dart
```

**完成条件：** 事件流可跨页面/重启读取，UI 不需要直接订阅 AgentRuntime 内部回调；测试证明损坏文件不会让 App 启动失败。

**Commit:** `feat(work-mode): add durable redacted task event stream`

---

### Task 04：实现全局调度器、每会话队列和全局并发上限

**目的：** 同一对话一次只执行一个任务，全 App 最多两个任务运行；新输入进入队列而不是取消当前任务。

**Files:**

- Create: `lib/features/work_mode/work_task_coordinator.dart`
- Create: `lib/features/work_mode/providers/work_task_providers.dart`
- Modify: `lib/providers/providers.dart`
- Create: `test/work_mode/work_task_coordinator_test.dart`

**怎么做：**

- [ ] 1. 先写失败测试，使用可控 `FakeWorkTaskRunner` 覆盖：全局最多 2；同 conversationId 最多 1；第三个任务排队；当前任务完成后 FIFO 启动；同一任务的新追问追加到其队列；取消只影响目标任务。
- [ ] 2. 定义最小运行接口：

```dart
abstract interface class WorkTaskRunner {
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation);
}
```

- [ ] 3. `WorkTaskCoordinator` 成为任务状态、调度、取消和恢复的唯一所有者。它持有 `Map<String, RunningTask>`、会话队列和全局槽位，不持有 BuildContext。
- [ ] 4. 提供明确 API：`submit`、`enqueueFollowUp`、`stop`、`resumeByUser`、`continueAfterSoftLimit`、`watchTask`、`watchAllTasks`。
- [ ] 5. Riverpod provider 从根 `ProviderScope` 获取 `DatabaseService` 和事件存储；provider 不 `autoDispose`，离开聊天页不能销毁协调器。
- [ ] 6. App 启动时只恢复任务列表和事件，不自动调用 `run`；中断任务等待用户点击继续。
- [ ] 7. 跑测试。

```bash
flutter test test/work_mode/work_task_coordinator_test.dart
```

**完成条件：** 页面销毁不会取消任务；测试中最大并发从未超过 2，同会话从未并发。

**Commit:** `feat(work-mode): add global task coordinator and queues`

---

### Task 05：把聊天输入从页面执行改为提交给全局协调器

**目的：** 去掉“新任务取消旧任务”和“离开页面停止执行”的旧所有权关系，同时保持消息和追问上下文。

**Files:**

- Modify: `lib/features/chat_group/chat_room_agentic_input_support.dart`
- Modify: `lib/features/chat_group/chat_room_agentic_approval_support.dart`
- Modify: `lib/features/chat_group/chat_room_agentic_support.dart`
- Modify: `lib/features/chat_group/chat_room_page_lifecycle_support.dart`
- Modify: `lib/features/chat_group/chat_room_page_state.dart`
- Modify: `lib/features/work_mode/work_mode_session.dart`
- Modify: `lib/features/work_mode/work_mode_task_lifecycle.dart`
- Modify: `test/work_mode/work_mode_session_test.dart`
- Modify: `test/chat_room_page_lifecycle_test.dart`
- Modify: `test/agentic/chat_room_agent_task_recovery_test.dart`

**怎么做：**

- [ ] 1. 先把旧测试“新输入取消待审批任务”改成 V1 规则：新输入排入当前任务，旧任务保持；测试应先 FAIL。
- [ ] 2. 页面输入只负责保存用户消息和调用 `coordinator.submit/enqueueFollowUp`；不再创建 CancelToken、不直接等待完整执行。
- [ ] 3. `dispose` 只解除 UI 订阅和文档临时解析，不调用工作任务停止。用户点击“停止”才调用协调器。
- [ ] 4. 旧 `WorkModeSession` 缩减为 UI 开关和当前会话选择状态；取消句柄、待审批所有权移到协调器。若类已无独立价值则删除并把开关放入页面状态，但不得同时保留两套 owner。
- [ ] 5. 恢复对话时加载同 conversationId 的活动/中断任务；只有用户点“继续”才续跑。
- [ ] 6. 运行回归。

```bash
flutter test test/work_mode/work_mode_session_test.dart test/chat_room_page_lifecycle_test.dart test/agentic/chat_room_agent_task_recovery_test.dart
```

**完成条件：** 发送追问不会取消旧任务；离开聊天室后 fake runner 继续并写出完成事件；重回页面能看到同一任务而非新任务。

**Commit:** `refactor(work-mode): move execution ownership out of chat page`

---

### Task 06：实现全 App 非模态、可收起的独立执行面板

**目的：** 在任意页面查看最多两个运行任务的实时进度；面板可展开、收起和关闭显示，但关闭显示不停止任务。

**Files:**

- Create: `lib/features/work_mode/presentation/work_task_panel.dart`
- Create: `lib/features/work_mode/presentation/work_task_overlay_host.dart`
- Modify: `lib/main.dart`
- Create: `test/work_mode/work_task_panel_test.dart`

**怎么做：**

- [ ] 1. 先写 widget 失败测试：展示任务标题/角色/当前步/总步/持续时间；事件按序流式出现；收起保留迷你条；关闭面板后任务 runner 未取消；停止按钮才取消；多个任务可切换。
- [ ] 2. 在 `MaterialApp.builder` 中把现有 `DirectChatForegroundWatcher` 保留，并在其内或外包一层 `WorkTaskOverlayHost`；不得覆盖现有 Navigator/ScaffoldMessenger key。
- [ ] 3. 桌面宽屏用右侧非模态面板，窄窗口用底部非模态 sheet；默认可收起，不阻挡主页面点击。
- [ ] 4. 面板显示公开执行信息：计划摘要、当前动作、工具名、安全化输出、审批原因、结论；不得显示 chain-of-thought 或系统提示词。
- [ ] 5. 提供“回到对话”“停止”“继续”“撤销（后续 Task 11 接线）”；不可用按钮给明确原因。
- [ ] 6. 运行测试。

```bash
flutter test test/work_mode/work_task_panel_test.dart
```

**完成条件：** 从角色页、群列表、设置页都能打开同一面板；UI 隐藏与任务停止是两个独立动作。

**Commit:** `feat(work-mode): add app-wide nonmodal execution panel`

---

## Stage 02：多文件夹授权、文件策略、审批、快照与撤销

### Task 07：实现 App 级多目录授权和设置入口

**目的：** 用户只授权一次，授权根目录对整个 App 的工作模式默认可访问；支持多目录、移除和重新授权。

**Files:**

- Create: `lib/features/work_mode/work_folder_grant_service.dart`
- Modify: `lib/features/settings/settings_page_build.dart`
- Modify: `lib/features/settings/settings_page_config_support.dart`
- Create: `lib/features/settings/work_mode_agent_settings_section.dart`
- Create: `test/work_mode/work_folder_grant_service_test.dart`
- Create: `test/work_mode/work_mode_agent_settings_section_test.dart`

**怎么做：**

- [ ] 1. 写失败测试：多目录去重；父目录授权覆盖子目录；移除后立即失效；不存在目录标记为不可用；设置重启后仍在；路径不出现在日志脱敏之外。
- [ ] 2. 使用现有 `file_picker` 的目录选择能力，不新增选择器包。用户选择目录即视为一次 App 级授权；保存规范化绝对路径、显示名、添加时间和最近验证时间到 `app_settings`。
- [ ] 3. macOS/Windows 每次启动对授权目录做轻量可达性检查，不递归扫描；失效时显示“重新授权”，不自动删除记录。
- [ ] 4. 设置页增加“工作模式 AI Agent”：授权目录列表、添加/移除、默认写入确认开关、30 天保留、2GB 上限、100 步/60 分钟说明。删除和不可撤销覆盖的强制确认不得提供关闭开关。
- [ ] 5. 若首次工作请求无授权目录，协调器发 `approvalRequired` 事件并打开目录选择提示；选择后任务继续，取消则暂停并说明原因。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_folder_grant_service_test.dart test/work_mode/work_mode_agent_settings_section_test.dart
```

**完成条件：** 授权是 App 级而非会话级；选择多个目录后任意工作对话都可读取；移除后下一次工具调用立即拒绝。

**Commit:** `feat(work-mode): add app-wide folder grants and settings`

---

### Task 08：实现规范路径解析和只读文件工具

**目的：** 在已授权根目录内安全列目录、搜索、读取和分析，阻止 `..`、符号链接和大小写绕过。

**Files:**

- Create: `lib/features/work_mode/workspace_file_service.dart`
- Create: `lib/features/work_mode/workspace_path_policy.dart`
- Create: `test/work_mode/workspace_path_policy_test.dart`
- Create: `test/work_mode/workspace_file_service_test.dart`

**怎么做：**

- [ ] 1. 写失败测试，覆盖 POSIX、Windows 盘符/反斜杠、大小写规则、`..`、相似前缀（`/work/a` 不能授权 `/work/ab`）、授权根本身、越界 symlink、损坏链接、超大文件、二进制文件。
- [ ] 2. 规范化输入路径后解析真实路径；目标存在时用 `resolveSymbolicLinks`，新建目标则解析最近存在父目录；最后按 path segment 判断是否位于任一有效授权根，不用字符串 `startsWith`。
- [ ] 3. 提供最小只读 API：`listDirectory`、`stat`、`readTextRange`、`searchText`。目录列表分页，默认不递归；搜索有文件数、字节数、耗时和取消上限。
- [ ] 4. 读取 `.env`、私钥、凭据命名文件时允许但追加“敏感读取”事件，并在模型上下文和 UI 输出前脱敏；绝不把内容写进任务事件文件。
- [ ] 5. 读取文本使用 UTF-8 严格解码，失败时报告“非文本/编码不支持”，不把乱码传给模型。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/workspace_path_policy_test.dart test/work_mode/workspace_file_service_test.dart
```

**完成条件：** 所有只读动作只能触及授权根；目录巨大或文件异常时有界失败，任务可继续选择其他方案。

**Commit:** `feat(work-mode): add bounded authorized read-only file tools`

---

### Task 09：建立统一变更计划和任务级写入审批

**目的：** 任何写、重命名、删除、修改命令先形成准确变更范围；首次写入弹一次任务级审批，设置可关闭普通写入提示。

**Files:**

- Create: `lib/features/work_mode/work_mutation_policy.dart`
- Create: `lib/features/work_mode/work_change_plan.dart`
- Create: `lib/features/work_mode/presentation/work_mutation_approval_dialog.dart`
- Create: `test/work_mode/work_mutation_policy_test.dart`
- Create: `test/work_mode/work_mutation_approval_dialog_test.dart`

**怎么做：**

- [ ] 1. 写失败测试覆盖：首次写提示；同一审批范围后续写不再提示；新增越界文件补充审批；关闭普通写入提示后仍对删除/不可撤销覆盖提示；拒绝不执行；取消对话只暂停任务；审批显示准确文件。
- [ ] 2. 定义 `WorkChangePlan`：动作类型、精确绝对路径、已知受影响目录、预计字节、是否可快照、是否可撤销、命令理由、风险理由。
- [ ] 3. 审批范围以“任务 + 明确文件集合/目录影响集合”保存，不能退化为“本任务允许所有写入”。模型后来提出新文件时生成 supplemental approval。
- [ ] 4. 对命令无法精确枚举全部文件时，必须列出命令、工作目录、已知文件和可能受影响目录，并标记 `impactUncertain=true`；该类动作始终提示。
- [ ] 5. 审批弹窗展示“为什么需要、将做什么、具体路径、能否撤销”，按钮为“允许本次范围”“拒绝并暂停”；不得只写“标准工具调用”。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_mutation_policy_test.dart test/work_mode/work_mutation_approval_dialog_test.dart
```

**完成条件：** 没有 `WorkChangePlan` 就不能进入任何变更工具；设置开关只影响普通可撤销写入，不影响高风险动作。

**Commit:** `feat(work-mode): require scoped mutation plans and approval`

---

### Task 10：实现原子文件变更执行器

**目的：** 统一执行创建、覆盖、补丁、重命名和删除，避免 AgentRuntime 内散落写文件逻辑。

**Files:**

- Create: `lib/features/work_mode/workspace_mutation_service.dart`
- Create: `test/work_mode/workspace_mutation_service_test.dart`
- Modify later integration point only: `lib/features/agentic/agent_runtime_components.dart`

**怎么做：**

- [ ] 1. 写失败测试：审批前零写入；临时文件写完后原子替换；失败保留原文件；补丁前内容哈希不匹配则拒绝；重命名目标存在需再次分类；删除只删精确目标；取消点不留下半文件。
- [ ] 2. 所有动作再次调用 `WorkspacePathPolicy`，不能信任计划阶段已校验结果；审批后路径发生 symlink 变化时必须拒绝（防 TOCTOU）。
- [ ] 3. 新建/覆盖写到同目录临时文件，flush 后 rename；Windows rename 不能安全覆盖时先走快照并用明确的受控替换分支。
- [ ] 4. 文本 patch 带原内容 SHA-256 和目标相对片段；哈希不匹配返回 conflict，让 Agent 重新读取，不做模糊套用。
- [ ] 5. 每个成功动作写 `stepCompleted` 事件及最终路径，失败写可理解原因，不记录文件正文。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/workspace_mutation_service_test.dart
```

**完成条件：** 所有文件变更只有一个生产入口；任何中途失败都不会把原文件变成部分内容。

**Commit:** `feat(work-mode): add atomic authorized mutation service`

---

### Task 11：实现任务快照、30 天/2GB 清理和一键撤销

**目的：** 写入前保存可恢复状态；任务完成后用户可一键撤销；不能快照时默认阻止。

**Files:**

- Create: `lib/features/work_mode/work_snapshot_service.dart`
- Create: `lib/features/work_mode/work_snapshot_manifest.dart`
- Create: `test/work_mode/work_snapshot_service_test.dart`
- Modify: `lib/features/work_mode/presentation/work_task_panel.dart`

**怎么做：**

- [ ] 1. 写失败测试：覆盖前保存旧文件；新文件记录为撤销时删除；删除前保存内容；重命名可逆；多动作按逆序撤销；撤销前目标被外部修改则停止并提示冲突；30 天和 2GB 双阈值清理；活动任务快照不被清理。
- [ ] 2. 快照放在 App Support `work_mode_agent/snapshots/<taskId>/`；manifest 使用 JSON，记录动作序号、原/目标路径、mtime、size、SHA-256、备份相对路径和完成状态。
- [ ] 3. 变更审批通过后、真正写入前创建快照；快照失败时返回 `snapshotUnavailable`，默认禁止变更并提示用户单独选择“仍然执行且无法撤销”。该选择不能被设置中的普通写入开关跳过。
- [ ] 4. 撤销前重新校验授权根和当前文件哈希；冲突时逐项列出，不覆盖外部新改动。成功项和冲突项都写事件。
- [ ] 5. 清理顺序：先删除超过 30 天的终态任务快照，再按最旧终态任务清到 2GB 以下；保留运行/暂停/待审批任务。
- [ ] 6. 面板完成态增加“撤销本任务改动”；撤销本身需要确认并显示将恢复/删除的文件列表。
- [ ] 7. 跑测试。

```bash
flutter test test/work_mode/work_snapshot_service_test.dart test/work_mode/work_task_panel_test.dart
```

**完成条件：** 可撤销变更全部有 manifest 和实际备份；模拟外部冲突时不破坏用户新内容。

**Commit:** `feat(work-mode): add snapshots retention and one-click undo`

---

### Task 12：实现跨任务文件锁和冲突排队

**目的：** 两个并行任务访问同一文件或父子目录时，不发生互相覆盖。

**Files:**

- Create: `lib/features/work_mode/work_resource_lock_manager.dart`
- Create: `test/work_mode/work_resource_lock_manager_test.dart`
- Modify: `lib/features/work_mode/work_task_coordinator.dart`

**怎么做：**

- [ ] 1. 写失败测试：同文件写写冲突；目录与子文件冲突；只读-只读不冲突；写与读冲突；锁按 FIFO；取消等待者移除；运行者异常后释放；Windows 路径大小写归一。
- [ ] 2. 锁粒度基于规范绝对路径和动作模式 `read/write/treeWrite`；一次获取计划需要的完整锁集合，按稳定排序申请，避免死锁。
- [ ] 3. 无法取得锁时任务状态为 `queued`，事件明确显示“等待另一个任务释放 <安全化路径>”，不消耗 Agent 动作数。
- [ ] 4. 在 `try/finally` 释放锁；协调器重启时不恢复内存锁，所有遗留运行任务先变 `interrupted`，由用户继续后重新校验和取锁。
- [ ] 5. 跑测试。

```bash
flutter test test/work_mode/work_resource_lock_manager_test.dart test/work_mode/work_task_coordinator_test.dart
```

**完成条件：** 压力测试中同一资源没有重叠写区间，异常/取消后队列能继续前进。

**Commit:** `feat(work-mode): serialize conflicting file operations`

---

## Stage 03：连续 Agent 循环、追问记忆、角色路由与终端

### Task 13：定义唯一 JSON Agent 决策协议

**目的：** 代替当前多套正则/XML/兼容字段猜测，用一个可验证协议驱动计划、工具、澄清、审批、接力和完成。

**Files:**

- Create: `lib/features/work_mode/agent_decision.dart`
- Create: `lib/features/work_mode/agent_decision_parser.dart`
- Create: `test/work_mode/agent_decision_parser_test.dart`
- Modify: `lib/features/agentic/agent_prompt_builder.dart`

**怎么做：**

- [ ] 1. 写表驱动失败测试：合法 `plan/tool/clarify/handoff/finish`；未知 action；缺字段；字段类型错；额外代码围栏；空 `content` 但有 `reasoning_content`；两者都空。
- [ ] 2. 协议顶层固定为：

```json
{
  "action": "tool",
  "public_update": "正在读取项目配置",
  "tool": {"name": "read_text", "arguments": {"path": "/..."}},
  "completion": null
}
```

- [ ] 3. 只允许一次“把原始响应作为数据交给同一模型修复成 JSON”的受控修复；修复仍失败即报告协议错误。不要新增正则提取 XML/Markdown 的备用链。
- [ ] 4. 保留现有红线：标准 `content` 为空才读取 `reasoning_content`；两者为空明确失败；流式空内容同一请求只回退一次非流式。
- [ ] 5. `public_update` 是面板公开进度，不是私有思维。提示词明确要求只描述动作、依据和结论，不输出隐藏推理。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/agent_decision_parser_test.dart
```

**完成条件：** 所有生产决策都能映射成 sealed/enum 类型；未知工具和非法参数在执行前被拒绝。

**Commit:** `refactor(work-mode): introduce single validated agent protocol`

---

### Task 14：实现连续 Agent 循环、重试和 100 步/60 分钟软限制

**目的：** 一个任务可多步读取、搜索、修改和验证；错误有界重试；达到软限制后等待用户手点继续。

**Files:**

- Create: `lib/features/work_mode/work_agent_loop.dart`
- Create: `lib/features/work_mode/work_tool_registry.dart`
- Create: `test/work_mode/work_agent_loop_test.dart`
- Modify: `lib/features/work_mode/work_task_coordinator.dart`

**怎么做：**

- [ ] 1. 用 Fake model/Fake tools 写失败测试：多步工具序列；每步事件；工具暂时失败后一次有界重试；不可重试错误立即澄清/失败；停止信号在模型前、工具前、工具后均生效；第 100 动作暂停；60 分钟暂停；用户继续后预算重新授予且上下文保留。
- [ ] 2. `WorkToolRegistry` 只注册结构化工具和 schema；读取工具自动执行，变更工具必须先过策略/审批/快照/锁。未知工具不能落到 shell。
- [ ] 3. 每次循环顺序固定：检查取消/软限 → 构建压缩上下文 → 调模型 → 解析决策 → 写公开事件 → 校验工具 → 执行 → 保存检查点。
- [ ] 4. 网络/限流/5xx 使用现有重试策略思想，最大次数和退避有常量；协议错只有一次修复；权限拒绝不重试；路径越界不重试。
- [ ] 5. 完成后自动执行已审批的剩余步骤；需要用户判断、授权、登录、验证码、付费墙或软限时进入 paused，不自动猜。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_agent_loop_test.dart
```

**完成条件：** Fake 场景可稳定完成 20+ 步；达到限制只暂停不丢任务；继续后从检查点推进而非重做已完成写入。

**Commit:** `feat(work-mode): add persistent continuous agent loop`

---

### Task 15：实现追问队列、上下文压缩和原文件修订

**目的：** 当前任务结束后按顺序处理用户追问；“修改当前/上次/同一文件”覆盖原路径；App 重启后仍保留上下文。

**Files:**

- Create: `lib/features/work_mode/work_context_builder.dart`
- Create: `lib/features/work_mode/work_follow_up_policy.dart`
- Create: `test/work_mode/work_context_builder_test.dart`
- Create: `test/work_mode/work_follow_up_policy_test.dart`
- Modify: `lib/features/work_mode/work_task_coordinator.dart`

**怎么做：**

- [ ] 1. 写失败测试：执行中收到 3 条追问按顺序保留；任务完成自动处理第一条；明确修订词绑定最后产物路径；新建重名才自动改名；群聊上下文成员共享；私聊 A 不读私聊 B；重启后摘要、产物和队列恢复。
- [ ] 2. 上下文只包含：用户目标、未决追问、已完成动作摘要、最近工具结果、审批范围、产物路径、角色/接力状态、错误和下一步；大文件正文按需重新读取，不持久化进摘要。
- [ ] 3. 压缩发生前先保存不可丢字段；摘要模型失败时用确定性裁剪，不清空任务。
- [ ] 4. 修订策略先用结构化上下文中的 `lastArtifactPaths` 和用户明确措辞，不靠全局最近文件猜测；目标多义时只问一个精确问题并暂停。
- [ ] 5. 群聊使用 `groupId` 作为上下文边界；私聊使用稳定 `dm:{characterId}`，绝不跨 conversationId 聚合。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_context_builder_test.dart test/work_mode/work_follow_up_policy_test.dart
```

**完成条件：** 重启恢复测试后，同一修订请求仍命中原绝对路径；私聊隔离测试无任何 B 会话内容泄漏。

**Commit:** `feat(work-mode): persist follow-ups and artifact revision context`

---

### Task 16：实现 @ 指定、自动角色选择和多阶段接力

**目的：** 用户可 `@角色` 指定执行者；无 @ 时由 AI 根据职业能力和上下文选择；产品、开发、测试可串行接力，但一个对话同时仅一个角色执行。

**Files:**

- Create: `lib/features/work_mode/work_role_router.dart`
- Create: `lib/features/work_mode/work_handoff_state.dart`
- Create: `test/work_mode/work_role_router_test.dart`
- Modify: `lib/features/chat_group/mention_parser.dart`（若现有解析足够则只复用、不修改）

**怎么做：**

- [ ] 1. 先用 `rg` 定位现有 mention 解析和角色 skill/persona 字段；写失败测试覆盖精确 @、重名角色、无 @ 产品需求、无 @ 编码任务、无 @ 测试任务、能力不足、产品→开发→测试接力、私聊固定角色。
- [ ] 2. 路由优先级固定：有效显式 @ → 私聊固定角色 → 当前 handoff 指定角色 → 基于 persona/skills/职业的模型选择 → 可解释的确定性兜底。
- [ ] 3. 模型路由结果必须包含角色 ID、公开理由、置信度和是否需要接力；角色不存在或能力不匹配时提示用户并给出具体原因，不静默换模型。
- [ ] 4. `WorkHandoffState` 保存阶段、交付物、接收角色和完成条件；handoff 发生在前一角色动作完成并释放资源锁之后。
- [ ] 5. 同一 conversationId 的 coordinator 槽位保持 1，角色切换不能创建并行 runner。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_role_router_test.dart
```

**完成条件：** 所有路由都有面向用户的原因；100 次调度压力测试中同会话活动角色数从未超过 1。

**Commit:** `feat(work-mode): route and hand off work between chat roles`

---

### Task 17：实现受控终端命令和工具安装提示

**目的：** Agent 可运行本机命令，但默认只读自动、变更需审批；不处理交互式密码/登录；缺工具时可提示用户让 App 帮装。

**Files:**

- Create: `lib/features/work_mode/work_command_runner.dart`
- Create: `lib/features/work_mode/work_command_policy.dart`
- Create: `test/work_mode/work_command_policy_test.dart`
- Create: `test/work_mode/work_command_runner_test.dart`

**怎么做：**

- [ ] 1. 写失败测试：允许 `pwd`/`git status`/`rg`；识别重定向、管道写入、`sed -i`、包安装、删除、移动、构建；拒绝工作目录越界；超时杀进程树；stdout/stderr 流式且有大小上限；取消后进程结束；检测密码提示后暂停。
- [ ] 2. 命令协议使用 `executable + arguments + workingDirectory + declaredImpact`，默认不经 shell；只有确需管道时使用系统 shell且 `impactUncertain=true`，强制审批。
- [ ] 3. 命令工作目录必须属于授权根；环境变量使用最小继承并删除已知敏感 App 凭据；日志脱敏 Authorization、API Key、token 模式。
- [ ] 4. 只读命令可自动；任何可能修改本地/外部状态的命令进入 `WorkChangePlan`。删除、不可逆覆盖、安装始终单独提示。
- [ ] 5. 缺失 executable 时发事件，说明工具用途、来源、将运行的安装命令、影响范围；用户选择后 App 才运行安装。V1 不自动输入 sudo 密码、不接管登录，遇到交互提示即暂停并让用户去外部终端处理。
- [ ] 6. V1 不默认运行测试或构建；仅当用户明确要求，或最终验收计划明确列出轻量检查时执行。代码修改后 Agent 默认仅做快速静态/语法检查。
- [ ] 7. 跑测试。

```bash
flutter test test/work_mode/work_command_policy_test.dart test/work_mode/work_command_runner_test.dart
```

**完成条件：** 命令不能绕过文件审批；模拟悬挂、超量输出和取消时没有遗留进程。

**Commit:** `feat(work-mode): add policy-controlled streaming command runner`

---

### Task 18：接入新循环并删除工作模式 localhost bridge 生产路径

**目的：** 让生产工作模式只走 App 内 Dart 工具服务，消除额外本地桥接服务和两套执行协议。

**Files:**

- Modify: `lib/features/chat_group/chat_room_agentic_generation_support.dart`
- Modify: `lib/features/agentic/agent_runtime.dart`
- Modify: `lib/features/agentic/agent_runtime_components.dart`
- Modify or delete if no other caller: `lib/features/agentic/tools/local_agent_bridge_launcher_io.dart`
- Modify or delete if no other caller: related local bridge files under `lib/features/agentic/tools/`
- Modify: tests under `test/agentic/` that assert old work-mode behavior
- Create: `test/work_mode/work_mode_end_to_end_test.dart`

**怎么做：**

- [ ] 1. 用 `rg` 列出 `AgentRuntime`、local bridge 和旧 tool executor 所有调用方，区分普通 agentic 功能与显式工作模式；先保存清单。
- [ ] 2. 写端到端失败测试：用户请求→角色选择→读取→审批→快照→写入→完成事件→追问→原文件修订→撤销。
- [ ] 3. 将 work mode 入口切到 `WorkAgentLoop`。现有 `ChatApiService`、API config、credential resolver、token accounting 继续复用，不另写模型客户端。
- [ ] 4. 从 `AgentRuntime` 删除仅服务旧 work mode 的 12 步/120 秒、XML/regex tool loop 和 localhost bridge 分支；仍被其他功能使用的逻辑保留并加注释说明 owner。
- [ ] 5. 运行 `rg` 确认生产 work mode 没有 bridge 调用，也没有两套审批 owner。

```bash
rg -n "LocalAgentBridge|local_agent_bridge|beginRun\(|pendingApproval" lib
flutter test test/work_mode/work_mode_end_to_end_test.dart test/work_mode test/agentic
```

**完成条件：** 端到端测试通过；工作模式无需启动 localhost 服务；普通聊天、技能和其他 agentic 功能回归通过。

**Commit:** `refactor(work-mode): switch production runtime to in-app agent loop`

---

## Stage 04：文档、视觉、无 Key 搜索与可见浏览器

### Task 19：做可见浏览器依赖兼容性闸门

**目的：** 在污染主实现前确认 `desktop_webview_window` 能在当前 Flutter fork、macOS、Windows 工程配置中编译；确认失败则采用系统浏览器降级，不留下半成品依赖。

**Files:**

- Modify only if spike passes: `pubspec.yaml`
- Generate only if spike passes: `pubspec.lock`
- Modify only if generated by package: macOS/Windows plugin registrants
- Create only if spike passes: `test/work_mode/desktop_browser_capability_test.dart`

**怎么做：**

- [ ] 1. 查官方 package 元数据和平台要求，记录 Dart SDK、macOS deployment target、Windows WebView2 要求；技术问题只依据官方包文档/源码。
- [ ] 2. 在临时分支/可回滚改动中加入精确兼容版本 `desktop_webview_window: 0.3.0`，运行依赖解析和 macOS debug 编译。此构建是依赖兼容性所必需，已被本计划明确授权。

```bash
flutter pub get
flutter build macos --debug
```

- [ ] 3. 若通过，保留依赖并写 capability test；若失败，完整回退该依赖改动，记录原因，Task 21 使用 `url_launcher` 打开系统浏览器作为明确降级，不能声称“App 内可见浏览器”。
- [ ] 4. Windows 只做静态工程和依赖配置审查；当前阶段不宣称 Windows 实机通过。启动时检测 WebView2，缺失时解释原因并询问是否由 App 打开微软官方安装流程。

**完成条件：** 只有真实 macOS 编译通过才保留 WebView 依赖；依赖失败时仓库无残留 import/config。

**Commit:** `build(work-mode): validate desktop visible browser dependency`

---

### Task 20：加入免 Key HTML 搜索并调整搜索优先级

**目的：** 将当前经常空结果的默认搜索改为：已配置/模型原生 → 免 Key HTML → 可见浏览器 → 明确失败。

**Files:**

- Create: `lib/features/web_search/providers/keyless_html_search_provider.dart`
- Modify: `lib/features/web_search/application/search_provider_route.dart`
- Modify: `lib/features/web_search/application/search_provider_chain.dart`
- Modify: `lib/features/web_search/application/search_coordinator.dart`
- Modify only if direct parser import is needed: `pubspec.yaml`
- Create: `test/web_search/keyless_html_search_provider_test.dart`
- Modify: `test/web_search/search_provider_chain_test.dart`

**怎么做：**

- [ ] 1. 先用保存的 HTML fixture 写失败测试，不让单测访问公网；覆盖正常结果、无结果、页面结构微调、429、验证码、超时、重定向、恶意链接和 HTML entity。
- [ ] 2. provider 只访问公开搜索结果页，不登录、不绕验证码/付费墙；设置明确 User-Agent、超时、最大响应字节和重定向上限。
- [ ] 3. 用 DOM 解析提取标题、URL、摘要；禁止用一条巨大正则解析 HTML。若直接 import `package:html`，把当前传递依赖声明为直接依赖并锁定兼容版本。
- [ ] 4. 把 route 顺序调整为：用户已配置 provider 或模型原生搜索；DuckDuckGo Instant Answer 可作为轻量来源但空结果不终止；keyless HTML；visible browser escalation。
- [ ] 5. URL 和来源写入事件记录；最终回答默认只给结论，不附链接；用户后续要求链接时从任务记录取出。
- [ ] 6. 跑 fixture 和链测试，再做一次可选真实网络 smoke test，真实网络失败只作为环境证据，不让单测不稳定。

```bash
flutter test test/web_search/keyless_html_search_provider_test.dart test/web_search/search_provider_chain_test.dart
```

**完成条件：** Instant Answer 空结果会继续 HTML provider；验证码/429 会升级或明确失败，不伪造搜索结果。

**Commit:** `feat(search): add keyless html fallback route`

---

### Task 21：实现可见浏览器搜索升级和人工接管

**目的：** 后台搜索失败时打开用户可见页面；遇到登录、验证码、付费墙暂停，由用户操作后手点继续。

**Files:**

- Create: `lib/features/work_mode/visible_browser_service.dart`
- Create: `lib/features/work_mode/presentation/visible_browser_panel.dart`
- Create: `test/work_mode/visible_browser_service_test.dart`
- Modify: `lib/features/work_mode/presentation/work_task_overlay_host.dart`

**怎么做：**

- [ ] 1. 写失败测试：合法 http/https；拒绝 file/javascript/data scheme；域名显示；导航记录；登录/验证码标记暂停；用户点击继续才恢复；关闭浏览器不自动取消任务。
- [ ] 2. 若 Task 19 通过，浏览器作为独立非模态窗口/面板展示；Agent 只读取当前公开页面中完成任务所需的有限文本，导航和读取写事件。
- [ ] 3. 禁止静默填密码、提交购买、绕过 CAPTCHA、访问付费内容。检测到这些状态时发 `paused` 事件和具体理由。
- [ ] 4. 用户手动完成网页操作后点击“继续”，服务重新读取当前页；不得监听或保存密码字段。
- [ ] 5. 若 WebView 依赖未通过，使用现有 `url_launcher` 打开系统浏览器，任务显示“等待用户完成后继续”；因为无法安全读回系统浏览器 DOM，要求用户粘贴必要结果，并把这项能力标为降级而非完成。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/visible_browser_service_test.dart test/work_mode/work_task_panel_test.dart
```

**完成条件：** 所有浏览器升级对用户可见；需人工介入时任务保持暂停，重启后仍可继续。

**Commit:** `feat(work-mode): add visible browser escalation and handoff`

---

### Task 22：接入文本、代码、PDF、DOCX、XLSX 和图片分析

**目的：** 工作模式读取/分析除音视频外的用户指定文件，并复用现有解析和视觉能力。

**Files:**

- Modify: `lib/features/document/document_understanding_service.dart`（仅补工作目录入口需要的窄 API）
- Modify: `lib/features/work_mode/work_tool_registry.dart`
- Create: `lib/features/work_mode/work_document_tool.dart`
- Create: `test/work_mode/work_document_tool_test.dart`
- Modify: `lib/features/ai_governance/model_capability_registry.dart`（只有发现能力判断缺口时）

**怎么做：**

- [ ] 1. 写失败测试：txt/md/json/常见代码；PDF 页码；DOCX 段落；XLSX sheet/cell；超大文档；损坏文件；图片+有视觉模型；图片+无视觉模型；音视频明确不支持。
- [ ] 2. 先调用 `WorkspacePathPolicy`，再把授权绝对路径适配成现有 `MediaAttachment`/`DocumentUnderstandingService` 输入；不复制 PDF/DOCX/XLSX 解析器。
- [ ] 3. 保留现有大小限制、分块和来源位置；工作任务只把相关 chunk 交给模型，事件记录文件名、页/sheet 范围和结论，不记录全文。
- [ ] 4. 图片先查当前角色绑定模型的 `ModelCapabilityRegistry`。支持 vision 才发送；不支持时暂停，列出准确原因并让用户选择其他已配置视觉模型，App 不自动切换。
- [ ] 5. 音视频返回结构化 `unsupportedMedia`，提示 V1 限制，不尝试外部转码或安装服务。
- [ ] 6. 跑测试。

```bash
flutter test test/work_mode/work_document_tool_test.dart test/document
```

**完成条件：** 所有支持格式均走现有解析能力；视觉模型切换只由用户决定；音视频没有假支持。

**Commit:** `feat(work-mode): analyze authorized documents code and images`

---

## Stage 05：错误恢复、安全硬化、完整自测与 macOS 安装包

### Task 23：统一错误分类、重试、暂停和恢复说明

**目的：** 用户看到具体错误和下一步，不再频繁出现无上下文的“执行失败”。

**Files:**

- Create: `lib/features/work_mode/work_failure.dart`
- Modify: `lib/features/work_mode/work_agent_loop.dart`
- Modify: `lib/features/work_mode/presentation/work_task_panel.dart`
- Create: `test/work_mode/work_failure_recovery_test.dart`

**怎么做：**

- [ ] 1. 写失败注入测试：模型 429/5xx/超时/空流；JSON 协议错；目录失效；文件外部改变；磁盘满；权限拒绝；快照失败；命令超时；App 重启；浏览器需人工。
- [ ] 2. 错误类型固定为：`retryableNetwork`、`modelProtocol`、`permissionDenied`、`authorizationLost`、`fileConflict`、`snapshotUnavailable`、`toolMissing`、`commandFailed`、`userActionRequired`、`internal`。
- [ ] 3. 每类包含用户可读标题、具体原因、安全化技术细节、已完成内容、是否可重试、建议动作。重试必须从安全检查点开始，不能重复已经提交的写入。
- [ ] 4. 面板失败态显示“重试/继续/重新授权/查看冲突/停止”中适用的动作；不提供无效按钮。
- [ ] 5. 跑测试。

```bash
flutter test test/work_mode/work_failure_recovery_test.dart
```

**完成条件：** 故障矩阵每一项都能得到确定状态和下一步；任何错误都不会清空追问、上下文或已完成操作清单。

**Commit:** `feat(work-mode): add explicit failure recovery states`

---

### Task 24：安全、数据生命周期、备份边界和代码质量审查

**目的：** 在 UI 验收前完整检查越权、凭据、快照清理、备份和结构质量，不以第一个问题为结束。

**Files:**

- Modify as required: `lib/features/backup/backup_snapshot.dart`
- Modify as required: `lib/features/backup/restore_plan.dart`
- Modify as required: `lib/core/database/data_lifecycle_*`
- Modify: `docs/work_mode_agent_v1_technical_design.md`（只更新与实际实现不同的最终决策）
- Create: `docs/verification/work_mode_agent_v1_security_review.md`

**怎么做：**

- [ ] 1. 明确备份策略：授权绝对路径、快照内容和治理日志不进入可移植备份；AgentTask 中的非便携绝对路径在导出时清空或标记需重新授权；API Key 始终排除。
- [ ] 2. 检查数据清除流程是否清理任务事件/快照但不删除用户授权目录内的真实文件；“清除 App 数据”必须列明它不会撤销已经写到项目中的文件。
- [ ] 3. 运行凭据扫描、路径策略测试、symlink/TOCTOU 测试、命令注入测试、日志脱敏测试。

```bash
rg -n "api[_-]?key|authorization|bearer|token|password" lib/features/work_mode test/work_mode
flutter test test/work_mode
```

- [ ] 4. 按 AGENTS.md 逐项 Review：需求符合性、正确性、失败路径、测试有效性、注释、命名、硬编码、函数长度、文件长度、模块化、性能、新老数据处理、安全。
- [ ] 5. 扫描占位符和重复旧实现。

```bash
rg -n "TODO|TBD|FIXME|placeholder|temporary|临时绕过|以后再说" lib/features/work_mode test/work_mode
rg -n "LocalAgentBridge|local_agent_bridge" lib test
find lib/features/work_mode -name '*.dart' -print0 | xargs -0 wc -l | sort -n
```

- [ ] 6. 报告必须列出所有问题、严重级别、文件/行号、证据、影响、修复方向；修完后重跑，不在发现第一个问题时停止。

**完成条件：** 无 P0/P1；所有 P2 要么修复要么得到用户明确接受；生产 work mode 无凭据落盘、无越权路径、无旧 bridge 双入口。

**Commit:** `chore(work-mode): harden lifecycle security and backup boundaries`

---

### Task 25：执行自动化测试、静态分析和 macOS debug 验证

**目的：** 用自动化覆盖所有已承诺能力；测试失败继续收集其余不依赖项，集中修复和复测。

**Files:**

- Modify: relevant tests only when a real defect is found
- Create: `docs/verification/work_mode_agent_v1_test_report.md`

**怎么做：**

- [ ] 1. 运行格式和静态分析。

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
git diff --check
```

- [ ] 2. 运行工作模式全套和关键回归。

```bash
flutter test test/work_mode
flutter test test/agentic test/web_search test/document
flutter test test/chat_room_page_lifecycle_test.dart test/agentic/chat_room_agent_task_recovery_test.dart
```

- [ ] 3. 运行全量测试；失败时记录全部失败，不只修第一个。

```bash
flutter test
```

- [ ] 4. 做 macOS debug 构建验证插件和 entitlement。由于用户明确要求完整自测，这一步属于必要构建，不是默认额外构建。

```bash
flutter build macos --debug
```

- [ ] 5. 报告记录每条命令、开始/结束时间、退出码、通过数、失败数、跳过项和原因；“单测通过”不能替代下一任务的真实 UI 验收。

**完成条件：** analyze、目标测试、全量测试和 macOS debug build 均通过；若存在环境阻塞，明确未验范围，不能给“全部完成”结论。

**Commit:** `test(work-mode): complete automated v1 verification`

---

### Task 26：用 computer-use 完成 macOS 真实 App 逐项验收

**目的：** 对每一个向用户承诺的 UI、权限、持续任务、搜索、浏览、恢复和撤销行为做真实操作，不只依赖 widget test。

**Files:**

- Create: `docs/verification/work_mode_agent_v1_macos_walkthrough.md`
- Store screenshots under: `docs/verification/evidence/work_mode_agent_v1/`

**怎么做：**

- [ ] 1. 启动 macOS App，准备两个临时授权目录、两个群、至少产品/开发/测试三个角色和一个私聊；测试文件不使用仓库用户真实文件。
- [ ] 2. 逐项执行并截图/记录：
  1. 首次无目录请求弹授权；
  2. 一次授权多个目录；
  3. 重启后仍有效；
  4. 任意对话默认读取；
  5. 首次写入列出精确路径；
  6. 设置关闭普通写提示；
  7. 删除仍强制提示；
  8. 新增审批外文件触发补充审批；
  9. 写入完成后一键撤销；
  10. 外部修改后撤销提示冲突且不覆盖；
  11. 离开聊天页任务继续；
  12. 隐藏面板任务继续；
  13. 停止按钮真正停止；
  14. 执行中连续发三条追问，按序处理；
  15. “修改当前文件”覆盖原路径；
  16. 关闭 App 后任务中断，重开只在手点继续后执行；
  17. 两会话并发、第三任务排队；
  18. 同文件冲突排队；
  19. `@角色` 精确路由；
  20. 无 @ 自动选角色并显示理由；
  21. 产品→开发→测试串行接力；
  22. 私聊互相隔离；
  23. 只读命令自动、变更命令审批；
  24. 缺工具给具体安装理由且不自动安装；
  25. 达到软限制后暂停并手点继续（通过测试设置缩短阈值，不真实等待 60 分钟）；
  26. PDF/DOCX/XLSX/代码解析；
  27. 有视觉模型分析图片；
  28. 无视觉模型时让用户选且不自动切；
  29. 免 Key HTML 搜索返回有效结果；
  30. 后台失败升级可见浏览器；
  31. 登录/验证码模拟页暂停等待用户；
  32. 最终回答默认不列链接，追问后可列；
  33. 普通聊天、自动聊天、主动私聊行为不变。
- [ ] 3. 使用 computer-use 操作时，每项记录输入、可见输出、文件系统前后状态和截图路径；涉及写入的项目都实际检查磁盘内容。
- [ ] 4. 任一项目失败后继续执行不依赖该失败的其余项目，最后集中列全问题并修复；修复后只重跑相关项目和一轮核心 smoke，不隐瞒首次失败。

**完成条件：** 33 项均有 PASS 证据；任何未测项都必须标为未完成，不能发布。

**Commit:** `test(work-mode): record complete macos agent walkthrough`

---

### Task 27：生成 macOS Release App 和无需额外服务的本地 DMG

**目的：** 交付用户双击即可安装的单 App 包；运行时只需要用户自己的模型 API，不要求另装守护进程、数据库、容器或本地服务。

**Files:**

- Create: `scripts/package_macos_dmg.sh`
- Create: `docs/verification/work_mode_agent_v1_release_checklist.md`
- Modify only if required: `macos/Runner/Release.entitlements`

**怎么做：**

- [ ] 1. 脚本只调用 Flutter 和 macOS 自带 `hdiutil`：先 release build，再把 `.app` 和 Applications 链接放入临时 staging 目录，最后生成版本化 DMG。临时目录用 `mktemp -d` 并用 trap 清理；不得递归删除宽泛路径。
- [ ] 2. 构建 release。

```bash
flutter build macos --release
```

- [ ] 3. 在干净测试用户环境安装 DMG，验证首次启动、目录选择、读写提示、任务面板、重启恢复和网络调用；确认没有 localhost bridge 进程，也没有要求安装额外服务。
- [ ] 4. 检查包内无开发 Hive、API Key、测试证据中的私密路径和临时快照。

```bash
find build/macos/Build/Products/Release -maxdepth 2 -type f | sort
rg -a -n "api_configs\.hive|Bearer |sk-[A-Za-z0-9]" build/macos/Build/Products/Release || true
```

- [ ] 5. 用 `shasum -a 256` 记录 DMG 哈希、App 版本、macOS 版本、签名/公证状态。若未签名或未公证，必须在交付说明中明确 Gatekeeper 打开方式和限制，不伪称正式分发包。
- [ ] 6. Windows 代码保留兼容路径和测试，但当前只声明“已实现/静态验证”，不声明 Windows 实机验收；Windows 安装包列入后续真实 Windows 环境任务。

**完成条件：** DMG 可在测试 Mac 安装并完成核心 smoke；App 运行不启动/要求额外服务；发布清单明确签名和 Windows 验证边界。

**Commit:** `build(macos): package work mode agent v1 dmg`

---

## 逐 Task 可复制执行提示词

下面的提示词与前述 Task 一一对应。一次只执行一段；完成并通过该 Task 的门禁后，才复制下一段。提示词要求执行者先读取规格和 Ponytail，因此既能在当前会话使用，也能交给一个没有上下文的新执行会话。

### Stage 01 提示词

#### Task 01 执行提示词

```text
你现在只执行 Work Mode AI Agent V1 的 Stage 01 / Task 01：冻结基线并建立规格追踪测试，不实现任何新功能。

开始前完整读取仓库 AGENTS.md、/Users/fengye/.codex/skills/ponytail/SKILL.md、docs/work_mode_agent_v1_requirements.md、docs/work_mode_agent_v1_technical_design.md，以及本计划的 Task 01。先运行 git status --short，保护所有已有未提交改动，尤其不要修改 character_skill_resolver.dart、expert_skill_catalog.dart、它们的测试以及两个未跟踪模板文件。

用 rg 检查 chat_activity_policy.dart、chat_room_agentic_round_support.dart 和 DirectChatForegroundWatcher 的现有入口。在 test/work_mode/work_mode_v1_spec_guard_test.dart 建立 FR-01～FR-09 的追踪清单，并先实现四条可由当前代码证明的隔离测试：普通聊天不进入工具运行时、工作模式开启时自动聊天暂停、关闭后恢复原策略、主动私聊不创建工作任务。测试名称必须直接表达需求，不允许空测试、skip 或只断言 true。

运行 flutter test test/work_mode/work_mode_v1_spec_guard_test.dart，再运行 flutter analyze 和当前 work_mode/recovery/lifecycle 基线测试。记录每条命令、退出码和任何既有失败；不要为了让测试变绿改变产品代码。执行 git diff --check。完成后只汇报：改动文件、冻结的四项行为、命令结果、既有阻塞、是否满足 Task 01 完成条件。不要开始 Task 02，不要提交，除非用户明确要求提交。
```

#### Task 02 执行提示词

```text
你现在只执行 Stage 01 / Task 02：把现有 AgentTask 扩展成可恢复的 App 级工作任务记录，并加入幂等 V1 迁移。严格执行 TDD 和 Ponytail，不建立第二套任务数据库。

开始前读取 AGENTS.md、Ponytail、三份工作模式文档和 AgentTask/DatabaseService/WorkModeWorkspace 的完整实现；运行 git status 并保护用户已有改动。先在 work_mode_v1_migrator_test.dart 和 work_mode_task_recovery_test.dart 写失败测试，准确覆盖：默认 100 动作和 60 分钟软限制、追问 FIFO、意外中断必须手点继续、旧 workModeTask 记录只在首次迁移清理、普通 AgentTask/聊天/角色/消息不清理、重复迁移无副作用。

只在 AgentTask 末尾追加新的 HiveField 编号，保存 queuedUserRequests、contextSummary、assignedCharacterIds、startedAt、actionCount、softLimitReached、resumeRequired、executionStateJson、lastArtifactPaths；增加 queued/paused/interrupted 状态并修正 canResume/isTerminal。列表必须防共享可变引用，JSON 不得含 API Key 或文件全文。WorkModeV1Migrator 用 app_settings 的 work_mode_agent_schema_version 做幂等门闩，只删除旧工作任务和旧 workspace。不得手改 agent_task.g.dart，必须运行 dart run build_runner build。

先证明测试因缺字段/迁移而失败，再写最小实现，再运行指定两组测试、flutter analyze、git diff --check。逐项审查新增 Hive 字段编号和旧普通任务保留行为。完成报告列出模型字段、迁移删除范围、测试前后结果和未验证项。不要开始事件流或协调器，不要擅自提交。
```

#### Task 03 执行提示词

```text
你现在只执行 Stage 01 / Task 03：建立持久化且脱敏的工作任务事件流，为全局执行面板提供唯一事实来源。不要做面板 UI。

先读取 AGENTS.md、Ponytail、需求/技术设计/本计划 Task 03，并检查 DatabaseService 的 App Support 路径获取方式，优先复用。先写 work_task_event_store_test.dart 的失败测试：sequence 单调递增、重启重放、同任务并发追加不丢失、截断的最后一行不破坏之前事件、内容长度上限、API Key/Authorization/token 脱敏。

创建 WorkTaskEvent 和 WorkTaskEventStore。事件类型只能是 queued、planning、stepStarted、toolOutput、approvalRequired、paused、stepCompleted、failed、completed、undoCompleted；字段限制为 taskId/sequence/timestamp/kind/title/detail/progressCurrent/progressTotal/safeMetadata。存储路径为 App Support/work_mode_agent/events/<taskId>.jsonl，同任务写入串行化、每次追加 flush，损坏末行跳过并返回安全诊断。禁止把模型私有推理、系统提示词、文件正文、API Key、Authorization header 写入事件文件；stdout 只保留有界安全摘要。

运行单测、flutter analyze、git diff --check，并人工检查一份测试生成的 jsonl 确认无秘密和结构一致。报告事件 schema、持久化路径、损坏恢复证据、脱敏证据。不要创建执行面板，不要开始 Task 04，不要擅自提交。
```

#### Task 04 执行提示词

```text
你现在只执行 Stage 01 / Task 04：实现 App 级 WorkTaskCoordinator、每会话 FIFO 队列和全局并发上限 2。协调器不能依赖 BuildContext，也不能 autoDispose。

先读取 AGENTS.md、Ponytail、规格、Task 04、现有 Riverpod provider 模式和 AgentTask persistence。用 FakeWorkTaskRunner 先写失败测试，记录实际最大并发，覆盖：全局最多两个运行任务、同 conversationId 最多一个、第三个任务 queued、槽位释放后 FIFO 开始、新追问追加而不是取消、取消只影响目标任务、App 启动只恢复状态不自动续跑。

用最小接口 WorkTaskRunner.run(AgentTask, WorkTaskCancellation) 隔离协调器与后续 Agent loop。协调器唯一持有运行任务、取消、调度、恢复和会话队列，公开 submit、enqueueFollowUp、stop、resumeByUser、continueAfterSoftLimit、watchTask、watchAllTasks。provider 必须从根 ProviderScope 取得 DatabaseService/EventStore，且离开页面不会 dispose。异常路径用 try/finally 释放槽位并持久化状态。

先运行测试确认因类不存在而失败，再实现最小代码，运行 coordinator 测试、flutter analyze、git diff --check。检查没有第二套内存 owner、没有页面对象引用、没有启动自动 resume。报告并发测量值、FIFO 证据、持久化边界。不要接聊天页，不要开始 Task 05，不要擅自提交。
```

#### Task 05 执行提示词

```text
你现在只执行 Stage 01 / Task 05：把聊天页的工作模式输入改为提交给全局协调器，移除“新输入取消旧任务”和“页面销毁停止任务”的旧所有权。普通聊天行为必须保持不变。

先完整读取 AGENTS.md、Ponytail、Task 05 列出的所有 chat_room_agentic_*、page lifecycle/state、WorkModeSession/Lifecycle 文件及相关测试。先把旧测试“新输入取消待审批任务”改成新规则并确认失败：新输入进入当前任务 FIFO，旧任务继续；离开聊天室后 fake runner 完成；回到聊天室看到原 taskId；App 重启后的 interrupted 任务只有点击继续才运行。

页面只保存用户消息并调用 coordinator.submit/enqueueFollowUp，不再拥有工作任务 CancelToken，不再 await 完整执行。dispose 只能解除 UI/文档临时订阅，用户点击停止才调用 coordinator.stop。待审批 owner 迁到协调器；WorkModeSession 若只剩 UI 开关就缩减，否则删除，绝不能保留两套 pendingApproval/activeRun。保留工作模式开启时暂停 auto-chat 的现有规则。

运行本 Task 指定的三个测试文件、work_mode_v1_spec_guard_test、flutter analyze、git diff --check；用 rg 检查 beginRun/pendingApproval/requestStop 的所有生产调用并解释每个剩余调用。报告新输入路径、dispose 行为、恢复行为和普通模式回归。不要实现面板，不要开始 Task 06，不要擅自提交。
```

#### Task 06 执行提示词

```text
你现在只执行 Stage 01 / Task 06：实现全 App 非模态、可收起/隐藏但不停止任务的执行面板。不得展示模型私有思维。

先读取 AGENTS.md、Ponytail、UI 规格、main.dart 的 MaterialApp.builder、DirectChatForegroundWatcher 和协调器事件 API。先写 widget 失败测试：显示任务标题/执行角色/当前步/总步/时长，事件按 sequence 展示，收起后有迷你状态条，隐藏后 runner 仍运行，只有停止按钮取消，可在两个运行任务间切换，回到对话按钮导航正确。

创建 WorkTaskPanel 和 WorkTaskOverlayHost，并在 MaterialApp.builder 中保留现有 DirectChatForegroundWatcher、navigatorKey 和 scaffoldMessengerKey。桌面宽屏使用右侧非模态面板，窄窗口使用非模态底部区域，不能屏蔽主界面操作。面板只展示计划摘要、公开动作、工具名、脱敏输出、审批原因和结论；禁止显示 chain-of-thought、系统提示词、API Key、文件全文。隐藏/关闭只是 UI 状态，stop 才调用协调器。

运行 widget 测试、现有 main/widget 导航回归、flutter analyze、git diff --check。手工审查所有 Text 输出来源是否经过脱敏。报告宽/窄布局、隐藏与停止差异、流式事件证据。不要实现文件授权或写入工具，不要开始 Stage 02，不要擅自提交。
```

### Stage 02 提示词

#### Task 07 执行提示词

```text
你现在只执行 Stage 02 / Task 07：实现 App 级多文件夹授权和设置入口。授权一次后对所有工作模式对话默认有效，不做递归预扫描。

先读取 AGENTS.md、Ponytail、FR-01/FR-08、现有 file_picker 用法、Settings 拆分模式和 app_settings API。先写 service/widget 失败测试：多目录保存、规范化去重、父目录覆盖子目录、移除立即失效、不存在目录显示不可用、重启保留、首次无授权任务触发选择、取消选择后任务暂停。

复用 file_picker 的 getDirectoryPath，不新增选择器依赖。WorkFolderGrantService 持久化规范绝对路径、显示名、添加时间、最近验证时间；启动只做 exists/access 轻量验证，不扫描内容。设置页新增工作模式 Agent 区域：授权列表、添加/移除/重新授权、普通写入确认开关、30 天/2GB、100 步/60 分钟说明。删除与不可撤销覆盖的强制确认不能关闭。首次工作请求无根目录时发 approvalRequired 事件并请求目录；取消后保留任务 paused 和明确原因。

运行两个目标测试、settings 回归、flutter analyze、git diff --check。检查授权记录不进入普通聊天 prompt、不出现在未脱敏日志。报告持久化 key、目录失效表现和设置开关边界。不要实现文件读取或写入，不要开始 Task 08，不要擅自提交。
```

#### Task 08 执行提示词

```text
你现在只执行 Stage 02 / Task 08：实现授权目录内的规范路径策略和有界只读文件工具。安全重点是阻止 ..、相似前缀、symlink 和 Windows 大小写绕过。

先读取 AGENTS.md、Ponytail、FR-02、Task 08、dart:io FileSystemEntity 行为。用临时目录写失败测试，覆盖 POSIX/Windows 表示、反斜杠、盘符大小写、/work/a 与 /work/ab、..、授权根、指向根外的 symlink、损坏 symlink、新文件的最近存在父目录、超大文本、二进制、取消、目录分页和搜索预算。

WorkspacePathPolicy 对已存在目标解析真实路径；新目标解析最近存在父目录；最终按路径 segment 判定是否处于任一有效根，禁止 startsWith 授权。WorkspaceFileService 只提供 listDirectory/stat/readTextRange/searchText，目录默认不递归，读取/搜索有文件数、字节、耗时、输出长度和取消上限。UTF-8 严格解码失败明确报告非文本。敏感命名文件允许按用户授权读取，但事件只记录敏感读取发生并脱敏，正文不得落盘。

运行两个目标测试、flutter analyze、git diff --check。在测试中实际证明 symlink 指向根外被拒绝。报告所有边界上限和 Windows 静态覆盖；不要实现 mutation，不要开始 Task 09，不要擅自提交。
```

#### Task 09 执行提示词

```text
你现在只执行 Stage 02 / Task 09：建立 WorkChangePlan、统一变更策略和任务级写入审批 UI。此任务只做计划/审批，不实际写文件。

先读取 AGENTS.md、Ponytail、FR-03/FR-04、审批技术设计和现有 showDialog 模式。先写 policy/widget 失败测试：首次可撤销写提示、同一已批准文件集合内不重复提示、新文件触发补充审批、关闭普通写提示后删除/不可撤销覆盖/影响不确定命令仍提示、拒绝零执行、关闭弹窗只暂停、弹窗列出准确绝对路径和理由。

WorkChangePlan 必须包含动作类型、精确路径、已知受影响目录、预计字节、快照可用性、可撤销性、命令和风险理由。批准范围只能是 taskId + 明确文件/目录影响集合，不能是任务全写权限。命令无法精确枚举时列出 executable/arguments/workingDirectory/已知文件/可能目录并标 impactUncertain=true。审批文案回答为什么、做什么、哪些路径、能否撤销；禁止“标准工具调用”模糊文案。

运行目标测试、flutter analyze、git diff --check。用 fake executor 证明任何拒绝/关闭决定都没有执行回调。报告审批范围序列化格式、强制提示矩阵和补充审批行为。不要写文件，不要开始 Task 10，不要擅自提交。
```

#### Task 10 执行提示词

```text
你现在只执行 Stage 02 / Task 10：实现唯一的原子文件变更入口 WorkspaceMutationService。所有动作必须已拥有 ChangePlan 和批准，不要绕过快照接口预留点。

先读取 AGENTS.md、Ponytail、Task 10、路径策略和审批模型。用临时目录先写失败测试：无批准零写入；临时文件 flush 后原子替换；中途异常保留原文件；patch 原 SHA-256 不匹配返回 conflict；重命名目标已存在重新分类；删除只触及精确路径；取消无半文件；审批后 symlink 改变被二次校验拒绝。

执行前再次调用 WorkspacePathPolicy，不能信任计划时结果。创建/覆盖写同目录临时文件后 flush/rename；Windows 无法直接安全覆盖时走明确的受控替换路径，但必须要求已有快照。文本 patch 带原内容哈希和明确片段，冲突后要求 Agent 重读，不做模糊 patch。每个成功动作写不含正文的 stepCompleted 事件，失败写明确安全原因。把旧 AgentRuntime 写入逻辑接线留到 Task 18，本任务不做双入口兼容。

运行 mutation 测试、路径/审批回归、flutter analyze、git diff --check。检查失败注入后磁盘前后哈希。报告原子性、TOCTOU 防护和冲突语义。不要实现快照正文或 Agent loop，不要开始 Task 11，不要擅自提交。
```

#### Task 11 执行提示词

```text
你现在只执行 Stage 02 / Task 11：实现任务级快照、30 天/2GB 清理和一键撤销，并接入 MutationService 与面板。

先读取 AGENTS.md、Ponytail、Task 11、DatabaseService App Support 路径和现有数据清理原则。先写失败测试：覆盖/删除前备份、新文件撤销时删除、重命名逆转、多动作逆序、外部修改导致冲突且不覆盖、快照失败默认阻止、用户单独确认无撤销后才执行、30 天/2GB 清理顺序、活动任务不清理。

快照目录固定为 App Support/work_mode_agent/snapshots/<taskId>，manifest JSON 保存动作序号、原/目标路径、mtime、size、SHA-256、备份相对路径、完成状态，不保存 API Key。审批后且真实 mutation 前创建快照；失败返回 snapshotUnavailable，普通写入免提示设置不能跳过“无撤销执行”确认。撤销前重验授权和当前哈希，冲突逐项报告并保留外部新内容。面板完成态增加撤销按钮，确认框列出恢复/删除文件。

运行 snapshot、mutation、panel 测试、flutter analyze、git diff --check。实际检查 manifest 与恢复后哈希，模拟超过保留期限和 2GB（可用 fake size/clock）。报告快照路径、清理顺序、冲突策略。不要实现资源锁，不要开始 Task 12，不要擅自提交。
```

#### Task 12 执行提示词

```text
你现在只执行 Stage 02 / Task 12：实现跨任务文件/目录资源锁，并接入全局协调器。目标是两个全局并行任务永不同时冲突写同一资源。

先读取 AGENTS.md、Ponytail、Task 12、路径规范和 coordinator。先写并发失败测试：同文件写写冲突、目录 treeWrite 与子文件冲突、read/read 可并行、read/write 串行、FIFO、取消等待者移除、运行者抛错后释放、一次多锁稳定排序无死锁、Windows 路径大小写归一、重启不恢复陈旧内存锁。

锁 key 使用规范绝对路径与 read/write/treeWrite 模式。一次计划先计算完整锁集合，按稳定顺序原子申请；不能取得时 AgentTask=queued，事件说明等待哪个安全化路径，等待不增加 actionCount。运行体必须 try/finally 释放。重启把旧 running 标为 interrupted，用户继续后重新取锁和重验文件状态。

运行 lock/coordinator/mutation 测试、flutter analyze、git diff --check。加入记录时间区间的压力测试并断言冲突写区间无重叠。报告锁兼容矩阵、FIFO 和异常释放证据。不要开始 Agent 协议，不要开始 Stage 03，不要擅自提交。
```

### Stage 03 提示词

#### Task 13 执行提示词

```text
你现在只执行 Stage 03 / Task 13：定义唯一 JSON AgentDecision 协议和严格 parser，开始替代旧正则/XML 猜测，但暂不接生产循环。

先读取 AGENTS.md、Ponytail、工作模式协议设计、现有 AgentRuntime 解析分支、ChatApiService 对 content/reasoning_content/stream 的处理。先写表驱动失败测试：合法 plan/tool/clarify/handoff/finish、未知 action、缺字段、类型错、代码围栏、多个 JSON、content 空但 reasoning_content 有值、两者都空、一次修复成功/失败。

顶层固定 action/public_update/tool/completion；为每个 action 建立类型安全模型，工具参数仍是受校验 Map。只允许一次将原响应作为数据交给同一模型修复为 JSON，第二次失败返回 modelProtocol；不要添加任何新的 XML 标签、Markdown fence 或宽松正则 fallback。保留红线：标准 content 空才读 reasoning_content，两者空明确失败；流式空响应只允许同请求一次非流式回退。public_update 只描述公开动作/依据/结论，不允许私有思维。

运行 parser 测试和现有 SSE/agent parser 回归、flutter analyze、git diff --check。用 rg 列出旧解析分支，注明哪些将在 Task 18 删除，当前不要大范围重构。报告协议 schema、非法样例结果和一次修复边界。不要开始 Agent loop，不要擅自提交。
```

#### Task 14 执行提示词

```text
你现在只执行 Stage 03 / Task 14：实现 WorkAgentLoop 和结构化 WorkToolRegistry，支持连续多步、有界重试、停止检查点及 100 动作/60 分钟软限制。

先读取 AGENTS.md、Ponytail、Task 14、AgentDecision、coordinator、现有模型调用/重试策略。用 Fake model、Fake tools 和 fake clock 先写失败测试：20+ 步序列、每步事件、暂时网络错误有界重试、权限/越界不重试、模型前/工具前/工具后停止、100 动作暂停、60 分钟暂停、手点继续后保留上下文并不重复已提交写入、finish 自动完成。

ToolRegistry 只允许已注册 name/schema；read-only 自动执行，mutation 必须经过策略→审批→快照→锁→执行。循环顺序固定为取消/软限检查、上下文、模型、解析、公开事件、工具校验、执行、检查点。重试次数/退避用命名常量；协议错仅一次修复；用户判断、授权、登录、验证码、付费墙和软限进入 paused。不要输出/保存 chain-of-thought。

运行 loop、decision、coordinator 测试、flutter analyze、git diff --check。核对 actionCount 只在真实 Agent 动作增加，锁等待和用户等待不增加。报告多步轨迹、重试矩阵和继续语义。不要接聊天生产入口，不要开始 Task 15，不要擅自提交。
```

#### Task 15 执行提示词

```text
你现在只执行 Stage 03 / Task 15：实现持久追问队列、上下文压缩和“修改当前/上次/同一文件”原路径修订策略。

先读取 AGENTS.md、Ponytail、FR-06、现有 AgentRuntime revision 判断、聊天 conversationId/DM key 规则和 AgentTask 新字段。先写失败测试：运行中连续三条追问 FIFO；当前任务完成后自动处理第一条；明确修订词命中 lastArtifactPaths；新建重名才改名；目标多义只问一个精确问题；群内成员共享上下文；dm:A 不能读取 dm:B；重启后摘要/路径/队列仍在。

WorkContextBuilder 只持久化目标、未决追问、已完成摘要、最近工具安全结果、审批范围、产物路径、角色接力、错误和下一步；大文件正文按需重读，不写入摘要。压缩模型失败用确定性裁剪，先保留不可丢字段。WorkFollowUpPolicy 优先用结构化 lastArtifactPaths + 明确措辞，不用全局最近文件猜测。conversationId 是严格隔离边界。

运行 context/follow-up/coordinator/recovery 测试、flutter analyze、git diff --check。检查持久化 JSON 不含文件全文或其他私聊内容。报告修订词策略、歧义行为、群/私聊隔离证据。不要实现角色路由，不要开始 Task 16，不要擅自提交。
```

#### Task 16 执行提示词

```text
你现在只执行 Stage 03 / Task 16：实现 @角色指定、无 @ 自动角色选择和产品→开发→测试串行接力；同一对话任何时刻只能一个角色执行。

先读取 AGENTS.md、Ponytail、角色/技能/persona 数据模型、现有 mention parser 和 Task 16。先用 rg 判断 mention_parser 是否可直接复用，不能为了新功能复制解析器。写失败测试：精确 @、重名、无 @ 产品文档/编码/测试任务、能力不足、私聊固定角色、handoff 三阶段、前角色释放锁后后角色启动、100 次压力调度活动角色最大值 1。

路由优先级固定：有效显式 @、私聊固定角色、当前 handoff、模型基于 persona/skills/职业选择、可解释的确定性兜底。模型结果包含角色 ID、公开理由、置信度、是否接力；不存在/不适合时告知具体原因，不静默换角色或模型。HandoffState 持久化阶段、交付物、接收角色、完成条件；角色切换不创建第二个 conversation runner。

运行 role router、coordinator、follow-up 测试、flutter analyze、git diff --check。报告复用的 mention 能力、每类路由理由、串行压力证据。不要实现终端，不要开始 Task 17，不要擅自提交。
```

#### Task 17 执行提示词

```text
你现在只执行 Stage 03 / Task 17：实现受控、流式的本机命令执行和缺工具安装提示。V1 不自动处理 sudo 密码、登录或其他交互凭据。

先读取 AGENTS.md、Ponytail、FR-04、Task 17、当前 Process/bridge 用法和审批/快照/锁策略。先写失败测试：pwd/git status/rg 只读自动；重定向、sed -i、移动、删除、包安装和构建被判定为 mutation；工作目录越界拒绝；默认不经 shell；管道必须 impactUncertain；stdout/stderr 流式有上限；超时/取消终止进程树；密码提示暂停；环境变量不含 App API Key。

命令模型为 executable/arguments/workingDirectory/declaredImpact。只读可自动，任何本地或外部状态修改必须产生 WorkChangePlan；删除、不可逆覆盖、安装始终单独提示。缺 executable 时说明用途、可信来源、将执行命令和影响范围，用户同意后才安装。检测 sudo/password/login prompt 立即暂停并指引用户外部终端处理，不模拟输入。默认不运行测试/构建，除非用户明确要求或验收计划授权轻量检查。

运行 policy/runner/mutation/lock 测试、flutter analyze、git diff --check。检查取消和超时后无遗留测试进程，日志已脱敏。报告分类矩阵、进程清理和安装提示内容。不要接生产 AgentRuntime，不要开始 Task 18，不要擅自提交。
```

#### Task 18 执行提示词

```text
你现在只执行 Stage 03 / Task 18：把生产工作模式接到 WorkAgentLoop，并删除 localhost bridge 和旧多协议 work-mode 路径。不得破坏普通聊天、技能或其他仍使用 AgentRuntime 的能力。

先读取 AGENTS.md、Ponytail、Task 18、AgentRuntime/Components、chat_room_agentic_generation_support 和 tools 目录。先用 rg 生成所有 AgentRuntime、LocalAgentBridge、beginRun、pendingApproval 调用清单，逐个标注 work mode 专用或其他功能共用。先写完整端到端失败测试：用户目标→角色→读取→审批→快照→写→完成事件→追问→原文件修订→撤销。

生产 work mode 入口只调用 WorkAgentLoop；继续复用 ChatApiService、ApiConfig、CredentialResolver、token accounting，不建立模型客户端。删除仅属于旧 work mode 的 12 步/120 秒、XML/regex tool loop、localhost bridge 和页面审批 owner；共用逻辑保留且写清 owner。不得为了兼容保留两套运行时或静默 fallback。源码产物无可运行模板时继续明确失败，不能把说明文字伪装成代码。

运行端到端、全部 work_mode、agentic、普通模式隔离测试和 flutter analyze；用 rg 证明生产 work mode 无 bridge/双 owner。git diff --check 后逐文件 Review 大型删除是否误伤。报告删除清单、保留调用理由、端到端证据和普通功能回归。不要开始 Stage 04，不要擅自提交。
```

### Stage 04 提示词

#### Task 19 执行提示词

```text
你现在只执行 Stage 04 / Task 19：做 desktop_webview_window 兼容性 spike。此任务的结论可以是“保留依赖”或“完整回退”，不能在未编译通过时进入生产代码。

先读取 AGENTS.md、Ponytail、Task 19、pubspec 依赖覆盖说明和 macOS/Windows 工程配置。只依据官方 package 文档/源码核对 0.3.0 的 Dart SDK、macOS target 和 Windows WebView2 条件。记录变更前 git status。临时加入精确版本，运行 flutter pub get 和 flutter build macos --debug；检查生成的 plugin registrant 和 Pod 变化。

若 macOS debug build 通过，保留依赖，添加 capability test，记录 Windows WebView2 启动检测要求。若失败，使用 apply_patch 完整移除 pubspec/import/config 临时变化并重新 flutter pub get，确认 git diff 无残留；后续只能采用 url_launcher 降级并明确能力差异。Windows 当前只做静态配置审查，不宣称实机通过，不安装任何额外服务。

执行 flutter analyze、git diff --check。报告官方要求、精确命令/退出码、保留或回退决定、Windows 未验边界。不要实现浏览器 UI，不要开始 Task 20，不要擅自提交。
```

#### Task 20 执行提示词

```text
你现在只执行 Stage 04 / Task 20：实现免 Key HTML 搜索 provider，并把优先级调整为已配置/模型原生→Instant Answer→HTML→可见浏览器升级。

先读取 AGENTS.md、Ponytail、FR-07、现有 SearchProviderChain/Coordinator/route/provider models。先保存公开搜索结果 HTML 为测试 fixture（fixture 不含个人查询），写不联网的失败测试：正常结果、空结果、HTML 结构小变化、entity、恶意 URL、429、验证码、超时、重定向、超大响应。测试必须验证 Instant Answer 空结果继续下一 route。

KeylessHtmlSearchProvider 只访问公开结果页，设置明确 User-Agent、超时、最大字节和重定向上限；不登录、不绕验证码/付费墙。使用 DOM parser，不用大正则；若直接 import package:html，就在 pubspec 声明当前兼容精确版本。结果统一成现有 SearchProviderResponse。URL/来源写安全事件，最终回答默认只给结论，用户追问链接时再从记录提供。

运行 provider fixture 测试、chain/coordinator 回归、flutter analyze、git diff --check；再做一次可选真实网络 smoke，仅记录环境结果，不让单测依赖公网。报告 provider 顺序、空结果行为、验证码/429 升级语义。不要实现可见浏览器，不要开始 Task 21，不要擅自提交。
```

#### Task 21 执行提示词

```text
你现在只执行 Stage 04 / Task 21：实现后台搜索失败后的用户可见浏览器升级和人工接管。必须服从 Task 19 的依赖结论。

先读取 AGENTS.md、Ponytail、Task 19 结论、Task 21 和全局面板。先写失败测试：只允许 http/https，拒绝 file/javascript/data；显示域名和导航；登录/验证码/付费墙进入 paused；关闭浏览器不停止任务；用户点击继续才恢复；密码字段不读取/持久化。

若 WebView spike 通过，创建 VisibleBrowserService/Panel，以独立非模态窗口或面板显示，读取当前公开页面中完成任务所需的有限文本，导航和读取写事件。绝不自动填密码、提交购买或绕 CAPTCHA。人工完成后必须手点继续。若 spike 未通过，复用 url_launcher 打开系统浏览器，任务明确提示用户完成后粘贴必要结果；不能声称能安全读回 DOM，也不能把降级伪装成完整能力。

运行 visible browser、panel、URL 安全测试、flutter analyze、git diff --check。报告实际采用方案、人工暂停/继续轨迹、禁止 scheme 证据和能力降级。不要实现文档工具，不要开始 Task 22，不要擅自提交。
```

#### Task 22 执行提示词

```text
你现在只执行 Stage 04 / Task 22：让工作模式读取/分析文本、代码、PDF、DOCX、XLSX 和图片；音视频明确不支持。必须复用现有 DocumentUnderstandingService/BinaryDocumentParser/ModelCapabilityRegistry。

先读取 AGENTS.md、Ponytail、FR-02、现有文档解析/多模态内容/模型能力代码。先写失败测试：txt/md/json/多种代码、PDF 页码、DOCX 段落、XLSX sheet+cell、超大和损坏文件、授权外路径、图片+视觉模型、图片+非视觉模型、音频/视频 unsupported。

WorkDocumentTool 先过 WorkspacePathPolicy，再适配现有 MediaAttachment/DocumentUnderstandingService，不复制解析器。保留大小限制、分块、来源位置和取消；只把相关 chunk 给模型，事件只记文件名和页/sheet 范围。图片先查当前角色模型能力，支持才发送；不支持就 paused，说明准确原因并让用户选择其他已配置视觉模型，App 不自动切换。音视频返回结构化 unsupportedMedia，不装转码服务。

运行 work_document_tool_test 和现有 document/multimodal/capability 回归、flutter analyze、git diff --check。报告每种格式的实际解析证据、视觉模型选择边界和不支持项。不要开始 Stage 05，不要擅自提交。
```

### Stage 05 提示词

#### Task 23 执行提示词

```text
你现在只执行 Stage 05 / Task 23：统一工作模式错误分类、重试/暂停状态和用户可执行的恢复说明。目标是任何失败都保留上下文并说明下一步。

先读取 AGENTS.md、Ponytail、Task 23、Agent loop、面板和已有 search failure 模式。先做失败注入测试：模型 429/5xx/超时/空流、协议错、目录失效、文件外部改变、磁盘满、审批拒绝、快照失败、命令超时、App 重启、浏览器人工介入。每个测试同时断言任务状态、已完成动作、队列/上下文保留和可用 UI 动作。

WorkFailure 类型固定为 retryableNetwork/modelProtocol/permissionDenied/authorizationLost/fileConflict/snapshotUnavailable/toolMissing/commandFailed/userActionRequired/internal；每类包含标题、具体原因、脱敏技术细节、已完成内容、retryable、建议动作。重试从安全检查点开始，不能重复已提交 mutation。面板只展示适用的重试/继续/重新授权/查看冲突/停止按钮。

运行 recovery、loop、panel、search failure 回归、flutter analyze、git diff --check。确认没有 catch(Object) 后静默继续或清空任务。报告完整故障矩阵和每类恢复动作。不要开始安全总审查，不要开始 Task 24，不要擅自提交。
```

#### Task 24 执行提示词

```text
你现在只执行 Stage 05 / Task 24：完成整个 V1 改动集的安全、数据生命周期、备份边界和代码质量审查，并修复审查发现的问题。发现一个问题不能停止检查。

先读取 AGENTS.md 的 Review/代码质量完整性规则、Ponytail、全部需求和技术设计。明确审查范围为所有 V1 代码、测试、设置、迁移、事件、快照、搜索、浏览器和命令。核对：授权绝对路径/快照/治理日志不进入可移植备份；导出任务清空非便携路径；API Key 排除；清除 App 数据只清事件/快照而不删除项目真实文件；撤销与清数据文案无歧义。

逐项运行凭据扫描、symlink/TOCTOU、命令注入、日志脱敏、备份/恢复、数据清理和全 work_mode 测试。扫描 TODO/TBD/FIXME/临时绕过、LocalAgentBridge 残留和文件行数。逐文件检查需求符合性、正确性、失败路径、测试有效性、注释、命名、硬编码、函数/文件长度、模块化、性能、数据处理、安全。一次性列全 P0/P1/P2，再用最小改动修复并重跑相关测试。

把最终证据写入 docs/verification/work_mode_agent_v1_security_review.md，技术设计只更新与实际实现不同的决策。运行 flutter analyze、git diff --check。报告所有发现及文件行号、修复、通过/失败/未检查项。不要以“测试通过”代替 Review，不要开始 Task 25，不要擅自提交。
```

#### Task 25 执行提示词

```text
你现在只执行 Stage 05 / Task 25：完成自动化测试、静态分析和 macOS debug 构建验证，并生成完整测试报告。除修复真实缺陷外不要新增功能。

先读取 AGENTS.md、Ponytail、Task 25 和前一安全审查报告。记录 git status 和环境版本。依次执行 dart format --output=none --set-exit-if-changed lib test、flutter analyze、git diff --check、flutter test test/work_mode、flutter test test/agentic test/web_search test/document、两个关键 lifecycle/recovery 测试、flutter test 全量、flutter build macos --debug。

某条失败时记录完整证据，并继续运行不依赖它的其他检查；集中列出全部失败后定位根因，用最小改动修复，再重跑相关项及最终核心套件。不得删测试、加 skip、放宽断言或把环境失败伪称通过。构建被本计划明确授权用于插件和 entitlement 验证。

把每条命令、开始/结束时间、退出码、通过/失败数量、修复和未检查原因写入 docs/verification/work_mode_agent_v1_test_report.md。最终运行 flutter analyze、flutter test、flutter build macos --debug 和 git diff --check 作为关闭门禁。报告自动化结论，但明确它不能替代 Task 26 的真实 UI 验收。不要开始 computer-use，不要擅自提交。
```

#### Task 26 执行提示词

```text
你现在只执行 Stage 05 / Task 26：使用 computer-use 对 macOS 真实 App 完成计划列出的 33 项逐项验收，并保留可复核证据。不得用 widget test 结果代替真实操作。

先读取 AGENTS.md、Ponytail、需求、Task 26 的完整 33 项清单和 Task 25 测试报告。启动 debug App，使用两个专门的临时目录和虚构测试数据，不接触用户真实项目文件；准备产品/开发/测试角色、两个群和两个私聊。每项操作前记录初始状态和输入，操作后记录可见 UI、任务事件、磁盘前后内容/哈希、截图绝对路径和 PASS/FAIL。

必须真实验证：一次多目录授权及重启保持、写入/强制高风险/补充审批、快照撤销与外部冲突、离页/隐藏继续和停止、三条追问 FIFO、原文件修订、关闭 App 后手动继续、2 并发+第三排队、文件锁、@/自动路由/接力、私聊隔离、命令和安装提示、软限制、文档/视觉、免 Key 搜索/可见浏览器/人工介入/链接追问、普通模式隔离。60 分钟用测试配置缩短，但必须证明同一状态机。

单项失败后继续所有不依赖项，一次性列全问题；修复真实缺陷后重跑失败项和核心 smoke，并保留首次失败记录。证据写入 docs/verification/work_mode_agent_v1_macos_walkthrough.md，截图放 docs/verification/evidence/work_mode_agent_v1。只有 33 项全部 PASS 才报告实机验收完成；任何未测项都明确标未完成。不要构建发布包，不要开始 Task 27，不要擅自提交。
```

#### Task 27 执行提示词

```text
你现在只执行 Stage 05 / Task 27：生成经过验证的 macOS Release .app 和本地 DMG，证明运行时是单 App，不依赖额外 daemon、数据库、容器或本地服务。

先读取 AGENTS.md、Ponytail、Task 27、Task 25/26 报告和 macOS 现有工程配置。只有 Task 26 的 33 项全部 PASS 才继续。创建 scripts/package_macos_dmg.sh，只使用 Flutter 和 macOS 自带 hdiutil；临时目录必须 mktemp -d + trap 精确清理，禁止 rm -rf 指向变量不明、HOME、仓库根或宽泛目录。

运行 flutter build macos --release，把 .app 与 Applications 链接放进临时 staging 后生成版本化 DMG。在干净测试用户环境安装并做首次启动、目录授权、读/写审批、面板、重启恢复和网络 smoke。检查运行进程/端口，确认没有 localhost bridge 和额外服务要求。扫描发布目录，确保不包含 data/api_configs.hive、开发 Hive、Bearer/API Key、测试证据、临时快照或用户路径。

记录 DMG 的 shasum -a 256、App/Flutter/macOS 版本、签名/公证状态和 Gatekeeper 限制到 release checklist。未签名/未公证必须如实说明。Windows 只报告代码/静态验证，不生成或宣称实机安装包。运行 flutter analyze、release smoke、git diff --check。最终报告 DMG 绝对路径、哈希、安装结果、单 App 证据和已知限制；不要擅自上传、发布或提交。
```

## 依赖和文件数量预算

Ponytail 要求限制实现扩张，实施中按以下预算审查：

- 新运行时依赖最多 2 个：`desktop_webview_window`（只有 spike 通过才保留）、`html`（只有直接 DOM import 时声明；它当前已是传递依赖）。
- 不新增本地服务、daemon、数据库、容器、Node/Python runtime。
- 不建立第二套模型客户端、第二套消息系统、第二套文档解析器、第二套搜索协调器。
- 新文件按职责创建，但若两个候选类合计仍小于约 250 行且生命周期一致，应合并；若单文件超过约 500 行，按“策略 / 执行 / UI / 存储”拆分。
- `AgentRuntime` 必须变小；如果总行数继续增长，视为 Ponytail 失败，停止 Stage 04 并先完成根因重构。

---

## 阶段门禁与允许继续的条件

每个 Stage 必须满足以下条件后才能进入下一 Stage：

1. 本 Stage 所有任务的目标测试 PASS。
2. `flutter analyze` PASS。
3. 规格追踪表中对应 FR 有测试或明确的下一阶段 UI 验收编号。
4. Review 已覆盖整个 Stage 改动集，不因发现第一个问题而提前结束。
5. 无未解释依赖、占位符、两套 owner、静默 fallback 或安全绕过。
6. 用户现有未提交改动保持不变，或任何必要重叠已单独说明并获得确认。

若某项客观阻塞，停止在阶段边界，说明：阻塞证据、已完成项、未验证项、可选解决方式；不得自行扩大权限或安装额外服务。

---

## 最终完成定义

只有同时满足以下条件才可说“工作模式 AI Agent V1 已完成”：

- 需求文档 FR-01 至 FR-09 全部逐条对照通过。
- App 级多目录授权、写入审批、强制高风险确认、快照和撤销均有自动化和 macOS 实机证据。
- 连续追问、原文件修订、重启手动继续、多角色路由/接力和全局并发/文件锁均通过。
- 流式执行面板只展示公开动作/状态/输出/结论，不泄露私有推理或凭据。
- 搜索优先级和可见浏览器升级真实可用；任何降级在 UI 和报告中如实说明。
- 普通聊天、自动聊天、主动私聊回归通过。
- `flutter analyze`、目标测试、全量测试、macOS debug/release build 全通过。
- computer-use 的 33 项 macOS walkthrough 全部有证据。
- 本地 DMG 可安装，单 App 运行，不依赖额外服务；签名/公证状态如实披露。
- Windows 仅报告代码/静态验证范围，不冒充实机验收。
