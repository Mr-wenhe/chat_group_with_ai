# Project Map

## What This App Is

AI 群聊模拟器是一个本地优先的 Flutter 应用，用 Hive 存储角色、群组、消息、记忆和设置，用 Dio 调用 OpenAI-compatible chat completions 接口。核心体验在 `ChatRoomPage`：用户发言后，应用根据提及、活跃度、关系状态、角色记忆和频率限制选择 AI 角色流式回复。

## Active Feature Areas

| Area | Main Files | Notes |
|------|------------|-------|
| App shell and routing | `lib/main.dart`, `lib/core/widgets/app_widgets.dart` | 初始化数据库、主题、底部导航和页面路由。 |
| Models and storage | `lib/core/models/`, `lib/core/database/database_service.dart` | Hive models and adapters. Model changes require `build_runner`. |
| API configs and settings | `lib/features/settings/` | API keys are stored in Hive; dev builds read repository `data/`, release builds create brand-new user-local Hive files from an empty template manifest. |
| Characters | `lib/features/ai_character/`, `lib/core/models/character_presets.dart` | Character CRUD plus preset templates. |
| Groups and chat room | `lib/features/chat_group/` | Group list/form, chat room UI, AI selection, streaming, quote reply, regenerate, TTS, memory. |
| LLM calls and streaming | `lib/services/chat_api_service.dart`, `lib/core/streaming/` | Non-streaming and SSE streaming chat completions. |
| Export | `lib/services/conversation_export_service.dart`, `lib/features/settings/export_page.dart` | Markdown/JSON exports intentionally omit key/config fields. |
| Tests | `test/` | Covers SSE parsing, export safety, presets, mention parsing, orchestration, humanized chat/memory, activity policy. |

## Data Model Notes

- `ApiConfig`: reusable provider/model/base URL config, including persisted `apiKey`.
- `AICharacter`: persona fields, legacy API fields, reply limits, and compact `memorySummary`.
- `ChatGroup`: group name/theme, member IDs, owner name.
- `Message`: user/AI content, mention IDs, optional `replyToMessageId`.
- `GroupMemory`: weekly group summary.
- `CharacterMemory`: layered per-character memory for one group.
- `RelationshipState`: directional relationship and mood between an AI and the user/another AI.

## Verification Commands

Use the Flutter binary on PATH when available:

```bash
flutter analyze
flutter test
```

On this machine, Flutter was available at:

```bash
/Users/fengye/work/flutter/flutter/bin/flutter analyze
/Users/fengye/work/flutter/flutter/bin/flutter test
```

## Maintenance Checklist

- After editing Hive models or generated providers, run:
  ```bash
  dart run build_runner build --delete-conflicting-outputs
  ```
- Keep generated `*.g.dart` files in sync with their source models.
- `data/*.hive` is intentionally versioned as the development dataset only.
- Before sharing exports, remember they are plaintext conversation files even though key/config fields are filtered out.
- Treat repository access as sensitive because versioned Hive files may contain API keys and chat history.
