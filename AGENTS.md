# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Commands

- `flutter run` — run the app on a connected device/emulator
- `flutter analyze` — lint and static analysis
- `flutter test` — run all tests
- `flutter test test/widget_test.dart` — run a single test file
- `dart run build_runner build` — generate code (Hive adapters, Riverpod providers, JSON serialization)
- `flutter pub get` — install dependencies

## Architecture

**AI Group Chat Simulator** — a Flutter app that simulates group conversations between AI characters backed by multiple LLM providers (DeepSeek, Qwen, Zhipu, Moonshot, Baidu, or custom OpenAI-compatible endpoints).

### Key Data Model

- `ApiConfig` — shared API key/URL/model config (1:many with characters)
- `AICharacter` — persona with system prompt, avatar, reply rate limits, and compact memory summary
- `ChatGroup` — a group of characters with a theme and owner name; messages belong to a group
- `Message` — user or AI messages with mention and quote-reply support
- `GroupMemory` — weekly-summarized topic memory per group, auto-updated after each AI round
- `CharacterMemory` / `RelationshipState` — layered per-character group memory and directional relationship state
- Direct chat sessions reuse `Message.groupId` with stable conversation keys `dm:{characterId}`. Lightweight inbox state (`readAt`, source, last proactive timestamp) is stored in Hive `app_settings`, not new Hive model classes.

### Flow

1. User creates AI characters and groups them into `ChatGroup`s.
2. In `ChatRoomPage`, user sends a message → triggers `_runAiRound` which randomly picks 1-2 eligible AI characters to reply in sequence (max 3 auto rounds). In addition, ~3s after entering a room the app starts an **idle auto-chat loop** (`_startAutoChat`): every 5-9s it randomly triggers 0-2 eligible characters to speak; a single burst runs at most 5 rounds, then pauses 10s and resumes.
3. Each reply calls `ChatApiService.streamChatMessage` when streaming is enabled, or `sendChatMessage` for non-streaming calls, using the character's `ApiConfig`.
4. After each round, if there are ≥8 messages, a summary is generated and stored as `GroupMemory` (keyed by year_week).
5. Each character has hourly reply limits tracked on the model itself.
6. Direct chats appear in `DirectChatListPage` (`/direct-chats`). App foreground proactive contact is coordinated by `DirectChatForegroundWatcher` + `DirectChatProactiveService`: stale existing DMs are preferred, but active group members can also start first-time DMs from recent group context. Fully offline AI generation still requires either pre-generated local notifications or a future server push service.

### Tech Stack

- **State**: Riverpod (annotation-based, code-generated providers)
- **Storage**: Hive local NoSQL database with type-safe adapters
- **Networking**: Dio for HTTP calls to LLM APIs
- **Serialization**: json_annotation / json_serializable for model JSON

### Code Generation

All `.g.dart` files are generated. After modifying any model class (HiveType/HiveField) or adding Riverpod providers, run:
```
dart run build_runner build
```

### Provider Pattern

All providers live under `lib/features/*/providers/` and are re-exported via `lib/providers/providers.dart`. The only top-level provider is `databaseServiceProvider` wrapping `DatabaseService`.

### Routes

| Route | Page | Purpose |
|-------|------|---------|
| `/` | `AICharacterListPage` | Manage AI characters |
| `/groups` | `ChatGroupListPage` | Manage groups |
| `/direct-chats` | `DirectChatListPage` | Private chat inbox, unread reminders, manual proactive check |
| `/chat/{groupId}` | `ChatRoomPage` | Active group conversation |
| `/dm/{characterId}` | `ChatRoomPage` | One-on-one private chat using `dm:{characterId}` as message groupId |
| `/settings` | `SettingsPage` | API configs, data management |

### Important Caveats

- `AICharacter` tracks hourly reply counts via `lastReplyTimestamp` and `hourlyReplyCount` directly on the model — these are mutated in `_isEligibleToReply` without re-saving to DB each time, only the limit check is enforced during a round.
- Non-release runs read Hive directly from the repository `data/` directory, including API keys stored inside `api_configs.hive`.
- Release builds read/write Hive under the user's app support directory and create fresh empty `*.hive` files there on first launch.
- The `custom` provider requires a manual `baseUrl` input; all others have hardcoded base URLs in `ApiProvider`.
- Local `data/*.hive` files are intentionally versioned as development-only data.
- Foreground proactive DMs may call configured LLM APIs while the app is running. Keep cooldowns conservative and never trigger background/offline network generation without an explicit notification/push design.
- **API Key 连接测试红线**：用户在配置表单中新输入的 Key 必须直接用于本次测试，禁止为测试先临时写入/回读/删除 Keychain/Keystore；只有编辑已有配置且 Key 输入留空时，才通过 `ApiCredentialResolver` 读取已保存凭据。持久化仅能由正式保存流程执行。
- **macOS Debug 凭据兼容**：非 release 运行时 Keychain 可能因 ad-hoc 签名不可用；安全写入失败后可仅在非 release 保留 `legacyApiKey`，并以 `hasCredential=true` 且 `credentialId=CredentialRepository.developmentHiveCredentialId` 作为开发回退标记。`ApiCredentialResolver` 与删除流程必须识别该标记；Release 严禁读取或写入 Hive 明文 Key。
- **工作模式连续修改红线**：恢复中的工作任务必须占用会话控制器，新输入只能排队并在旧任务结束后派发，禁止取消旧任务后静默丢弃新请求。中英文“修改同一/相同/当前/上次文件”等明确修订请求必须覆盖原附件路径；只有新建请求发生重名时才允许自动改名。流式通道返回空内容时可对同一请求回退一次非流式调用；标准 `content` 为空时才允许读取兼容字段 `reasoning_content`，两者均为空必须报错。源码附件的本地兜底必须有对应语言的可运行模板，否则应明确失败，禁止把说明文本伪装成 `.py/.js/.ts` 等代码附件。
- **Dependency overrides 策略**：本项目使用 Flutter 3.24 fork，不支持 `android.flutter` 属性（3.27+ API）。以下包的新版会触发 Android 构建失败，已通过 `dependency_overrides` 锁定：`file_picker`（≥8.0.0 <9.0.0）、`package_info_plus`（≥8.0.0 <9.0.0）、`wakelock_plus`（≥1.0.0 <1.4.0）。新增依赖前需验证 Android build.gradle 是否使用了 `android.flutter`。

