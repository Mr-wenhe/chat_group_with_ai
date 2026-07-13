# `chat_room_page.dart` 重构、封装与模块化审核建议

> 审核对象：`lib/features/chat_group/chat_room_page.dart`
> 审核日期：2026-07-13
> 审核方式：静态结构审查 + 现有架构对照 + `flutter analyze`
> 当前分析结果：`flutter analyze lib/features/chat_group/chat_room_page.dart` 通过，无静态分析错误

## 1. 结论摘要

`chat_room_page.dart` 目前不是单纯的“聊天页面”，而是同时承担了页面、会话状态机、消息编排器、LLM 回复引擎、Agent 工具协调器、记忆持久化服务、附件服务和多组 UI 组件的职责。

建议重构，但不建议一次性重写或直接把所有逻辑迁移到 Riverpod。最稳妥的路线是：

1. 先冻结行为并补齐关键路径测试。
2. 先抽取纯函数和纯展示组件，降低文件体积，保持行为不变。
3. 再把加载、回合编排、回复生成、Agent 执行、记忆更新拆成独立协调器。
4. 最后再评估是否将页面状态迁移为按 `conversationId` 派生的 Riverpod controller。

第一阶段目标不是“把 6,640 行平均分到几个文件”，而是建立清晰的依赖边界：

```text
Widget/UI  →  ChatRoomController  →  ChatRoomCoordinator
                                      ├─ ChatReplyService
                                      ├─ AgenticConversationCoordinator
                                      ├─ ChatMemoryCoordinator
                                      ├─ ChatPromptFactory
                                      └─ ChatRoomRepository / DatabaseService
```

## 2. 当前规模与结构画像

| 指标 | 当前情况 | 影响 |
|---|---:|---|
| 文件行数 | 6,640 行 | 阅读、定位和安全修改成本高 |
| import 数量 | 75 个 | UI、数据库、网络、文件系统和 Agent 依赖混在一起 |
| 文件内 class 数量 | 10 个 | 页面、消息气泡、视频播放器、光标动画和内部模型共存 |
| `ConsumerState` 状态字段 | 约 40 个 | 一个状态对象同时驱动多个相互独立的子系统 |
| 主要方法 | 100 个以上 | 页面生命周期、领域逻辑、异步流程和 UI builder 没有边界 |
| 主要异步资源 | Timer、StreamSubscription、Completer、TTS、视频控制器、文件 IO | 生命周期和并发行为难以单独验证 |

### 2.1 当前职责分布

| 代码范围 | 当前职责 | 建议归属 |
|---|---|---|
| 78–320 | 提及解析、Agent 选角、重复回复判断、非 Agent 文件恢复 | `chat_room_utils.dart`、`agentic_reply_utils.dart`，保持纯函数 |
| 334–508 | 页面字段、控制器、服务初始化、生命周期清理 | `ChatRoomController` + 页面只保留 Widget 生命周期 |
| 509–675 | 群聊/私聊加载、记忆读取、已读状态、自动聊天启动 | `ChatRoomLoader` / `ChatRoomRepository` |
| 677–751 | Agent 任务恢复和审批恢复 | `AgentTaskRecoveryCoordinator` |
| 753–879 | 空闲自动聊天 Timer、选角、回合执行 | `AutoChatCoordinator` |
| 923–1163 | 发送消息、自治任务授权、自治任务执行 | `ChatSendCoordinator` + `AutonomousTaskCoordinator` |
| 1177–1324 | 普通 AI 回合编排、排队消息、失败占位 | `ChatRoundCoordinator` |
| 1326–1729 | 流式回复、重试、SSE 收尾、附件恢复、落库、token 记录 | `ChatReplyService` + `StreamingReplySession` |
| 1731–2519 | Agent Runtime、工具执行、审批、进度消息、技能保存/下载 | `AgenticConversationCoordinator` |
| 2520–2948 | 关系更新、API message 构建、群聊/私聊 prompt | `ChatPromptFactory` + `RelationshipCoordinator` |
| 2964–3287 | 消息持久化、@我提示、群记忆、角色记忆、回复资格、token 使用 | `ChatMessageRepository` + `ChatMemoryCoordinator` + `ReplyEligibilityPolicy` |
| 3298–4124 | @弹窗、上下文压缩、流式滚动、自动聊天控制、搜索、TTS | 各自的 controller/service + 子 Widget |
| 4163–4475 | 消息操作菜单、TTS、重新生成、引用回复 | `MessageActionSheet` + `MessageInteractionController` |
| 4496–5290 | 页面 Scaffold、AppBar、消息列表、横幅、成员面板 | `ChatRoomScaffold`、`ChatMessageList`、`ChatRoomHeader`、`MemberSheet` |
| 5290–6040 | 输入框、附件选择、拖放、剪贴板、预览、引用条 | `ChatComposer` + `AttachmentPicker` + `AttachmentPreviewStrip` |
| 6103–6529 | 消息气泡、引用、媒体、文件打开、内容渲染 | `ChatMessageBubble`、`MessageMediaContent`、`AttachmentCard` |
| 6536–6640 | 视频播放器和闪烁光标 | 独立 Widget 文件 |

