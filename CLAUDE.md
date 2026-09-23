# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 回复语言

- 面向用户的所有回复必须使用中文；代码、命令、文件路径、标识符与引用原文保持原样。

## Commands

### Flutter app (repo root)

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # regenerate all *.g.dart
flutter analyze
flutter test
flutter test test/widget_test.dart                          # single file
flutter test test/work_mode/work_task_coordinator_test.dart # single file
flutter test --plain-name "部分用例名"                        # single test by name
flutter run
```

`build_runner` is not optional after touching a Hive model or a `@JsonSerializable` class — every `*.g.dart` in the repo is generated, and both `analyze` and `test` depend on them being current.

### Search gateway (`gateway/`, Node ≥22.18)

```bash
cd gateway && npm test          # node --test, no dependencies installed
cd gateway && npm start         # node --experimental-strip-types src/server.ts
```

The gateway is plain TypeScript executed via Node's type-stripping — there is no build step and no `node_modules`.

### Scripts

| Script | Purpose |
|---|---|
| `scripts/publish_local.sh` | Build + upload macOS/iOS/Android artifacts to an existing GitHub Release |
| `scripts/package_macos_dmg.sh` | Package the macOS build as a DMG |
| `scripts/generate_changelog.py` | Regenerate `CHANGELOG.md` from Conventional Commits |
| `scripts/verify_android_release_permissions.sh` | Manifest/permission check for a debug-signed release APK |
| `scripts/seed_data.dart`, `merge_data_to_project.dart`, `clear_dm_context.dart`, `fix_config_refs.dart`, `inspect_configs.dart`, `update_reply_limit.dart` | Development-data maintenance (Hive fixtures) |
| `scripts/qa_*.dart` (**local-only**, gitignored) | Standalone harnesses for tool-request parsing (`qa_real_tool_request_check.dart`, `qa_verify_tool_request.dart`) |

## Architecture

**AI Group Chat Simulator** — a local-first Flutter app that simulates group conversations between AI characters backed by LLM providers, plus a work-mode agent that executes real file/command tasks.

Toolchain: **Flutter 3.27.1 / Dart 3.6.0** (`pubspec.yaml` requires `sdk: ">=3.5.0 <4.0.0"`; CI and release workflows pin 3.27.1). Current version `2.1.0+225`.

### Repository layout

```
lib/          Flutter app (476 Dart files)
  core/       Shared infrastructure: models, database, storage, streaming, theme, audio, widgets
  features/   Feature modules (12)
  services/   App-level services (chat API, export, TTS, presence, WeCom push)
  providers/  Provider aggregator
