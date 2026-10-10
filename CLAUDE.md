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

Hive models live in `lib/core/models/` and are registered in `DatabaseService.init()` (`lib/core/database/database_service.dart`). Boxes: `ai_characters`, `api_configs`, `chat_groups`, `messages`, `group_memories`, `character_memories`, `relationship_states`, `app_settings`, `character_skills`, `agent_tasks`, `work_mode_workspaces`, `ai_governance_ledger`, `user_profile`, `permanent_memories`, `relationship_events`, plus `dev_credentials` (非 release 才打开的调试凭据镜像，没有 model 类也不注册 adapter).

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
- Every error exit of `_streamChatMessageInternal` must set `ChatStreamEvent.sanitized: true`. `_collectStreamedOnce` passes a marked message through verbatim and re-sanitizes only an unmarked one (a custom `streamChatMessage` override that yields a provider body). Forgetting the mark re-masks the client's own wording: a Dio receiveTimeout arrives as `连接超时`, and masked it becomes `流式请求失败`, which `RetryHandler.isTransientResult`, `_needsCompletionFallback` and `WorkFailure` can no longer read as a retryable transport failure. `ChatStreamEvent.truncated` (`finish_reason == 'length'`) is set only by the OpenAI-compatible SSE parser — the Anthropic / Responses / Gemini parsers do not produce it yet — work mode compensates by comparing `completionTokens` with the requested `max_tokens` (`requestedMaxTokens`).
- Memory summarization fires at ≥8 messages **and** at most once per 10 minutes, and only for groups (never DMs).

Direct chats reuse `Message.groupId` with the stable key `dm:{characterId}` (`DirectChatSession.conversationIdFor`). Lightweight inbox state (`readAt`, source, last proactive timestamp) lives in the `app_settings` box rather than a Hive model class.

### Work mode (`lib/features/work_mode/`)

An explicit per-room toggle. When on, non-empty user input is routed to a work task (`WorkTaskCoordinator` → `WorkAgentLoop`) instead of chat rounds. This is the largest and most actively developed subsystem.