## 3. 主要问题与优先级

### P0：页面状态对象承担了多个领域的状态机

`_ChatRoomPageState` 同时持有：

- 会话数据：群、角色、消息、群记忆、角色记忆、关系状态；
- 生成状态：普通回复、流式回复、Agent 运行、重试、停止生成；
- 自动聊天状态：Timer、轮数、暂停/恢复、直接聊天上限；
- 输入状态：@弹窗、引用、附件、拖放、剪贴板、桌面键盘；
- 交互状态：搜索、TTS、@我提醒、成员面板；
- 资源状态：数据库、网络服务、TTS、视频和文件系统。

这会导致一个局部改动触发整页 rebuild，也使得“消息生成是否完成”“页面是否仍可更新”“附件是否需要删除”这类问题互相耦合。

建议优先建立 `ChatRoomSnapshot` 和若干独立状态片段，而不是继续增加字段：

```dart
class ChatRoomSnapshot {
  final ChatRoomSession session;
  final List<Message> messages;
  final ReplyState reply;
  final AutoChatState autoChat;
  final ComposerState composer;
  final SearchState search;
  final MentionState mentions;
}
```

流式消息属于高频变化状态，建议单独维护 `StreamingReplyState`，不要和整个会话快照一起刷新。

### P0：UI、领域逻辑和副作用没有隔离

例如 `_generateAiReply`（1326–1628）同时完成：

1. 解析 API 配置和 provider；
2. 压缩上下文；
3. 判断是否进入 Agentic；
4. 构建 prompt；
5. 订阅 SSE；
6. 更新流式临时消息；
7. 处理重试和空回复兜底；
8. 清理协议泄漏；
9. 生成附件；
10. 落库、更新索引、标记已读、统计 token、更新关系和记忆。

这个方法应拆成“返回结果的服务”和“页面状态适配器”：

```text
ChatReplyService
  ├─ build request
  ├─ call ChatApiService
  ├─ return ReplyStream / ReplyResult
  └─ never call setState or Navigator

ChatRoomController
  ├─ subscribe to ReplyStream
  ├─ update streaming state
  ├─ ask MessageRepository to persist
  └─ expose UI-safe status
```

### P0：异步生命周期和重入路径过于集中

页面目前通过 `_disposed`、重写 `setState`、`_streamSub`、`_streamDone`、多个 Timer 共同防止页面销毁后的回调写 UI。这些保护是必要的，但它们分散在页面中，未来很容易新增遗漏。

重点风险：

- `_startAutoChat` 和 `Future.delayed` 的回调需要手动检查页面生命周期；
- 用户消息在 AI 回复期间进入 `_pendingUserMessages`，随后递归调用 `_runAiRound`；
- 流式订阅、停止生成、页面销毁存在多个收尾路径；
- Agent 恢复、审批、普通回复和自动聊天可能同时竞争同一角色；
- `_agenticRunningCharacterIds` 是页面级并发锁，容易被新入口绕过。

建议统一引入 `ConversationRunId` 或取消令牌：每次开始加载/生成时生成 run id，所有异步回调在提交 UI 或持久化前验证 run id。自动聊天 Timer、流式订阅和 Agent 任务应由各自协调器持有并负责 dispose。

### P1：群聊和私聊加载流程重复

`_loadData`（509–608）与 `_loadDirectChatData`（610–675）分别完成角色解析、消息读取、已读标记、记忆读取、自治配置加载、状态设置和自动聊天启动。两者只有会话来源和群记忆策略不同。

建议先抽出共享的 `ChatRoomLoadContext`：

