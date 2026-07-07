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
- `AICharacter` — persona with system prompt, avatar, reply rate limits
- `ChatGroup` — a group of characters with a theme; messages belong to a group
- `Message` — user or AI messages with mention support
- `GroupMemory` — weekly-summarized topic memory per group, auto-updated after each AI round

### Flow

1. User creates AI characters and groups them into `ChatGroup`s.
2. In `ChatRoomPage`, user sends a message → triggers `_runAiRound` which randomly picks 1-2 eligible AI characters to reply in sequence (max 3 auto rounds). In addition, ~3s after entering a room the app starts an **idle auto-chat loop** (`_startAutoChat`): every 5-9s it randomly triggers 0-2 eligible characters to speak; a single burst runs at most 5 rounds, then pauses 10s and resumes.
3. Each reply calls `ChatApiService.sendChatMessage` with the character's `ApiConfig`.
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
- `ApiConfig` stores `apiKey` in plaintext in Hive; no encryption layer is applied.
- The `custom` provider requires a manual `baseUrl` input; all others have hardcoded base URLs in `ApiProvider`.

## Extensible Features (Roadmap)

> Ideas derived from analyzing the current codebase, ordered by fun/value vs. effort. Pick a few per iteration.

### High priority — implemented (2026-07-07, branch `feat/chat-enhancements`)

- ✅ **Streaming / typewriter replies.** `ChatApiService.streamChatMessage` reads SSE and `ChatRoomPage` renders tokens incrementally with a blinking cursor + "停止生成" button.
- ✅ **Character persona presets / template library.** 10 built-in presets in `CharacterPreset.presets`; one-tap apply from the form dialog and a FAB on the list page (still requires choosing an ApiConfig).
- ✅ **Conversation export / share.** `ConversationExportService` exports Markdown/JSON to `chat_group_exports/` and shares via `share_plus`; entries on Settings page and chat-room AppBar. Export only reads display fields — never apiKey/apiProvider/apiConfigId.

### Medium priority — contained, practical

- **Regenerate / stop reply.** `_runAiRound` is already structured; add a "regenerate this AI reply" action and a "stop this round" button.
- **Quote-reply UI.** `Message.replyToMessageId` already exists but is never used. Add long-press-to-quote and render the quoted snippet in the bubble.
- **Scenario / scripted modes.** Inject "debate / roast / board-meeting" system prompts based on `ChatGroup.theme` to give group chats more "story".
- **Per-character long-term memory.** `AICharacter.memorySummary` is defined but **never injected into the conversation** (only `GroupMemory` is used). Wiring it up lets a character remember preferences across sessions.

### Low priority — polish / enhancement

- **Cost / token tracking.** Each call knows its `model`; accumulate estimated spend per character/group.
- **Chat history search.**
- **Light/dark theme toggle.** Currently forced dark; expose a switch.
- **Voice playback (TTS).** Speak AI replies aloud — pure fun.
- **Unit tests.** Only `test/widget_test.dart` exists today. Add tests for `_isEligibleToReply`, `_parseMentions`, `_buildApiMessages`.

### Known limitations (current implementation)

- `AICharacter.memorySummary` is not wired into the dialogue context.
- Import for characters/groups/conversations not yet available — only export (added 2026-07-07); data is local-only and easy to lose.
- Test coverage covers SSE parsing, presets, and export services; chat orchestration logic (`_isEligibleToReply`, `_parseMentions`, `_buildApiMessages`) still lacks unit tests.
- `ApiConfig.apiKey` is still stored in plaintext in Hive (see Important Caveats).