gateway/      Node search proxy (production web-search backend)
scripts/      Release + development-data tooling
tool/         mock_openai_server.dart (local API stub)
docs/         Design docs, ADRs, work-mode + web-search specs, project map
data/         Hive development fixtures (api_configs.hive is local-only + gitignored)
```

### Feature modules

| Module | Lines | Role |
|---|---|---|
| `work_mode/` | ~43k | Work-mode agent: task coordinator, agent loop, tool execution, approvals, discussion |
| `chat_group/` | ~16k | Group list, chat room UI, AI selection/scoring, streaming, memory, attachments |
| `memory/` | ~13k | Long-term memory: observation pipeline, migrators, audit UI, relationships |
| `web_search/` | ~12k | Pluggable search providers, query planning, per-turn snapshots, citations, security |
| `agentic/` | ~4.1k | Character skills, prompt/context builders, tool + progress protocol |
| `backup/` | ~5.9k | Versioned `.cgbak` export/restore |
| `settings/` | ~5.1k | API configs, theme, tokens, search config, work-mode settings, governance |
| `ai_character/` | ~3.4k | Character CRUD, presets, gender inference + migration |
| `ai_governance/` | ~2.7k | Request gateway/guard, budget + pricing ledger, model capability registry |
| `direct_chat/` | ~1.3k | DM inbox, foreground watcher, proactive contact |
| `document/` | ~1.1k | PDF/DOCX/XLSX parsing for attachments |
| `search/` | ~0.6k | Global message search page + inverted index |

### Data model

Hive models live in `lib/core/models/` and are registered in `DatabaseService.init()` (`lib/core/database/database_service.dart`). Boxes: `ai_characters`, `api_configs`, `chat_groups`, `messages`, `group_memories`, `character_memories`, `relationship_states`, `app_settings`, `character_skills`, `agent_tasks`, `work_mode_workspaces`, `ai_governance_ledger`, `user_profile`, `permanent_memories`, `relationship_events`.

- `ApiConfig` — shared API key/URL/model config (1:many with characters). API keys are **not** stored here in plaintext; see Credentials below.
- `AICharacter` — persona, system prompt, avatar, reply-rate limits, compact `memorySummary`, gender.
- `ChatGroup` — theme, member IDs, owner name, `replyIntervalSeconds` (auto-chat cadence).
- `Message` — user/AI content, mention IDs, `replyToMessageId`, attachments. Belongs to a group **or** to a DM conversation key.
- `GroupMemory` — weekly group summary, keyed `{isoWeekYear}_W{week:02d}` (e.g. `2026_W37`).
- `CharacterMemory` / `RelationshipState` / `RelationshipEvent` / `PermanentMemory` — layered per-character memory, directional relationship state, and durable memory entries.
- `CharacterSkill`, `AgentTask`, `WorkModeWorkspace`, `UserProfile` — agentic/work-mode state.

`@HiveType` typeIds 0–24 are allocated. **typeId 17 is unallocated** — do not reuse it blindly. Never reorder or reuse existing `@HiveField` indices.

### Chat room flow

User message → `ChatOrchestrator` / `HumanizedChatOrchestrator` scores eligible characters by mentions, recent speakers, relationship state, topic fit and memory, then up to N reply in sequence. Constants live in `lib/features/chat_group/chat_room_page_state.dart`:

- **User round:** up to **3** replies (2 when the message @-mentions someone); `_maxAutoRounds = 3`.
- **Idle auto-chat:** starts **8 s** after entering a group room (18 s for DMs); burst capped at `_maxAutoChatRounds = 4`; then `_autoChatBurstPause = 35 s`. Interval is **45 s** for DMs, or the group's `replyIntervalSeconds` clamped to 5–60 s, plus 0–9 s jitter.
- Turning on work mode disables idle auto-chat entirely.
- Replies stream via `ChatApiService.streamChatMessage` (SSE) or `sendChatMessage`; `SseParser` extracts `usage` for token accounting.
- Memory summarization fires at ≥8 messages **and** at most once per 10 minutes, and only for groups (never DMs).

Direct chats reuse `Message.groupId` with the stable key `dm:{characterId}` (`DirectChatSession.conversationIdFor`). Lightweight inbox state (`readAt`, source, last proactive timestamp) lives in the `app_settings` box rather than a Hive model class.

### Work mode (`lib/features/work_mode/`)

An explicit per-room toggle. When on, non-empty user input is routed to a work task (`WorkTaskCoordinator` → `WorkAgentLoop`) instead of chat rounds. This is the largest and most actively developed subsystem.

- `WorkTaskCoordinator` owns scheduling **app-wide** (mounted via `WorkTaskOverlayHost` in `MaterialApp.builder`), independent of any widget, with `maximumConcurrentTasks = 2`. Tasks survive chat-room disposal.
- `WorkAgentLoop` drives execution; the model receives public checkpoints, never a private reasoning trace.
- `WorkRoleRouter` elects an executor among group members from inferred stage/occupation + `CharacterSkill`. A model recommendation can never invent a qualification.
- `WorkDiscussionRunner` runs a governed multi-member discussion before execution.
- Tools: sandboxed command runner (approval-gated, with `blockedByDefault` / `pathRejected` / `waitingForApproval` states), workspace file service (list / read / search / patch / rename / delete), document tool, weather service, and skill create / download. `browser.context` exists in the tool enum and is still described in prompts, but no runtime registers it — treat it as unavailable.
- Permissions: folder grants and agent settings persist under `app_settings` keys `work_mode_folder_grants_v1` / `work_mode_agent_settings_v1`; mutations are fingerprinted and require explicit approval dialogs.

Work mode is the only agentic execution path. The legacy ordinary agentic runtime (`AgentRuntime`) and its progress-reporting subsystem were removed because nothing in `lib/` ever instantiated them — do not reintroduce a second execution loop.

### Web search + gateway

`lib/features/web_search/` is a clean-architecture feature: `application/` (coordinator, query planner, turn cache, snapshot builder, retry policy), `data/` (settings store, credential repository), `models/`, `presentation/`, `providers/` (Tavily, Brave, DuckDuckGo Instant Answer, keyless HTML, gateway, native, visible browser), `security/` (endpoint validator, DNS guard, query sanitizer, secret scanner).

Search is scoped to the **user turn**: multiple AI replies in one round share a single `WebSearchSnapshot`, and `off` / `ask` / `auto` policy is evaluated before any provider call. Search results are treated as untrusted external data (structured evidence + source numbering + prompt-injection defense). Search credentials use their own secure-storage namespace and must not reuse `ApiConfig` fields. See `docs/decisions/ADR-001-production-web-search-provider-gateway.md`.

`gateway/` is the production backend: a **fixed-upstream proxy**, not a general URL fetcher. The client can only submit a query to `POST /v1/search` and can never choose a destination. It resolves/rejects private IPs and pins the verified IP, requires bearer auth in production, enforces per-token rate limits + daily quota + circuit breaker, and logs neither queries nor credentials.

### Credentials and storage

- API keys live in `flutter_secure_storage`, resolved through `ApiCredentialResolver` / `CredentialRepository` (`lib/core/storage/`), not in the `api_configs` Hive box.
- Non-release runs read Hive from the repo `data/` directory; release builds create fresh empty boxes under the user app-support directory from `assets/release_templates/seed_manifest.json`.
- Export and backup paths are engineered to omit credentials.
- Some tracked `data/*.hive` files are development fixtures; `data/api_configs.hive` is local-only and gitignored. `data/autonomous_*.hive` and `data/evidence_memories.hive` are **dead legacy fixtures** with no remaining references in `lib/` — ignore them.

### State management

Providers are **hand-written** `Provider` / `StateNotifierProvider` — there are no `@riverpod` annotations in `lib/` (the `riverpod_annotation` / `riverpod_generator` / `riverpod_lint` dependencies are present but unused). `lib/providers/providers.dart` aggregates `databaseServiceProvider`, the web-search providers, the work-mode providers, and defines `appSkinModeProvider` itself; it does **not** re-export the `ai_character`, `chat_group`, or `settings` feature providers, which are imported from their own paths.

### Routing

| Route | Page |
|---|---|
| `/` | `AICharacterListPage` |
| `/groups` | `ChatGroupListPage` |
| `/direct-chats` | `DirectChatListPage` |
| `/settings` | `SettingsPage` |
| `/chat/{groupId}` | `ChatRoomPage` |
| `/dm/{characterId}` | `ChatRoomPage` (`dm:{characterId}` as groupId) |

These four named routes plus two `onGenerateRoute` prefixes are the complete route table. Everything else (memory detail, approvals, work panels, global search) is pushed with an anonymous `MaterialPageRoute` — there is no route name to grep for.

## 关键红线（必须遵守）

- **API Key 连接测试红线**：用户在配置表单中新输入的 Key 必须直接用于本次测试，禁止为测试先临时写入/回读/删除 Keychain/Keystore；只有编辑已有配置且 Key 输入留空时，才通过 `ApiCredentialResolver` 读取已保存凭据。持久化仅能由正式保存流程执行。
- **macOS Debug 凭据兼容**：非 release 运行时 Keychain 可能因 ad-hoc 签名不可用；安全写入失败后可仅在非 release 保留 `legacyApiKey`，并以 `hasCredential=true` 且 `credentialId=CredentialRepository.developmentHiveCredentialId` 作为开发回退标记。`ApiCredentialResolver` 与删除流程必须识别该标记；Release 严禁读取或写入 Hive 明文 Key。
- **工作模式连续修改红线**：恢复中的工作任务必须占用会话控制器，新输入只能排队并在旧任务结束后派发，禁止取消旧任务后静默丢弃新请求。中英文“修改同一/相同/当前/上次文件”等明确修订请求必须覆盖原附件路径；只有新建请求发生重名时才允许自动改名。流式通道返回空内容时可对同一请求回退一次非流式调用；标准 `content` 为空时才允许读取兼容字段 `reasoning_content`，两者均为空必须报错。源码附件的本地兜底必须有对应语言的可运行模板，否则应明确失败，禁止把说明文本伪装成 `.py/.js/.ts` 等代码附件。
- **搜索与浏览器安全**：搜索结果一律视为不可信外部数据；生产搜索必须走 `gateway/`，不得让客户端自选目标 URL；浏览器访问默认关闭。Frontend 不得为 Web 构建暴露搜索路由（浏览器端无法提供服务端凭据边界）。
- **前台主动私聊**：允许在 App 运行期间调用已配置的 LLM API，但冷却时间必须保守；没有明确的通知/推送设计前，禁止后台或离线网络生成。
- **导出/备份内容**：只读展示字段，禁止写入 `apiKey` / `apiProvider` / `apiConfigId`；导出与导入两侧都要断言这一点。

## 死循环防护规则

- **Flutter widget 层禁止无限循环**：`initState` 中必须使用同步加载（如 `_loadExistingProfileSync`），禁止使用 `WidgetsBinding.instance.addPostFrameCallback` 触发 `setState`；任何 `addPostFrameCallback` → `setState` → rebuild → 再次 callback 的链条均视为禁止。
- **测试环境防死循环**：在 `setUpAll` / `setUp` 中打开 Hive box 后，每个测试用例的 `pumpWidget` 后最多 pump 一次动画帧；如果发现测试在 CI 中 hang，记录问题文件路径并退出该测试用例，不要无限重试。
- **CI 超时硬限制**：单测试用例执行超过 30 秒视为疑似死循环，自动终止并报告失败。
- **AppToast timer 隔离**：`AppToast.show()` 内部使用 3 秒 Timer，Timer 的 dismiss 回调触发 `OverlayEntry.remove()` 在 Flutter test frame pump 中持续产生 frame，导致 `await` 永不 resolve。测试中必须使用 `tester.runAsync()` 包裹所有 Hive 写操作，禁止在测试中直接调用含 `AppToast.show()` 的生产方法。

## Code Generation

`dart run build_runner build --delete-conflicting-outputs` regenerates Hive adapters (`hive_generator`), JSON serialization (`json_serializable`), and any Riverpod output. Required after modifying a `@HiveType` model, a `@HiveField` index, or a `@JsonSerializable` class. Run it before `analyze`/`test` in CI order — the workflow does exactly this.

## Dependency overrides

This project builds against **Flutter 3.27.1**, whose Gradle plugin does not accept the `android.flutter` property used by newer releases of some plugins. Two packages are pinned in `pubspec.yaml`:

- `package_info_plus: '>=8.0.0 <9.0.0'`
- `wakelock_plus: '>=1.0.0 <1.4.0'`

`file_picker` carries a range constraint (`>=8.0.0 <9.0.0`) in regular dependencies, not in `dependency_overrides`. Before adding a dependency, check whether its Android `build.gradle` uses `android.flutter`.

## Testing

213 test files. `test/` root holds feature-level suites (chat room, characters, memory, backup, direct chat, search, persistence); subdirectories group `work_mode/` (57), `agentic/` (17), `audio/` (9), `core/`, `services/`, `web_search/`. Shared helpers live in `test/helpers/` (`lifecycle_hive.dart`, `fault_injecting_box.dart`, `capturing_chat_api_service.dart`); fixtures in `test/fixtures/`.

Large suites are split into `*_part_NN.dart` and `*_helpers_NN.dart` files (backup, data lifecycle, search). When adding a case to one of these, add it to the correct part file rather than creating a new top-level suite.

`flutter analyze` in CI fails on **errors only** — warnings and infos do not block. `analysis_options.yaml` uses stock `flutter_lints` with no custom rules and excludes `scripts/**`.

## CI and release

- `.github/workflows/ci.yml` — on push/PR to `main`: `flutter pub get` → `build_runner` → `analyze` → `test`, plus a separate `gateway/` job running `npm test`.
- `.github/workflows/release.yml` — on `v*` tag or manual dispatch. CI builds **Windows only**; macOS/iOS/Android are built locally via `scripts/publish_local.sh` and uploaded to the same release. Web is deliberately not a release target.
- Android release is **fail-closed**: without a complete `android/key.properties` the release build errors instead of falling back to debug signing. Only the permission-verification job sets `ALLOW_DEBUG_SIGNING=true`, and that APK must never be published.
- Commit messages follow Conventional Commits; `scripts/generate_changelog.py` derives the next version from them (breaking → major, `feat` → minor, else patch).
- 排查 CI 失败时注意：`gh run view <run_id> --log-failed` 只返回失败步骤的末尾若干行，常找不到具体失败用例；完整日志用 `gh api repos/{owner}/{repo}/actions/jobs/<job_id>/logs`（job_id 从 `gh run view <run_id> --json jobs` 取）。

## 代码质量检查清单

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

## Review / 校验完整性规则

- 当用户要求 Review、验收或校验某个阶段、模块、文件或改动集时，必须先明确本次范围，并完整检查范围内的需求符合性、正确性、边界与失败路径、测试有效性、可读性、架构、安全、性能、新老兼容和本清单中的代码质量要求。
- 发现一个问题不得立即中断校验或直接给出最终结论；必须继续完成其余可执行检查，尽可能一次性收集全部问题。某项检查失败时，记录失败证据并继续不依赖该项的检查；只有安全风险、数据破坏风险或客观阻塞使后续检查无法进行时才停止，并明确未检查范围。
- 最终报告必须集中列出所有发现，按严重级别排序，并为每项提供文件与行号、证据、影响和建议修复方向；同时列出已执行命令、通过项、失败项、未检查项及原因。完成完整范围前，不得只报告“第一个问题”，也不得宣称 Review / 校验完成。
- “测试通过”不等于验收通过。测试、静态分析、实现逐行审查和与规格逐项对照均完成后，才可给出通过结论；如有阻塞问题，应一次性列全后给出不通过结论。

## Known limitations

- Backup/restore (`lib/features/backup/`, `.cgbak`) covers every Hive box except `ai_governance_ledger` (the usage audit trail is intentionally device-local). `WorkModeWorkspace.workDirPath` is dropped on import because local paths are not portable. `formatVersion` must match exactly; `schemaVersion` accepts 1 or 2. Backup scopes are `all` / `configurationOnly` / `conversation`. Restored `ApiConfig`s need their key re-bound.
- Fully offline proactive contact is not implemented: closed-app AI generation would need pre-generated local notifications or a server-side push service. Current proactive DMs are foreground-only.
- Web builds cannot provide the app's credential boundary, so they are not a release target.
- UI-heavy chat-room behaviour is mostly covered indirectly through extracted logic tests rather than widget tests.
- Work mode has no structural validation of generated files. The legacy runtime's `FileValidator` (HTML tag balance, `flutter analyze` on generated Dart, Java/C++ shape checks) was the only implementation and was removed with it, so generated code is written and reported but never shape-checked. Re-adding that for work mode is a separate piece of work, not a regression to restore.
- In-room progress is shown by `WorkTaskPanel`, not in the chat transcript. The multi-line `agent-progress:` bubble has had no producer since the work-mode rewrite; only its renderer survives, for messages already persisted in users' Hive boxes.

## Documentation map

`docs/PROJECT_MAP.md` is a shorter orientation doc. Deeper references:

- `docs/decisions/` — ADRs (ADR-001: production web-search provider gateway)
- `docs/production_web_search_technical_design.md`, `docs/production_web_search_implementation_retrospective.md`
- `docs/work_mode_agent_v1_{requirements,technical_design,user_guide}.md`
- `docs/system_design.md`, `docs/relationship_audit_redesign.md`
- `docs/group_work_discussion/` — staged design + review docs for the governed discussion workflow
- `docs/verification/`, `docs/roadmap/`, `docs/archive/`

`AGENTS.md` at the repo root is a short pointer file for other agents: it carries the reply-language rule and tells them to read this file, but deliberately duplicates none of it. **Guidance lives only here** — when you change a constraint, change it in this file and do not copy it into `AGENTS.md`, which previously drifted out of date exactly because it held a second copy.

## Important caveats

- `AICharacter` tracks hourly reply counts via `lastReplyTimestamp` / `hourlyReplyCount` mutated in `_isEligibleToReply` without re-saving to DB each round — only the limit check is enforced during a round.
- `ApiProvider` has 8 entries: `deepseek`, `qwen`, `zhipu`, `moonshot`, `baidu`, `xfyun`, `sensenova`, `custom`. `custom` requires a manual `baseUrl`. `ApiProtocol` additionally selects OpenAI Chat Completions / Anthropic Messages / OpenAI Responses / Gemini Native upstream formats.
- `RelationshipState.recentMoodAt` decides whether a mood is still live (`kRelationshipMoodTtl`, 30 min). Read it through `effectiveMood()`, never `recentMood` directly — ordinary events neither change the mood nor refresh the timestamp, so a stored mood the code forgot to expire would otherwise leak into prompts and reply scoring. On upgrade the field is null for existing rows, so **all pre-existing moods read as expired (neutral)**; there is deliberately no backfill, because the only available source (`updatedAt`) is advanced by later ordinary events and would keep stale moods alive.
- `GroupMuteStore` keeps per-group mutes in `app_settings` (`group_muted_characters_v1`). Mute only removes a member from **automatic** selection — `@`-mentioning them still gets a reply, and that reply's tone still follows mood and relationship, so mute is deliberately not part of `ReplyEligibilityPolicy`. Adding any new `app_settings` key that backups should carry costs **four** edits, not one: add it to `backup_setting_keys.dart` (the single list the exporter and the importer both consult — when those were two hand-kept copies, adding a key to only the exporter produced backups that its own importer rejected), include it in `backup_snapshot.dart` `_selectedSettings`'s `configurationOnly` set if it is user configuration, add a per-conversation branch there if the value is scoped to one room, and add a rule in `restore_plan_rewrite.dart` when the value holds entity ids (otherwise `copyWithNewIds` restore leaves stale ids).
- Treat repository access as sensitive: versioned `data/` fixtures and `data/ai_files/conversations/` contain real chat and task history. The credential-bearing `data/api_configs.hive` is local-only and ignored.