```dart
class ChatRoomLoadContext {
  final ChatGroup displayGroup;
  final List<AICharacter> activeCharacters;
  final List<AICharacter> allCharacters;
  final List<Message> messages;
  final List<CharacterMemory> characterMemories;
  final List<RelationshipState> relationships;
  final AutonomousConversationConfig autonomousConfig;
  final GroupMemory? groupMemory;
}
```

`ChatRoomLoader.load(conversationId)` 内部判断群聊/私聊，页面只接收一次结果并更新状态。

### P1：存在重复工具和重复编排逻辑

已确认的重复点：

- `chat_room_page.dart:6042–6071` 存在顶层 `_fileIconFor`、`_fileNameFromPath`、`_extensionOfPath`；
- `chat_room_page.dart:6461–6494` 在 `_ChatRoomPageState` 中再次实现文件图标、文件名和大小处理；
- `ChatOrchestrator.extractRecentFocus` 已存在，但页面仍在 `2933–2943` 实现 `_extractRecentFocus`；
- `ChatOrchestrator` 已提供回复资格、阻断原因和回复计数相关能力，但页面在 `3202–3271` 仍保留一套近似实现；
- `chat_room_page.dart:509–675` 对群聊和私聊进行近似的加载和状态赋值。

建议先归一化工具入口，再做大规模逻辑迁移。重复实现如果继续保留，会导致一个路径修复后另一个路径仍有旧行为。

### P1：流式输出会触发整页重建

`_flushStreamingUi`（3903–3919）会更新 `_messages`，而页面 `build`（4496–4709）同时重建 AppBar、横幅、消息列表、生成状态和输入区。流式输出按约 80ms 刷新时，消息列表之外的大量 UI 也会被反复构建。

建议：

- 将消息列表提取为独立的 `ChatMessageList`；
- 将流式消息状态用 `ValueNotifier`、独立 Riverpod provider 或局部 `StatefulWidget` 承载；
- AppBar、控制条和输入区只依赖它们自己的状态；
- `GlobalKey` 清理和列表数据整理移到状态变化处，避免在 `build` 内执行 `_messageKeys.removeWhere`（4503）。

### P1：调试日志可能记录敏感对话内容

`_generateAiReply` 在 1398–1407 输出 API message 数量和每条 content 的前 60 个字符。虽然没有直接打印 API Key，但这些内容可能包含用户隐私、附件路径、项目代码或系统提示词。

建议：

- 默认生产构建关闭 prompt 内容日志；
- 日志只保留 request id、角色 id、消息数量、token 统计和错误类型；
- 必须调试 prompt 时使用显式 debug flag，并统一脱敏；
- 不在普通日志中输出附件路径和完整工具参数。

### P2：页面中的类型和派生状态仍可收紧

- `_pendingUserMessages` 声明为 `List<dynamic>`（366），应改为 `List<_PendingUserMessage>`，最好提升为公开的 feature 内部模型；
- `_isInputEmpty` 既由 controller listener 更新（454–459），又会在文本变更路径中参与判断，属于可派生状态；
- `_isAiReplying`、`_isStreaming`、`_streamingMessage` 三个字段的状态关系应集中为 `ReplyState`，避免出现组合不一致；
- `Map<String, dynamic>` 用于工具结果、API message 和待处理审批，边界处应增加结果模型或最小化动态字典范围。

## 4. 建议的目标目录

建议保留现有 `features/chat_group` 作为边界，先不引入跨 feature 的“大而全”工具目录：

```text
lib/features/chat_group/
├── chat_room_page.dart                         # 页面组装，目标 < 400 行
├── chat_room_controller.dart                   # 页面可观察状态与用户意图入口
├── chat_room_state.dart                        # ChatRoomSnapshot / 子状态模型
├── chat_room_loader.dart                       # 群聊/私聊统一加载
├── chat_room_repository.dart                   # 消息、已读、记忆、统计的持久化门面
├── chat_round_coordinator.dart                 # 用户回合与消息队列
├── auto_chat_coordinator.dart                  # idle auto-chat Timer 与策略
├── chat_reply_service.dart                     # 普通回复、流式回复、重试结果
├── agentic_conversation_coordinator.dart       # AgentRuntime 入口、审批、恢复
├── chat_prompt_factory.dart                    # 群聊/私聊 API messages
├── chat_memory_coordinator.dart                # 群记忆、角色记忆、关系持久化
├── reply_eligibility_policy.dart               # 回复资格与阻断原因
├── chat_room_utils.dart                        # mention、重复回复、文件纯函数
├── widgets/
│   ├── chat_room_app_bar.dart
│   ├── chat_room_banners.dart
│   ├── chat_message_list.dart
│   ├── chat_message_bubble.dart
│   ├── message_media_content.dart
│   ├── chat_room_composer.dart
│   ├── attachment_preview_strip.dart
│   ├── member_sheet.dart
│   ├── message_action_sheet.dart
│   ├── video_bubble.dart
│   └── blinking_cursor.dart
└── models/
    ├── chat_room_load_context.dart
    ├── chat_room_reply_state.dart
    └── pending_user_message.dart
```