- `WorkTaskCoordinator` owns scheduling **app-wide** (mounted via `WorkTaskOverlayHost` in `MaterialApp.builder`), independent of any widget, with `maximumConcurrentTasks = 2`. Tasks survive chat-room disposal.
- `WorkAgentLoop` drives execution; the model receives public checkpoints, never a private reasoning trace.
- `WorkRoleRouter` elects an executor among group members from inferred stage/occupation + `CharacterSkill`. A model recommendation can never invent a qualification.
- 新群工作任务从聊天输入、协调器提交及独立追问推广入口统一创建 v2；DM 和普通聊天保持原行为。`WorkDiscussionRunner` 先选择相关团队、实际查证未决问题、形成方案并逐成员认可，再由同一个 `WorkAgentLoop` 制作、冻结候选、独立审查、返工复测和逐成员认可交付；旧“理解 100%”不是 v2 门槛。
- 启动恢复先保留 FIFO、附件关联和版本索引，再核对项目、当前成员资格/配置、文件摘要、工具收据和权限，重新获取资源锁。讨论和执行共用两个 App 运行槽；待用户/审批、主动暂停、停止、完成及删除任务不会自动执行。旧未完成群任务保留产物后转换，需显式继续重新确认方案；旧已完成历史不伪造签字，未知 schema 保留原状态并阻塞。
- v2 副作用调用前持久化不确定操作标记，完成后写设备本地提交收据；重启可用已提交收据或完整覆盖写的真实 SHA-256 后置条件核对，无法证明的命令、追加写、安装、删除及外部调用求助，不能盲重放，也不保证普遍 exactly-once。可信本地工具收据、路径授权、审批和资源锁不能作为跨设备可执行权限携带。
- Tools: sandboxed command runner (approval-gated, with `blockedByDefault` / `pathRejected` / `waitingForApproval` states), workspace file service (list / read / search / patch / rename / delete), document tool, weather service, and skill create / download. `browser.context` exists in the tool enum and is still described in prompts, but no runtime registers it — treat it as unavailable.
- Permissions: folder grants and agent settings persist under `app_settings` keys `work_mode_folder_grants_v1` / `work_mode_agent_settings_v1`; mutations are fingerprinted and require explicit approval dialogs.
- **会话槽只由持有者交还**：槽的持有者是"正在执行（`planning` / `runningTool`）或停在等用户（`waitingForApproval` / `paused` / `interrupted`）"的那条任务（`_pauseForDiscussion` 的串行所有权）。释放它必须先问 `_conversationHeldByAnotherTask`（收口点是 `_releaseConversationReservationFor`，恢复、删除、启动恢复三处共用）：无条件 `_conversationReservations.remove(groupId)` 会把同会话另一条任务的占用一起松开，于是两条任务并发跑在同一个群里（群工作上下文、产物路径与文件锁都是共享的）。`queued` **不算**持有者——排队中的任务什么也没握住，把它当占用方会让刚恢复的任务卡在自己留下的旧槽后面，谁也跑不起来。同理，已停止的 v2 任务不能按"讨论未完成"挡掉「继续」入口：停止已经取消讨论，v2 又不给「从头开始」，挡掉就没有出路；恢复后由 `_discussionGateFailure` 拦在执行之前。旧 v1 检查点没有这条重入路径，保持挡住。已停止的任务也不该出现「重试」：`_implRetry` 只放行 `canRestartAfterUserStop` 的「从头开始」，其余一律被状态守卫拒绝，摆一个点下去必然报错的按钮比不摆更糟。
- **撤回发言不能改写已被引用的正文**：v2 讨论的正文先发布、状态后校验（问题证据要绑定消息 id），一轮发言还是**逐项**落盘的（`_validateHumanMember` 只允许一次追加一条 issue），所以"第二项被拒绝"不等于"整轮没被采纳"。`_withdrawRejectedTurn` 必须先过 `_isAdoptedEvidence`——已落盘记录（issue / 决议 / 验收 / 签字 / 工作项的 `*Ref`）引用过的正文原样保留，拒绝仍由诊断事件记录；否则已提交问题的 `evidenceRef` 会被换成一句中性说明，问题依据就此失真。
- **「停止」是可继续的终态**：`_implStop` 写 `cancelled` + `AgentTask.userStopReason`，`AgentTask.isUserStopped` 是唯一判据——`cancelled` 还有别的来源（用户在恢复对话框里当场选「放弃恢复」、任务被删除），那些都不给继续入口。`resumeByUser` 接受这个状态并**原样保留**检查点（`completedOperations` / `committedActionKeys` / `lastArtifactPaths` / v2 协作状态），与「从头开始」的分界就在这里；面板「继续」由 `_continueUnavailableReasonForPanel` 决定可用性，「从头开始」由 `canRestartAfterUserStop` 决定是否出现，两者共用 `AgentTask.isUserStopped` 而不各自维护一份。停止**不再清空** `queuedUserRequests`（旧行为会吞掉用户已经发出的输入），改由 `resumeByUser(restoreQueuedFollowUps:)` 让用户当场决定一并执行还是丢弃；因此 `_implShouldRouteNewTaskForFollowUp` 里"队列非空就不另起任务"必须限定在**非终态**记录上——终态记录不会再排空自己的队列（`_promoteQueuedFollowUp` 在 `cancelled` 上早退），让队列把它钉住会让用户下一句直接撞上"已停止的任务不能继续追问"。停止前若正卡在软超限暂停上，两个标记会同时成立，`continueNeedsFreshSoftLimitBudget` 规定继续走「接着跑」而不是「再给一次预算」（后者在 `cancelled` 上会被状态守卫拒绝）。v2 协作任务不给「从头开始」：那条路会清空整块协作记录，`retry` 的 v2 拒绝因此必须排在"已停止或已完成的任务不能重试"之前，否则诊断会退化成看不出原因和出路。

Work mode is the only agentic execution path. The legacy ordinary agentic runtime (`AgentRuntime`) and its progress-reporting subsystem were removed because nothing in `lib/` ever instantiated them — do not reintroduce a second execution loop.

### Web search + gateway

`lib/features/web_search/` is a clean-architecture feature: `application/` (coordinator, query planner, turn cache, snapshot builder, retry policy), `data/` (settings store, credential repository), `models/`, `presentation/`, `providers/` (Tavily, Brave, DuckDuckGo Instant Answer, keyless HTML, gateway, native, visible browser), `security/` (endpoint validator, DNS guard, query sanitizer, secret scanner).

Search is scoped to the **user turn**: multiple AI replies in one round share a single `WebSearchSnapshot`, and `off` / `ask` / `auto` policy is evaluated before any provider call. Search results are treated as untrusted external data (structured evidence + source numbering + prompt-injection defense). Search credentials use their own secure-storage namespace and must not reuse `ApiConfig` fields. See `docs/decisions/ADR-001-production-web-search-provider-gateway.md`.

`gateway/` is the production backend: a **fixed-upstream proxy**, not a general URL fetcher. The client can only submit a query to `POST /v1/search` and can never choose a destination. It resolves/rejects private IPs and pins the verified IP, requires bearer auth in production, enforces per-token rate limits + daily quota + circuit breaker, and logs neither queries nor credentials.

### Credentials and storage