### 代码质量检查清单

每个功能/需求开发完成后，提交前必须逐项检查以下维度：

1. **代码 Review** — 自检逻辑是否正确、边界是否覆盖；复杂逻辑优先写成单测
2. **注释** — 非自解释代码需有注释（说明 *why*，不是 *what*）；公共 API / 复杂算法必须有注释
3. **命名** — 变量、函数、类名见名知意；避免 `tmp`、`data`、`handle` 等无意义命名
4. **硬编码** — 魔法数字、字符串常量、URL 必须抽成常量或配置；禁止在业务逻辑中写死值
5. **函数拆分** — 单函数不超过 ~50 行；职责单一，一个函数只做一件事；过长的 `build` 方法需拆 widget
6. **函数封装** — 可复用的逻辑封装成独立方法/工具类；禁止在同一文件内复制粘贴相似代码块
7. **文件解耦** — 单个文件不超过 ~500 行；关注点分离，widget / 逻辑 / 数据层各司其职
8. **模块化** — 同领域逻辑归入同一 feature 目录；跨 feature 通信走 provider，禁止循环依赖
9. **性能问题** — 避免列表内不必要的 `setState` / rebuild；大列表用 `ListView.builder`；Stream 监听及时 dispose
10. **新老兼容** — 修改 public API 或数据模型时，检查是否影响旧数据迁移、Hive 字段版本、现有调用方

## Extensible Features (Roadmap)

> Ideas derived from analyzing the current codebase, ordered by fun/value vs. effort. Pick a few per iteration.

### High priority — implemented

- ✅ **Explicit work mode.** Per-conversation work mode routes every non-empty user instruction through `AgentRuntime` — local file generation, skill creation/download, workspace/browser tools, with a 12-step budget and 120s per-completion timeout. Normal and auto chat never enter the tool runtime; sensitive tools require explicit approval.
- ✅ **Media attachments (v1.3.2).** Chat input bar has an attachment button; supports images and documents via `file_picker`. Desktop drag-and-drop via `desktop_drop`.
- ✅ **Presence-aware proactive notifications (v1.3.2).** `ConversationPresenceService` tracks active conversation; suppresses notifications and auto-marks-read when user is viewing the target conversation.
- ✅ **Streaming / typewriter replies.** `ChatApiService.streamChatMessage` reads SSE and `ChatRoomPage` renders tokens incrementally with a blinking cursor + "停止生成" button.
- ✅ **Character persona presets / template library.** 10 built-in presets in `CharacterPreset.presets`; one-tap apply from the form dialog and a FAB on the list page (still requires choosing an ApiConfig).
- ✅ **Conversation export / share.** `ConversationExportService` exports Markdown/JSON to `chat_group_exports/` and shares via `share_plus`; entries on Settings page and chat-room AppBar. Export only reads display fields — never apiKey/apiProvider/apiConfigId.
- ✅ **Humanized chat engine.** Intent selection uses mentions, recent speakers, relationship state, topic fit, and character memory.

### Medium priority — implemented

- ✅ **Regenerate / stop reply.** Streaming replies can be stopped, and long-pressing an AI message can regenerate it with the existing context.
- ✅ **Quote-reply UI.** `Message.replyToMessageId` is set from long-press quote actions and rendered as a quoted snippet in message bubbles.
- ✅ **Scenario / scripted modes.** Group theme keywords inject debate / roast / board-meeting style prompts.
- ✅ **Per-character long-term memory.** `AICharacter.memorySummary` and layered `CharacterMemory` are injected into dialogue context.

### Low priority — polish / enhancement

- ✅ **Token tracking.** SSE usage is parsed and accumulated per character/group in Settings.
- ✅ **Light/dark theme toggle.** Settings exposes light / dark / system theme.
- ✅ **Voice playback (TTS).** AI messages can be spoken aloud; Settings includes a TTS toggle.
- ✅ **Private chat inbox + foreground proactive contact.** `/direct-chats` lists private histories with unread counts; private chats use `dm:{characterId}`; foreground watcher can create proactive DMs from stale private chats or recent group context.
- **Cost estimation.** Token usage exists, but provider/model-specific price calculation is not implemented.
- **Chat history search.**
- **Import / restore flow.** Export exists, but importing characters/groups/conversations is not yet available.
- **Offline proactive contact.** Fully closed-app AI generation needs pre-generated local notifications or a server-side push service; current implementation is foreground/local only.

### Known limitations (current implementation)

- Import for characters/groups/conversations not yet available — only export (added 2026-07-07); data is local-only and easy to lose.
- Test coverage covers SSE parsing, presets, export safety, mention parsing, activity policy, chat orchestration, and humanized memory/prompt logic. UI-heavy chat room behavior still relies mostly on extracted logic tests.
- Versioned `data/*.hive` may contain live API keys and chat data, so repository access should be treated as sensitive.