### 4.1 页面保留什么

最终的 `ChatRoomPage` 只负责：

- 从 route 接收 `groupId`；
- 创建或读取 controller；
- 监听生命周期并通知 controller；
- 根据 controller state 组装 `Scaffold`；
- 将 UI 回调转成 `sendMessage`、`stopReply`、`quoteMessage` 等明确意图。

页面不应再直接调用：

- `ChatApiService.streamChatMessage`；
- `AgentRuntime.run`；
- `DatabaseService` 的多个 Hive box；
- `FilePicker`、`Pasteboard`、`OpenFilex`；
- 群记忆摘要生成和关系更新。

## 5. 推荐的模块边界

### 5.1 `ChatRoomLoader`

输入 `conversationId` 和数据库门面，输出不可变的 `ChatRoomLoadContext`。它负责：

- 识别群聊或私聊；
- 解析 active/all characters；
- 读取消息和已读状态；
- 读取或迁移旧版群记忆 key；
- 读取角色记忆、关系状态和自治配置；
- 返回可直接渲染的 display group。

它不负责启动 Timer、不弹 Dialog、不调用 `setState`。

### 5.2 `ChatRoundCoordinator`

负责一次“用户消息 → 选择角色 → 依次回复 → 清理队列”的流程。建议接口类似：

```dart
Future<RoundResult> runUserRound({
  required String userMessage,
  required List<String> mentionedIds,
  Message? currentUserMessage,
});
```

它依赖 `ReplyEligibilityPolicy`、`HumanizedChatOrchestrator` 和 `ChatReplyService`，不依赖 Flutter `BuildContext`。需要 Toast 或导航时返回结构化的 `RoundBlockReason`，由 controller/page 处理。

### 5.3 `ChatReplyService`

把当前 `_generateAiReply` 拆成几个明确结果：

```dart
Stream<ReplyEvent> streamReply(ReplyRequest request);
Future<ReplyResult> finishReply(ReplyAccumulator accumulator);
```

建议 `ReplyEvent` 至少覆盖：`started`、`token`、`done`、`error`、`stopped`。`ReplyResult` 携带最终文本、失败状态、token 使用量、提及角色和附件，不直接操作页面消息列表。

### 5.4 `AgenticConversationCoordinator`

目前 1731–2519 的 Agent 逻辑已经足够形成独立模块，建议整体迁移，而不是继续在页面中逐个抽 helper。其职责包括：

- 从用户请求创建/恢复 `AgentTask`；
- 解析和执行工具请求；
- 管理审批状态；
- 写入 Agent 进度消息；
- 处理技能创建/下载；
- 从工具结果生成附件；
- 返回 `AgenticReplyResult`。

审批 Dialog 可以通过 callback 注入：

```dart
typedef ApprovalHandler = Future<bool?> Function(ToolRequest request);
```

这样协调器可以在 widget test 和纯 Dart test 中运行，不需要直接持有 `BuildContext`。

### 5.5 `ChatPromptFactory`

将 `_buildApiMessages`、`_buildDirectApiMessages`、`_collaborationPromptFor`、`_extractRecentFocus` 迁移为纯输入/输出对象。它只依赖一个明确的 `PromptContext`，不要直接读取页面字段。

特别建议把以下内容从大字符串拼接中拆成策略函数：

- 角色记忆；
- 群记忆；
- 场景 prompt；
- 协作分工 prompt；
- 当前任务 prompt；
- 历史消息映射；
- 多模态用户消息。

这样可以分别测试“私聊不会出现群聊 prompt”“多模态 provider 不支持视觉时的降级”“当前用户消息不重复注入”等边界。

### 5.6 UI 组件边界

建议优先抽取以下四块，因为它们对领域逻辑依赖较少：