- API keys live in `flutter_secure_storage`, resolved through `ApiCredentialResolver` / `CredentialRepository` (`lib/core/storage/`), not in the `api_configs` Hive box.
- 所有凭据（聊天 / 图像 / 实时 / 语音 / 搜索 / 企微 / `default_provider`）最终都经过 `SecureStorageService`，它是唯一收口点；非 release 下该层再套一层调试镜像 `DebugCredentialCache`（见「关键红线」）。新增加凭据类型时不需要各自实现回退，但**不要**把新凭据写进 `app_settings`：那个 box 受 git 跟踪，明文密钥会被提交进仓库。
- Non-release runs read Hive from the repo `data/` directory; release builds create fresh empty boxes under the user app-support directory from `assets/release_templates/seed_manifest.json`.
- Export and backup paths are engineered to omit credentials.
- Some tracked `data/*.hive` files are development fixtures; `data/api_configs.hive` and `data/dev_credentials.hive` are local-only and gitignored. `data/autonomous_*.hive` and `data/evidence_memories.hive` are **dead legacy fixtures** with no remaining references in `lib/` — ignore them.

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
- **macOS Debug 凭据兼容**：debug 构建是 ad-hoc 签名，每次重建后二进制指纹都变，钥匙串 ACL 认不出它，于是**每次读取都弹一次登录密码框**——「始终允许」只对点它时那个二进制有效，重建即失效。收敛手段是唯一收口点 `SecureStorageService` 下的调试镜像 `DebugCredentialCache`（`dev_credentials` box）：读取命中镜像即返回、未命中才读一次钥匙串并落盘；**写入只写镜像、不碰钥匙串**（重建后的二进制做任何钥匙串写入同样会弹框）；删除先写**墓碑**再尽力删钥匙串，且删除失败不报错——没有墓碑，下一次读取会回落钥匙串把已删的密钥复活。镜像只在非 release 打开（`DatabaseService._openDebugCredentialCacheBox`，刻意不走 `_openBoxSafely`，打不开就退化为直通），box 被 gitignore、不进 `_releaseHiveFiles` 与备份。`LegacyApiCredentialMigrator` 在任何读取之前必须先 `seedDevelopmentCredentialCache`：待迁移配置的明文就在记录自己的 `legacyApiKey` 里，不先镜像就会在每次启动时读一次钥匙串。安全写入失败后仍可仅在非 release 保留 `legacyApiKey`，并以 `hasCredential=true` 且 `credentialId=CredentialRepository.developmentHiveCredentialId` 作为开发回退标记，`ApiCredentialResolver` 与删除流程必须识别该标记；Release 严禁读取或写入 Hive 明文 Key。
- **工作模式连续修改红线**：恢复中的工作任务必须占用会话控制器，新输入只能排队并在旧任务结束后派发，禁止取消旧任务后静默丢弃新请求。中英文“修改同一/相同/当前/上次文件”等明确修订请求必须覆盖原附件路径；只有新建请求发生重名时才允许自动改名。修订钉定只作用于**同名文件**（`default_work_task_runner_context.dart` 的 `_namesSameFile`）：模型请求的路径与修订目标 basename 相同时才改写为该目标的绝对路径，脚本、素材、分段源文件等其它路径按普通规则解析。把钉定套到每一次写操作会让交付物成为任务里唯一可写的文件——模型要写的脚本静默落到交付物上且工具报 success，`workspace.list` 又看不到它，于是模型换名重写、无限循环（2026-09-30 现场：15 次 patch 全被重定向，`.docx` 被覆盖成 Python 源码，全程 `command.run` 只跑过最初那一次）。流式通道返回空内容时可对同一请求回退一次非流式调用；标准 `content` 为空时才允许读取兼容字段 `reasoning_content`，两者均为空必须报错。源码附件的本地兜底必须有对应语言的可运行模板，否则应明确失败，禁止把说明文本伪装成 `.py/.js/.ts` 等代码附件。
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

