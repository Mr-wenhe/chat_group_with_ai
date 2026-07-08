# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

### Flow

1. User creates AI characters and groups them into `ChatGroup`s.
2. In `ChatRoomPage`, user sends a message → triggers `_runAiRound` which randomly picks 1-2 eligible AI characters to reply in sequence (max 3 auto rounds). In addition, ~3s after entering a room the app starts an **idle auto-chat loop** (`_startAutoChat`): every 5-9s it randomly triggers 0-2 eligible characters to speak; a single burst runs at most 5 rounds, then pauses 10s and resumes.
3. Each reply calls `ChatApiService.streamChatMessage` when streaming is enabled, or `sendChatMessage` for non-streaming calls, using the character's `ApiConfig`.
4. After each round, if there are ≥8 messages, a summary is generated and stored as `GroupMemory` (keyed by year_week).
5. Each character has hourly reply limits tracked on the model itself.

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
| `/chat/{groupId}` | `ChatRoomPage` | Active group conversation |
| `/settings` | `SettingsPage` | API configs, data management |

### Important Caveats

- `AICharacter` tracks hourly reply counts via `lastReplyTimestamp` and `hourlyReplyCount` directly on the model — these are mutated in `_isEligibleToReply` without re-saving to DB each time, only the limit check is enforced during a round.
- Non-release runs read Hive directly from the repository `data/` directory, including API keys stored inside `api_configs.hive`.
- Release builds read/write Hive under the user's app support directory and create fresh empty `*.hive` files there on first launch.
- The `custom` provider requires a manual `baseUrl` input; all others have hardcoded base URLs in `ApiProvider`.
- Local `data/*.hive` files are intentionally versioned as development-only data.

## Extensible Features (Roadmap)

> Ideas derived from analyzing the current codebase, ordered by fun/value vs. effort. Pick a few per iteration.

### High priority — implemented (2026-07-07, branch `feat/chat-enhancements`)

- ✅ **Streaming / typewriter replies.** `ChatApiService.streamChatMessage` reads SSE and `ChatRoomPage` renders tokens incrementally with a blinking cursor + "停止生成" button.
- ✅ **Character persona presets / template library.** 10 built-in presets in `CharacterPreset.presets`; one-tap apply from the form dialog and a FAB on the list page (still requires choosing an ApiConfig).
- ✅ **Conversation export / share.** `ConversationExportService` exports Markdown/JSON to `chat_group_exports/` and shares via `share_plus`; entries on Settings page and chat-room AppBar. Export only reads display fields — never apiKey/apiProvider/apiConfigId.
- ✅ **Humanized chat engine.** Intent selection uses mentions, recent speakers, relationship state, topic fit, and character memory.

### Medium priority — implemented

- ✅ **Regenerate / stop reply.** Action sheet on AI messages (long-press) provides "重新生成" + "引用回复"; regenerate re-queries the API with existing context, sets `replyToMessageId`.
- ✅ **Quote-reply UI.** Long-press AI message → action sheet → "引用回复"; shows quoted bar above input with sender name + snippet; stored via `Message.replyToMessageId` and rendered in bubble header.
- ✅ **Scenario / scripted modes.** `_scenarioPromptFor` matches group theme keywords (辩论/debate, 吐槽/roast, 开会/board-meeting, etc.) and injects scene-specific system prompt into `_buildApiMessages`.
- ✅ **Per-character long-term memory.** Injected as first system message in every API call: `【{name}的自我记忆】{memorySummary}`.

### Low priority — polish / enhancement

- ✅ **Token tracking.** `ChatStreamEvent` carries `promptTokens`/`completionTokens`; `SseParser` extracts `usage` from SSE; recorded per character via `DatabaseService.recordTokenUsage`; displayed in Settings page with per-character breakdown and reset button.
- ✅ **Light/dark theme toggle.** SegmentedButton in Settings page under "外观" section; persisted in Hive `app_settings` box; `MyApp` reads on startup.
- ✅ **Voice playback (TTS).** `flutter_tts` speaks AI replies on long-press; toggle in Settings persists in Hive `app_settings` box.
- ✅ **Unit tests.** Extracted orchestration logic into `ChatOrchestrator` and related policy/prompt services; tests cover eligibility, block reasons, usage tracking, focus extraction, name prefix stripping, mention behavior, and humanized memory/prompt logic.
- **Cost estimation.** Token usage exists, but provider/model-specific price calculation is not implemented.
- **Chat history search.**
- **Import / restore flow.** Export exists, but importing characters/groups/conversations is not yet available.

### Known limitations (current implementation)

- Import for characters/groups/conversations not yet available — only export (added 2026-07-07); data is local-only and easy to lose.
- Test coverage covers SSE parsing, presets, export safety, mention parsing, activity policy, chat orchestration, and humanized memory/prompt logic. UI-heavy chat room behavior still relies mostly on extracted logic tests.
- Versioned `data/*.hive` may contain live API keys and chat data, so repository access should be treated as sensitive.