1. `ChatMessageBubble`：消息头像、引用、文本、媒体、已读状态和长按操作；
2. `ChatMessageList`：时间分隔、消息 key、滚动和消息定位；
3. `ChatRoomComposer`：输入框、@、引用、附件预览、发送和停止；
4. `MemberSheet`：成员搜索、状态展示、进入私聊和角色设置。

组件通过 data/callback 通信，不把 `ConsumerState` 传给子组件。例如：

```dart
ChatRoomComposer(
  textController: controller.textController,
  focusNode: controller.inputFocusNode,
  quotedMessage: state.composer.quotedMessage,
  attachments: state.composer.attachments,
  onSend: controller.sendMessage,
  onQuoteCancel: controller.cancelQuote,
  onPickAttachment: controller.pickAttachment,
)
```

## 6. 分阶段实施计划

### Phase 0：建立行为基线

不改生产逻辑，补充或确认以下测试：

- 用户消息发送、AI 回复队列、最大回合数；
- 自动聊天暂停条件、私聊连续 AI 回复上限；
- 流式 token、停止生成、错误重试和空回复兜底；
- 群聊/私聊加载结果一致性；
- Agent 审批、拒绝、恢复和重复执行防护；
- 引用消息、@角色、@我提醒、搜索和已读；
- 图片/视频/文件选择、拖放、粘贴和未发送附件清理。

现有测试已经覆盖 SSE、Agent、mention、编排器、语音和附件等多个纯逻辑点，但 UI-heavy 的 chat room 行为仍偏少。重构前应先为高风险路径增加行为测试，而不是先改目录。

### Phase 1：纯函数和模型抽取

建议先做一个低风险 PR：

- `parseMentionedCharacterIds`、`isDuplicateAiReply` 移至 `chat_room_utils.dart`；
- `inferRecoverableFilePath`、`extractRecoverableFileContent`、`_sanitizeNonAgenticReply` 移至 `agentic_reply_utils.dart`；
- 文件扩展名、文件名、文件图标和大小格式化统一到 `attachment_utils.dart`；
- `_PendingUserMessage`、`_PendingAgentToolApproval` 移至 `models/`；
- 删除重复实现，并让现有测试改为直接测试新模块。

验收标准：功能行为不变、`flutter analyze` 通过、现有纯逻辑测试全部通过。

### Phase 2：展示组件抽取

按以下顺序拆出：

1. `BlinkingCursor`、`VideoBubble`；
2. `ChatMessageBubble` 与媒体内容；
3. `ChatMessageList`；
4. `ChatRoomComposer` 与附件预览；
5. `MemberSheet`、AppBar 和横幅。

每次只迁移一块 UI，并保留原 callback。完成后页面应缩减到约 3,000 行以内，但业务行为仍由页面状态驱动。

### Phase 3：加载和持久化门面

引入 `ChatRoomLoader` 与 `ChatRoomRepository`，先处理 `_loadData` / `_loadDirectChatData` 的重复，再迁移 `_appendMessage`、已读、token、回复计数和记忆读取。

验收重点：

- 群聊和私聊继续使用相同的 `Message.groupId` 约定；
- 不改变旧版群记忆 key 迁移；
- 不把 API Key 放进新的状态快照、日志或 UI model；
- 页面 dispose 后，后台已提交的流式收尾仍按当前产品约定落库。

### Phase 4：回复和 Agent 协调器

先抽 `ChatPromptFactory`，再抽 `ChatReplyService`，最后整体迁移 Agent Runtime 协调逻辑。顺序不能反过来：如果先抽 `_generateAiReply`，prompt、Agent、落库和 UI 回调仍会全部纠缠在新 service 里。

建议将普通回复与 Agent 回复统一为：

```text
ChatRoundCoordinator
  ├─ ReplyMode.normal  → ChatReplyService
  └─ ReplyMode.agentic → AgenticConversationCoordinator
```

两个分支都返回统一的 `ReplyResult`，由同一个持久化入口写入消息、token、提及和附件。

### Phase 5：状态迁移（可选）

当前四个阶段稳定后，再考虑 Riverpod：

- `chatRoomControllerProvider(conversationId)` 管理会话状态；
- `chatRoomMessagesProvider` 单独负责消息列表；
- `chatRoomReplyProvider` 单独负责流式状态；
- `chatRoomComposerProvider` 管理输入和附件；
- 页面通过 `select` 只监听自己需要的字段。