214 test files. `test/` root holds feature-level suites (chat room, characters, memory, backup, direct chat, search, persistence); subdirectories group `work_mode/` (57), `agentic/` (17), `audio/` (9), `core/`, `services/`, `web_search/`. Shared helpers live in `test/helpers/` (`lifecycle_hive.dart`, `fault_injecting_box.dart`, `capturing_chat_api_service.dart`); fixtures in `test/fixtures/`.

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
- `WorkArtifactDeliveryGuard` 已提供交付合同与 DOCX/HTML 等结构校验，候选发布与审查还会核对真实文件摘要。结构正确不等于软件已运行测试；`browser.context` 尚无运行时注册，缺浏览器能力必须阻塞或走用户明确的人工验收/豁免。文档审查必须完整读取正文，`workspace.document` 用 `startChunk` / `nextChunkStart` 有界分页，相关检索片段不能冒充全文。网络来源核查尚未接通专业审查工具入口。
- In-room progress is shown by `WorkTaskPanel`, not in the chat transcript. The multi-line `agent-progress:` bubble has had no producer since the work-mode rewrite; only its renderer survives, for messages already persisted in users' Hive boxes.
- DM 仍可由角色路由器生成 `WorkHandoffState` 并由协调器串行接手；新群任务使用 v2 工作项/候选/审查责任交接，不再生成 legacy handoff。旧群 handoff 仅保留历史，迁移重新核对后进入 v2。DM 阶段切换会清除上一阶段的投递重发通知，避免下一角色重复发送上一角色产物。
- 完整/会话备份通过现有附件通道保存交付版本及关联报告；配置备份不含任务历史。缺物理文件标记不完整，导入版本仅作历史并标记 `verified=false`，项目需重新绑定；导入未完成 v2 在原任务显式继续后归档旧方案，重新确认角色、方案、工作项、决策及验收，旧人工豁免和签字不授权当前执行。冻结的历史文件保留原始来源标识和摘要；活动 Hive 引用按新 ID 重写，历史签字不授权当前执行。
- v2 当前状态每类索引最多 64 条。四个只追加的台账按"旧记录还有没有人读"各自收口：**签字**在解析时先归档同键旧记录（见 `WorkCollaborationState.compactedApprovals`，所以这条上限限的是**有效认可**数、不随迭代累积；归档键里带 `approved`，改口前后的签字各自留证，成员增量的"只追加一条"判据也必须按归档后的形状核对，否则改口再改回来会被判成非法改写；键里**不带**需求版本、团队版本、迭代与摘要——除 `idea` 外所有读取判据都只比当前值，留着这些维度就是让历史签字永久占着容量，32 个需求版本就能攒满 64 条解析失败），提交动作缓存最多 128 条；未决项达到容量时阻塞而不静默丢失，完整细节留在设备本地事件/版本文件。版本单任务存储上限 1 GiB、单份元数据 1 MiB，达到上限需处理后继续，并非任意长任务无限留存。**签字容量的判据是"当前主体"而不是列表长度**（`WorkCollaborationGate.liveApprovalGroups`）：归档键对 `delivery` 仍带 `subjectId`，而它就是随迭代变化的迭代 id，于是失效候选的签字永远不与新签字同键、只能一路堆下去——30 轮旧候选就能让第 65 条**当前**签字把整个状态解析成 null、任务永久卡住。读取判据（`planReady` 读 `taskId`、`deliveryReady` 读当前迭代 id、`ideaApproved` 读问题 id）只钉在当前主体上，旧迭代签字对任何判据都不可见，历史凭证仍在群里的公开回复（`evidenceRef`）与事件日志里，所以容量按 `currentApprovals` 只数当前门禁实际读取的签字：方案绑定当前需求/团队与空候选字段，交付绑定当前候选/摘要/需求/团队/验证，提案绑定问题自身的需求版本与当前团队。旧需求或团队版本的提案签字不占当前容量，台账本身仍完整保留。**候选版本索引同属这一类，但用的是另一种归一化**：`iterations` 在解析时按 `WorkCollaborationState.boundedIterations` 只留**最新 64 条**（上限常量 `maxIterations`），与 `appliedEventIds` 是同一形状的滚动窗口。它不能像签字那样"保留列表、只放宽容量"，因为旧行确实有人读（面板列出整个索引、发布编号分配取最大编号、`sendCandidateVersion` 按 id 校验候选属于本任务索引）；但**权威记录不在状态里**——每轮候选目录与 `candidate.json` 完整留在工作区，`WorkCandidatePublisher.recover` 会从磁盘重建整个候选列表并重写 `index.json`，而所有**判据**都只钉最新一条（`currentIteration` / 交付门槛 / 发布编号分配 / 索引校验）。不设窗口就会撞上 64 条上限：第 65 轮候选让整个状态解析成 null、任务永久卡住。丢的只是被取代那一行的状态级 `status` 与 `reviewRef` 指针，候选文件、清单与审查报告仍在工作区与详情存储里。**问题与决策用的是第四种收法：只挂在唯一落盘入口 `WorkDiscussionState.mergeIntoExecutionState`**（`WorkCollaborationState.boundedHistory`）。它们**不能**像候选索引那样在解析时裁——`_validateMemberResolution` / `_validateReview` 是**按下标**比对新旧问题的，读取时裁会让下标错位、把一次正常答复判成"篡改问题或采纳范围提案"（有回归用例钉住这条）。所以内存里的台账始终完整，写进任务检查点的才是有界镜像：只丢**判据不依赖会变的当前版本**的已了结条目（`resolved` 且非 `idea`、`waived`、`rejected`），`open` / `deferred` 是未决义务、一条不丢；`idea` 且 `resolved` 的判据是 `ideaApproved`（读当前团队与认可），团队一换就可能翻回未满足，同样不参与窗口。决策与问题**同批**处理：保留**仍有效的成员加入/人工审查授权**和**保留下来的**问题、验收引用的 `answered` / `waived` 决策；缺少答复凭据的记录仍是未决，不能裁掉，否则会丢失授权或错误改变门禁。代价是 `isValid` 不再对这两类清单设长度上限（长度改由落盘窗口约束），未决条目本身不设硬顶——它们各自需要一次成员发言才会产生，且已由进展保护盯着。
- 模型上下文使用 `WorkCollaborationState.toPromptJson`：只携带 `currentApprovals` 和最新候选，需求、问题、验收及用户决策保持完整；权威检查点仍用 `toJson` 保存历史。群讨论、执行提示与 `WorkContextSnapshot` 共用此投影，存量摘要按当前权威状态重建后发送，禁止从旧摘要再次注入完整历史。不能为解决历史膨胀删除上下文保护或截断未决义务。
- 公开协作增量（`WorkTaskCoordinator.applyCollaborationUpdate`，即 `fromDiscussionRunner == false` 的那条路）只能**原样携带**已有签字：新增或**改写**一条 `delivery` 签字都必须来自实际成员请求-响应，否则抛"不能由外部增量代签"。判据是 `WorkCollaborationState.approvalFingerprint`（按固定字段顺序拼接的签字内容指纹），不是 `eventId` —— id 由调用方给出，而解析会归档被同键新签字顶掉的旧记录，旧 id 一旦滚出 `appliedEventIds`/台账索引，换个 `verificationRevision`（或任何字段）的同 id 记录就会被当成全新签字放行。比对的是内容而不是"列表是否变长"：归档正好可以让长度不变。
- 群任务 v2 的产物合同只有一个词表：`artifactContract.type` 的 `software` 就是 v1 `deliverableType` 的 `source`，录入入口与唯一收口点都是 `WorkCollaborationState` 构造函数里的 `canonicalContract`（词汇表映射仍是 `WorkRoleRouter.canonicalArtifactType`）——等价校验会放行 `source`/`software`，不规范化就原样写回合同。**归一化挂构造函数而不是提交点**：状态既能从落盘 JSON 读回、也能由内存增量构造，只在提交时归一化会漏掉两条路——已经 `ready` 的旧任务不再经过提交，原样读回就让软件材料、文件清单与验证命令整段闭环检查失效（`prepareCollaborationWork` 只对 `type == 'software'` 要求这些）；未组队的旧任务则会让基线比较把一次等价拼写差异当成"合同被改写、必须递增需求版本"，抛错卡住。两套词表并存过一次的后果是整段软件闭环检查失效——真实入口把「制作飞行棋 HTML 游戏」判成 `source`，而材料工作项、测试覆盖、独立审查资格与候选文件合同都在比 `software`，于是读一遍正文就能宣称那个游戏通过审查。合同只能由两个来源改写：用户原话（`_userRewrittenContractFields` 要求一句**变更指令**：旧值 → 变更动词 → 新值，三处否定各按**作用对象**核验——变更连接自身（"不要改成 X"）、旧值之前（`_prohibitionAdjacent`，允许“不要把 / 不能将 / do not rename”等紧邻结构连接，也识别“保持 game.html 文件名”）、目标之后紧跟否定；**不能**按"旧值所在从句出现否定"整段扫，"在保持内容不变的前提下把 game.html 改名为 game2.html"里那句"保持"管的是内容，会把正常改名整句挡下来。这次变更还必须是指令而不是被讨论的提议（`_evaluationFrame` 认从句里的疑问/讨论标记，"先讨论把 game.html 改名为 game2.html 是否合适，不要实际改名"不构成授权）。名称共现不算授权，`to` 必须逐字出现在指令里——模型提案里的新值只有被用户原话点名才算数，不能反过来由提案推定授权。中文里名称与汉字直接相邻不需要空格，拉丁词元的边界只看 ASCII 词字符；由用户身份落盘新需求版本，模型那次提案仍作废重写）与协调成员按新需求版本重新形成的提案（`_validateContract` 钉定，模型不得擅改）。
- 「原地重建分段文件」护栏只认**真实重复**——写入的**整份**正文与最近几次新建过的某一份相同；**不数**新建文件个数、也**不做空白折叠**。判据取整份正文而不是开头若干字符：共用版权头或 `<!DOCTYPE html>…<template>` 模板头的独立文件开头可以完全一样，按开头判会在第二个文件就误报（2026-10-01 复现：六个文件共用 500 字版权头、正文各异，被判成原地重建并暂停）。折叠空白同样误报：`<pre>` 里一个空格与六个空格是两份显示结果不同的正文，"用 pre 演示一至六个空格"这类正常多文件交付会在第四次写入后暂停（2026-10-02 复现）。按个数拦也不行：正常的多文件交付是逐个新建、正文各异，按个数拦会在第三个文件之后要求直接 `finish` 并最终把任务暂停。代价是模型每次重写都产出不同文字时不再命中——正文不同就是不同的文件。判定态落盘键是 `writeDigests`，刻意避开 `_isPrivateField` 的 `content` 黑名单，否则护栏活不过一次暂停。抢救写入（`.rescue-` 派生名）既不计数也不清零。

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
- `GroupMuteStore` keeps per-group mutes in `app_settings` (`group_muted_characters_v1`). Mute only removes a member from **automatic** selection — `@`-mentioning them still gets a reply, and that reply's tone still follows mood and relationship, so mute is deliberately not part of `ReplyEligibilityPolicy`. Adding any new `app_settings` key that backups should carry costs **three** edits, not one: add it to `backup_setting_keys.dart` (the single list the exporter and the importer both consult — when those were two hand-kept copies, adding a key to only the exporter produced backups that its own importer rejected) plus that file's `backupConfigurationOnlySettingKeys` if it is user configuration, add a per-conversation branch in `backup_snapshot.dart` `_selectedSettings` if the value is scoped to one room, and add a rule in `restore_plan_rewrite.dart` when the value holds entity ids (otherwise `copyWithNewIds` restore leaves stale ids). A key scoped to one room costs a **fourth** edit that is easy to forget: `data_lifecycle_settings.dart`, where `planConversation` / `planCharacter` / `planClear(chatContent)` and `conversationSettingCount` each enumerate room-scoped keys — miss it and deleting that conversation leaves an orphan key behind (the boundary key was added exactly this way: the group-deletion test caught it).
- Treat repository access as sensitive: versioned `data/` fixtures and `data/ai_files/conversations/` contain real chat and task history. The credential-bearing `data/api_configs.hive` is local-only and ignored.
- 启动恢复与网络自动重试分开：仅 `retryableNetwork` 失败进入既有有限重试阶梯。有效群 v2 不受旧累计 100 动作/60 分钟和自动整轮 120 秒限制，单次模型/命令时限与无进展保护仍有效；DM 保留原限制。`_autoResumeTaskIds` 只标记网络尝试，手动继续/重试/停止必须清除该 id，不能让用户手动执行继承自动标记。
- A completed task can still hold a retryable "artifact delivery" failure: the deliverable is saved and validated, only the chat attachment failed, so the task stays `completed` and only a resend notice is recorded (a deliverable that no longer satisfies its contract still fails). Such a task is not auto-resumed (only `failed` tasks are) and is retryable exactly while `workArtifactDeliveryRetryPending()` is true. Clear the notice with `workWithoutArtifactDeliveryNotice()` rather than by hand: it leaves a damaged (non-map) checkpoint untouched instead of wiping it to an empty, runnable-looking state.
- 工作模式一次模型请求的输出上限由**能力表**决定：`workModeRequestOutputTokens` 取 `model_capability_registry` 的 `maxOutput`、上下文窗口的一半、以及绝对天花板 `maxWorkRequestOutputTokens`（32768，用来压住明显超出厂商能力的声明值；它不能替代厂商侧校验——把 8k 上限的模型声明成 32768 仍会收到 400）三者中的最小值。窗口一半这一条是必需的：8k 窗口的模型按声明值要 8k 输出时输入预算会被压到 0，请求会带着空 `messages` 发出去。**不再**硬性截到 8192（那会压住用户手工声明的大输出模型；内置模型声明值都不超过 8192，所以对它们是空操作）。长内容因此必须**分块写**，契约写在提示词里：先用 `workspace.patch` 建一个分段文件，此后每次带 `{"append":true}` 追加一段（每次 content ≤3000 字——CJK 约 1～1.5 token/字，加上 JSON 转义与包装落在 4～6k，对"约 8k"的上限留有余量），全部写完后用一次 `workspace.patch` 的 `parts` 合并成交付物的 Markdown 源。**不要**反复往交付物本身写：append 会把它建成半成品，而它同时是要被核对、被交付的那个文件（带 `append:true` 的写入本就不算满足单产物契约）。只有需要转换格式时才用 `command.run`（合并只写纯文本，DOCX 交付物必须由 `pandoc report.md -o out.docx` 转换产生），纯文本拼接不需要 shell；`document.word` 技能里有同一句。**只有 `buildAgentDecisionPrompt` 是工作模式实际发送的提示词**（`buildToolPlanningPrompt` 已无生产调用者，契约加在那里不会生效）。截断判定跨协议：`truncated`（OpenAI 兼容解析器的 `finish_reason == length`）或"已输出 token 达到本次请求的 max_tokens"（`requestedMaxTokens`，覆盖 Anthropic / Responses / Gemini），命中后修复指令与之后那次协议重试都必须把策略换成"分块写"——只要求"输出合法 JSON"没有用，被截断的正是"一次写完整份文件"这个动作，原样重试会再撞一次上限。
- 工作模式一次模型请求有**两个**时限，归因必须分开：总时限 `modelCompletionTimeout`（默认 300s，管整轮请求）与**首字节停滞**时限 `modelFirstTokenTimeout`（默认 180s，只在"一个字符都还没收到"时计时，首字节一到即撤销；生效值由 `effectiveFirstTokenTimeout` 钳到不超过总时限，所以调用方把总时限设得更短时不会构造失败）。停滞能单独归类的判据是可判定的：零输出意味着不存在任何已生成内容，提前放弃并重试不会丢掉工作；而总时限做不到这么激进——它必须容下"生成很慢但正在输出"的请求，缩短它就是砍掉正常的那一类。两者在用户可见文案里都被 `WorkTaskErrorSanitizer` 折叠成"任务执行超时"，所以归因不能走文案：客户端那侧的码由 `WorkModelDeadlineException`（`work_model_deadline.dart`）带着走——`modelFirstByteStall` / `modelCompletionTimeout`，从看门狗抛出处一路写进「模型请求暂时失败，准备重试。」事件的安全元数据 `failureCode`（它此前只会落成笼统的 `retryableNetwork`，与上游 5xx 同码；`WorkFailure._typeFor` 必须认这两个码并仍归到 `WorkFailureType.retryableNetwork`，改码时两处同改，否则会掉进 `modelProtocol` 兜底把停滞说成"模型写坏 JSON"）。治理表里 `failureType=cancelled` 且 `latencyMs` 恰是时限值仍是同一件事的网关口径，可作交叉验证；首字节分布则只存在于 liveness 事件携带的 `firstTokenMs` 里，`modelFirstTokenTimeout` 这个值必须靠它校准（现成数据里没有首字节直方图，180 秒是保守起点）。2026-09-30 现场：`sensenova-6.8-flash-lite` 对 16.8k 输入的三个请求各吞掉 300 秒零输出，占整轮 23 分钟里的 15 分钟。
- 协议重试（面板上的「模型返回格式无效」）有**三种**成因，标题必须分开，否则用户按错误的类别处置：`truncated`（输出用满预算 → 改策略分块写）、`repairRequestFailed`（修复请求自己失败 → 链路问题，该重试）、其余（模型写坏 JSON → 收窄要求或换模型）。判据集中在 `_protocolRetryTitle`（`work_agent_loop_retry.dart`）。修复请求**与普通决策走同一条模型级重试**（`_callModelWithRetries`），停滞/断链先按 `maxModelRetries` 重试并发「模型请求暂时失败，准备重试。」，用尽后由 `_repairModel` 抛 `AgentDecisionRepairFailure` 把成因交回解析器（`AgentDecisionParseResult.repairRequestFailed`）；它此前直接 `await model(repair)`，一次可重试的停滞被记成协议错误、还吃掉一次协议重试额度。「修复请求失败」与「修复响应为空」是两回事（后者是模型又写了一次坏 JSON），解析器里必须分开措辞，且 `AgentDecisionRepairFailure` 之外的异常只落固定文案、不透传 `toString()`（对象标识与耗时不进用户文案）。协议失败诊断另记 300 字有界正文开头 `responseSnippet`（首次决策响应）与 `repairResponseSnippet`（修复后那次，`reason` 多数时候描述的正是它——两类字段对不上时只留首次正文会让人按错误的形状推断；落盘前由事件存储做密钥/URL/路径脱敏，完整正文仍不落盘）——反复出现的「模型写到一半就停」只能靠形状定性，计数与解析器文案都看不出断在哪。2026-09-30 现场：`reason` 写着「修复响应为空」、事件之间 180 秒空白，真相是首字节看门狗掐断了修复请求，用户看到的却是「模型返回格式无效」。
- 跟进分类器（`work_follow_up_policy.dart`）把动词分成**修订动词**（修改/修复/替换/覆盖/改/fix/revise…）和**程度词**（优化/完善/美化/改进…，判定修订前先剥离），规则是 `newFile && !revisionVerb` 一律判为新交付物。于是"根据这个 docx 生成一份 html，用前端技能优化"不再被当成"要改哪个旧文件"——那个澄清对新建请求无解，任务会永远暂停。只有真正的修订动词才可能把同时要求新建文件的请求判给旧文件（例："生成一个副本，并修改 /work/report.md"）。
- 任务"在等用户回答"的可回答性只有一处判据：`WorkTaskClarification.isAnswerable`（模型提问 `isPending` 或协调器澄清 `isFollowUpPending`），面板回复框、聊天回答入口、`WorkTaskUserAction`、"继续"按钮和协调器的 `_isFollowUpClarification` 全部走它。判据分开维护过一次的后果：面板不给回复框、"继续"又按另一个判据拒绝，任务既答不了也退不出，而用户在会话里发什么都只得到一句"已收到补充要求"。澄清答复的判决分三级——先按"原句+答复"判，仍无法判定才只看答复；直接只看答复会丢掉"答复只指明目标"时原句里的修订意图；只有第二级（明确要求新建交付物）和第三级（整句就是清单序号："2"、"第2个"，见 `WorkFollowUpOption.selectedBy`）都不成立时才维持原判。澄清的候选目标是**结构化**落盘的：`WorkFollowUpDecision.clarificationOptions`（序号 + 完整路径）随 `clarificationQuestion` 一起写进检查点，面板据此渲染候选按钮（点一下提交完整路径，走第一级判决；同名候选退回显示完整路径，因为两个一样的按钮等于没给选择），`_withoutFollowUpDecision` 与 `WorkTaskClarification.clear()` 必须同步清除它；同一轮答复仍没解开目标时由 `clarificationAnswerRejected` 标记（面板据此提示"上次回复没被采纳"，暂停事件标题从"需要明确修订目标"改成"仍未确定修订目标"），首次提问不带该标记。序号判据故意很窄（整句只是一个序号指代），"生成 3 个文件"这类句子里的数字不算选择。
- 任务面板的标签栏按**当前会话**收敛（外加其它会话里正在执行的任务，因为切走页面任务照跑）：会话内执行中的优先、最多 4 条，其它会话的终态/排队/暂停任务不占标签。"还有 N 个任务在队列中"只数当前会话未显示且未结束的任务——它曾按全 App 任务流计数，把别的会话 9 月就已结束的任务也算成了"18 个任务在队列中"。
- 任务删除是**真删除**（`WorkTaskCoordinator.deleteTask`）：先按 `stop` 的口径释放该任务的 runner、会话保留、资源锁、排队与自动续跑标记，再删 `agent_tasks` 记录，**最后**删公开事件日志（删除之后再写的事件会用同一个 taskId 重建 JSONL）。写入路径只有一个闸门 `_putTaskRecord`（`_save` 与 `_record` 的失败分支都走它），它按 `_deletedTaskIds` 拒绝一切迟到写入——否则删除刚返回，一条正在收尾的 runner 就能把记录（甚至带着"日志保存不完整"）写回来。删除后同会话的下一条请求必然新建任务——留一条终态记录会让追问继续挂到它上面复用产物路径，这正是"真删除"要避免的。快照不做定向删除（交给既有保留策略回收），但账本状态要跟着收尾，否则那条记录永远不可回收：进行中的任务记 `cancelled`，已结束的任务保留它自己的终态；已生成的文件不随任务删除；标签隐藏标记由宿主清（`WorkTaskOverlayHost._deleteTask`），协调器不碰 `app_settings`——它注入 `contextBoundaryWriter` 回调（`work_task_providers.dart` 接到 `WorkContextBoundary.advance`），删除时把该会话的**工作上下文分界线**推到删除时刻（`app_settings` 键 `work_mode_context_boundary:<conversationId>`）。分界线是单向的：`advance` 只在更晚时写入，`readAt` 对损坏值返回 null（视为没有分界线），过滤判据是严格晚于。它切的是模型可见的两条聊天记录通道——执行提示的对话历史（`default_work_task_runner_context.dart` 的 `_conversationHistory`）与群讨论的「近期群聊」（`work_discussion_runner_model_io.dart` 的 `_recentChatMessages`）——不删聊天消息、不删磁盘产物、不影响普通闲聊的提示。**刻意不碰** `_requestWithAttachmentContext`：它解析的是当前任务自己的附件，排队中的任务其请求消息可能早于分界线，过滤它会让那个任务丢失附件。删除闸门（协调器 `_deletedTaskIds` 与事件存储的同名集合）只在"任务记录被外部写回"时由 `WorkTaskCoordinator.reconcileDeletionGates()` **逐 id** 解除：记录已经回来的 id 放行，记录仍不存在的 id 继续拦（整表解除会给不存在的 id 开口子，让停在 await 上的迟到续跑把记录写回来）。调用点只有备份导入成功后一处；数据清除不需要调用（清除后要么记录不存在、闸门无害，要么由导入时核对解禁）。写入路径刻意不自己判断"记录又存在了"：记录存在证明不了这次写入拥有它。
- 私聊里一条任务记录是**长期血缘**：只要记录还在，新请求默认并入它（`_latestWorkTaskForConversation` → `enqueueFollowUp`），推广时 `task.userRequest` 会被新请求**覆盖**（`work_task_coordinator_follow_up_promotion.dart`），于是标签栏写着新请求、事件日志仍是这条记录的全部历史——2026-09-30 现场就是这样长成了"我删了老任务，新任务却还带着它的历史"的错觉（那条记录其实从未被真删，见上一条的四条痕迹）。两处配套约束缺一不可：①执行动态按**运行段**收敛（`WorkTaskRunBoundary`；新事件带 `safeMetadata.runBoundary` 标记，存量日志回退认标题"开始处理已排队的追问"），默认只显示当前这一段，更早的由用户点开——`_record` 与 `eventStore.append` 已经支持 `safeMetadata`，别再另起一套判据；②**明确新建交付物**的请求在私聊里只有旧记录已经"交还给你"（终态，或应用关闭后中断、没有排队、没在等回答——`_isReleasedForNewDeliverable`）时才另起一条，群聊维持"终态才另起一条"。`_implShouldRouteNewTaskForFollowUp` 与 `_implTaskForConversation` 的 `ownershipRank` 必须同认这个判据：只改路由不改所有权，新记录建好后的下一次追问会被那条旧中断记录重新接走（因此已交还的中断记录与终态记录同级排序、由更新时间分先后，仍在等回答的记录靠会话保留位兜住）。修订请求不受影响，继续并入原记录以便覆盖原产物路径。