不建议在 Phase 1 直接做 Riverpod 全量迁移，因为这会把“架构重构”和“状态管理迁移”叠加为一个不可回滚的大变更。

## 7. 建议的第一批 PR 切分

### PR 1：纯工具和类型收敛

- 抽取 mention、重复回复、文件恢复和附件工具；
- `List<dynamic>` 改为强类型；
- 删除重复文件工具；
- 只移动代码，不改变行为。

### PR 2：消息展示组件

- 抽取 `ChatMessageBubble`、媒体渲染、视频播放器、闪烁光标；
- 增加消息气泡 widget test；
- 验证引用、附件、流式光标、长按菜单。

### PR 3：输入区组件

- 抽取 composer、附件预览和 quote bar；
- 将选择文件、拖放和粘贴封装为 `AttachmentPicker`；
- 保持 controller 作为 callback owner。

### PR 4：消息列表和顶部区域

- 抽取 `ChatMessageList`、AppBar、成员面板和 banner；
- 把滚动定位和 `GlobalKey` 管理移到列表 controller；
- 观察流式输出时的 rebuild 范围。

### PR 5：加载与回复服务

- 抽取 loader、repository、prompt factory；
- 再拆普通回复和 Agent 回复；
- 每个 PR 都保持可运行、可测试和可回滚。

## 8. 测试与验收清单

### 纯 Dart 测试

- mention 解析：中文名、重复 @、@all、未知名、标点边界；
- 回复资格：停用、无 API、小时上限、跨小时重置；
- 自动聊天策略：生成中、输入框非空、连续回复上限、burst pause；
- prompt factory：群聊、私聊、场景模式、记忆、关系、附件和视觉能力；
- reply service：token 累积、done/error、空内容、重复内容、停止；
- Agent coordinator：审批、拒绝、恢复、超时、工具重复执行防护；
- attachment utils：扩展名、文件类型、Web 大小上限、路径安全。

### Widget 测试

- 消息气泡：用户/AI、头像、引用、媒体、已读和流式光标；
- 输入区：文本为空时不可发送，有附件时可发送；
- @弹窗：过滤、键盘选择、插入文本、关闭；
- 成员 sheet：搜索、状态、私聊和角色设置回调；
- 页面加载态、无消息态、API warning、公告和 @我提醒。

### 手工回归

- 群聊普通消息、多角色接力和自动聊天；
- 私聊首次发送、主动联系和连续回复限制；
- 流式生成中停止、离开页面后重新进入；
- Agent 文件生成、审批拒绝、任务恢复和附件点击打开；
- 桌面端 Enter/Shift+Enter、拖放、剪贴板粘贴；
- Web 端 data URI、附件大小限制和视频降级。

## 9. 重构完成标准

- `chat_room_page.dart` 只保留页面组装和少量 UI 意图转发，目标不超过 400–600 行；
- 页面不直接持有数据库 box、LLM API、Agent Runtime、文件选择器和 TTS 业务流程；
- 普通回复、Agent 回复、自动聊天、记忆更新均可在无 `BuildContext` 的测试中执行；
- 流式 token 更新只刷新消息区域，不重建整个 Scaffold；
- 群聊/私聊加载只有一个共享加载入口；
- 文件工具、回复资格、prompt 焦点等不再有重复实现；
- 所有异步协调器都有明确的取消/销毁策略；
- 生产日志不输出 prompt 内容、附件路径和工具敏感参数；
- 运行 `flutter analyze`、相关单测和关键 widget test 全部通过。

## 10. 最终建议

最值得立即做的是“组件抽取 + 协调器边界建立”，而不是马上重写整个页面。推荐先完成 PR 1–3，再根据流式性能和测试收益决定是否推进 Riverpod 状态迁移。

如果只能安排一次重构迭代，建议优先级如下：

1. 抽取 `ChatMessageBubble`、`ChatMessageList`、`ChatRoomComposer`；
2. 统一附件和文件工具，删除重复实现；
3. 把 `_generateAiReply` 拆为 `ChatReplyService`；
4. 把 `_loadData` 与 `_loadDirectChatData` 合并为 `ChatRoomLoader`；
5. 为流式生成和 Agent 审批补齐行为测试。

这样可以先显著降低文件复杂度和 rebuild 范围，同时保持现有功能与数据约定稳定，为后续业务逻辑服务化留下清晰入口。
