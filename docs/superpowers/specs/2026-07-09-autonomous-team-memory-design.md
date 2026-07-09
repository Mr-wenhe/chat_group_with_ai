# Autonomous Team And Evidence Memory Design

## Goal

Build a general autonomous work system for AI characters. When a group chat or direct chat enables autonomous execution, AI characters can turn natural language and conversation context into real work: code changes, document creation, workflow creation, system commands, file operations, image or format conversion, and other artifact-producing tasks. The same design adds permanent, cross-conversation memory with evidence, so characters remember real facts without inventing past events.

## User-Approved Requirements

- Autonomy is per group chat or direct chat, controlled by an independent switch.
- When autonomy is enabled, all AI characters in that conversation automatically receive full tool permissions: workspace read, workspace patch, command run, browser context, skill download, and skill create.
- The user grants direct source-code/project-directory access once per target project. After that, the current autonomous task may modify source files and run commands without per-tool approval.
- The app no longer treats autonomous work as sandbox-only. If a target project is authorized, AI can work directly in that project.
- Settings exposes an AI work root directory. The default is the existing app support data path under `data/ai_files`.
- Every group or direct chat gets a dedicated directory under the AI work root. Task journals, handoff state, reports, generated artifacts, and recovery files are written there.
- Autonomous tasks are triggered by natural language, group/direct-chat context, or AI messages when they imply real output. This is not limited to software development.
- If a required skill exists, AI may download it. If no suitable skill exists, AI may create and persist one.
- Tasks are goal-driven and have no time limit. They continue until the goal is completed, product/owner confirmation passes, verification succeeds, the user stops them, or the same blocking condition repeats enough times to justify pausing with a report.
- If the app closes, tasks pause. On app launch, unfinished autonomous tasks are recovered automatically and continue.
- AI memory must be permanent across groups and direct chats.
- A character's memory of the user and of other AI characters is global, not scoped to one group or direct chat.
- All facts and memories must have real evidence. AI must not invent prior conversations, relationships, times, locations, project states, or shared history.
- Users can inspect, delete, and correct permanent memory entries.

## Existing Context

The codebase already has a single-character agentic path:

- `lib/features/agentic/agent_runtime.dart` can plan tool calls, request workspace reads/patches, run commands, use browser context, download skills, and create skills.
- `lib/features/chat_group/chat_room_page.dart` routes certain messages into the agent runtime, appends tool results to chat, and handles per-tool approvals.
- `lib/features/agentic/tools/local_agent_bridge_server.dart` runs local workspace operations.
- `DatabaseService` already stores `AgentTask`, `CharacterSkill`, and an AI processing directory in `app_settings`.
- Current `CharacterMemory` and `RelationshipState` are scoped by `groupId`, while `AICharacter.memorySummary` is a short per-character summary. This is not enough for cross-conversation permanent memory with evidence.

## Architecture

Add a dedicated feature module:

```text
lib/features/autonomous/
  autonomous_trigger_detector.dart
  autonomous_conversation_config_service.dart
  autonomous_task_service.dart
  autonomous_team_runtime.dart
  autonomous_role_resolver.dart
  autonomous_tool_runner.dart
  task_journal_service.dart
  evidence_memory_service.dart
  evidence_memory_prompt.dart
  widgets/
    autonomous_status_banner.dart
    autonomous_authorization_sheet.dart
    evidence_memory_viewer.dart
```

`ChatRoomPage` should remain mostly UI and orchestration glue. It detects that a message or auto-chat event may start real work, calls `AutonomousTaskService`, displays status messages, and lets the autonomous module own task state, recovery, role scheduling, tool execution, and journaling.

The existing `AgentRuntime` should be reused for individual agent tool planning. The autonomous layer wraps it with conversation-level authorization so write-like tools no longer ask for per-tool approval after the user has enabled autonomy and authorized a target project for the task.

## Conversation Configuration

Create a Hive-backed model:

```dart
class AutonomousConversationConfig extends HiveObject {
  final String id;
  final String conversationId;
  final String conversationType; // group | direct
  bool enabled;
  String workDirPath;
  String? authorizedProjectPath;
  bool sourceWriteAuthorized;
  DateTime? authorizedAt;
  DateTime updatedAt;
}
```

Storage key can be `conversationId`, where group chats use the group id and direct chats already use `dm:{characterId}`.

Settings should rename the current "AI 文件处理" section to "AI 工作根目录". The default remains `DatabaseService.defaultAiProcessingDir`, currently `<app support>/data/ai_files`.

Conversation work directories:

```text
<AI work root>/
  conversations/
    group_<groupId>/
    dm_<characterId>/
```

Task directories:

```text
<conversation work dir>/
  task_<taskId>/
    task_journal.md
    handoff.json
    requirements.md
    acceptance_report.md
    artifacts/
```

If a project directory is authorized, real source edits happen in that project. The conversation task directory remains the durable journal and recovery location.

## Task Models

Extend `AgentTask` if migration cost is low; otherwise add `AutonomousTask` and keep the old model for legacy single-character tasks.

Recommended fields:

```dart
enum AutonomousTaskStatus {
  planning,
  running,
  verifying,
  fixing,
  productReview,
  completed,
  blocked,
  paused,
  cancelled,
  failed,
}

enum AutonomousTaskPhase {
  intake,
  requirements,
  execution,
  verification,
  bugfix,
  productConfirmation,
  handoff,
}

class AutonomousTask extends HiveObject {
  final String id;
  final String conversationId;
  final String conversationType;
  String userGoal;
  String taskType; // code | docs | workflow | system | file | media | general
  String workDirPath;
  String? targetProjectPath;
  AutonomousTaskStatus status;
  AutonomousTaskPhase phase;
  List<String> participantCharacterIds;
  String? plannerCharacterId;
  String? executorCharacterId;
  String? verifierCharacterId;
  int repeatedBlockCount;
  String lastBlockSignature;
  String resultSummary;
  DateTime createdAt;
  DateTime updatedAt;
}
```

Task steps:

```dart
class AutonomousTaskStep extends HiveObject {
  final String id;
  final String taskId;
  final String characterId;
  String role; // product | executor | tester | reviewer | documenter
  String action;
  String toolName;
  String inputSummary;
  String outputSummary;
  List<String> changedPaths;
  List<String> artifactPaths;
  int? commandExitCode;
  DateTime createdAt;
}
```

`handoff.json` should mirror enough state to recover if Hive state is incomplete: task id, phase, status, target project path, last successful step, last failed command summary, and next recommended action.

## Triggering

`AutonomousTriggerDetector` should classify messages and AI generated content as:

- `none`: ordinary chat.
- `suggest`: likely real-work request but autonomy is disabled.
- `startInConversationDir`: real work can happen in the conversation directory only.
- `needsProjectAuthorization`: direct source/project work is needed and no project is authorized.
- `startInAuthorizedProject`: project authorization exists and task can begin.

Detection should cover broad real-output intent:

- code: implement, fix, debug, test, build, refactor, review
- docs: create document, write plan, export report, summarize into file
- workflow: create process, checklist, script, automation
- system/files: organize files, rename, copy, convert, generate directory
- media: image conversion, format conversion, asset processing
- browser/context: inspect current page, capture context, turn page content into artifact

When autonomy is disabled, the app can let AI respond normally and optionally suggest enabling autonomy. When enabled, the task starts automatically unless project authorization is required.

## Authorization

The user approves once per target project path within the current conversation/task context. After approval:

- all participating AI characters in the conversation are granted full tool permissions
- `AutonomousConversationConfig.authorizedProjectPath` stores the path
- `sourceWriteAuthorized` is set to true
- tool approval prompts are bypassed by `AutonomousToolRunner`

Authorization should be explicit for source/project edits. If no project is authorized, autonomous tasks may still create files in the conversation work directory.

## Team Runtime

`AutonomousTeamRuntime` coordinates the work as a state machine, not as free-form chat.

Default phases:

1. Intake: classify goal, choose work directory and target project, choose participants.
2. Requirements: product/planner role writes `requirements.md` and acceptance criteria.
3. Execution: executor role performs real tool work.
4. Verification: tester/reviewer role runs checks or inspects artifacts.
5. Bugfix: failed verification becomes a concrete bug list and loops back to execution.
6. Product confirmation: product/planner role compares final state against acceptance criteria.
7. Handoff: write `acceptance_report.md`, update chat with final evidence and artifact paths.

Role assignment should be based on character roles and skills:

- product, PM, planner, analyst -> requirements and product confirmation
- developer, engineer, coder -> source changes and scripts
- tester, QA, reviewer -> verification and bug reports
- writer, documenter, operations -> docs, workflows, reports
- designer, media, image, asset roles -> image and asset tasks

If no role is an obvious fit, choose the most capable available character and let skill download/create improve it.

## Tool Execution And Skills

`AutonomousToolRunner` wraps `AgentRuntime`:

- It passes conversation/task context and current phase to the character.
- It injects available tools and full permissions.
- It bypasses write/command/browser/skill approval only when autonomy is enabled and the task is authorized for the relevant target.
- It records every tool request and result as an `AutonomousTaskStep`.
- It writes step summaries to `task_journal.md`.

Skill behavior:

- Before executing specialized work, ask the character to inspect whether an existing skill fits.
- If a catalog skill fits, use `skill.download`.
- If none fits, use `skill.create` with concrete instructions and required permissions.
- Generated skills persist to `CharacterSkill` and can be reused by that character later.

## Recovery

On app startup:

1. `AutonomousTaskService.resumePendingTasks()` loads tasks with `running`, `verifying`, `fixing`, `productReview`, `paused`, or recoverable `blocked` states.
2. For each task, read Hive state and `handoff.json`.
3. Rebuild runtime context from task fields, task steps, conversation config, work directory, and target project path.
4. Append a chat status message in the owning conversation: the task was found and resumed.
5. Continue from the next phase, not from scratch.

If the local bridge is unavailable, mark the task blocked with a clear reason and retry on next app launch.

## Blocking And Stop Conditions

There is no time limit.

A task stops only when:

- acceptance criteria pass and product confirmation completes
- the user manually cancels/stops it
- the same blocking condition repeats enough times that progress is impossible without user or environment change
- an unrecoverable data corruption or missing target path is detected

Block signatures should normalize repeated failures, for example:

- `missing_project_path`
- `command_not_found:flutter`
- `test_failure_same_output_hash`
- `bridge_unavailable`
- `model_no_valid_tool_request`
- `ambiguous_goal`

When blocked, write a blocker report to chat and `task_journal.md`, including the exact needed user/environment action.

## Evidence Memory

Add evidence-backed permanent memory rather than extending short summaries.

```dart
enum EvidenceMemoryType {
  selfFact,
  userFact,
  relationship,
  taskFact,
  correction,
}

class EvidenceMemory extends HiveObject {
  final String id;
  String subjectCharacterId;
  String targetId; // user or character id
  String targetType; // user | ai | project | self
  EvidenceMemoryType type;
  String content;
  String evidenceConversationId;
  String? evidenceMessageId;
  String? evidenceTaskId;
  String? evidenceTaskStepId;
  String evidenceSnippet;
  DateTime occurredAt;
  DateTime createdAt;
  DateTime updatedAt;
  double confidence;
  bool deleted;
  bool userCorrected;
}
```

Memory is global across group chats and direct chats:

- A character's memory about the user is shared everywhere.
- A character's relationship with another AI is shared everywhere, but only relevant in-context memories are injected.
- Group memory remains as group context and cannot be treated as global fact by itself.

Memory extraction should run after meaningful messages and task steps. It must only write entries when the fact is supported by a direct quote, tool result, or task log. Existing `CharacterMemory` and `RelationshipState` can be migrated as low-confidence legacy entries only when evidence is not available.

## Memory Viewer And Correction

Add a viewer in character details or settings:

- list memories by target: user, self, AI character, project/task
- show evidence snippet, source conversation, source time, confidence, and correction status
- allow delete
- allow correction, which creates a high-priority `correction` memory and marks the old entry corrected/deleted

Corrections override lower-confidence entries during prompt injection.

## Prompt Discipline

All normal chat, direct chat, autonomous planning, autonomous execution, and memory extraction prompts should include this rule block:

```text
【事实与记忆纪律】
只能使用已提供的聊天历史、工具结果、任务日志、永久记忆证据中的信息。
不得编造过去发生过的聊天、关系、承诺、时间、地点、项目状态。
如果没有证据，必须说“不确定”或自然追问。
提到“之前/上次/我们聊过”时，必须能从记忆或最近消息中找到依据。
不得为了显得亲密而虚构共同经历。
```

When memory is injected, include evidence-aware lines rather than bare facts:

```text
有证据的长期记忆：
- 2026-07-09，在群 group_x 的消息 msg_y 中，用户说过：“...”。可作为事实：...
- 任务 task_z 的验收报告显示：...
```

The model should never receive ungrounded relationship notes as if they were confirmed facts.

## UI Surface

Keep UI modest and consistent with the current Flutter app:

- Chat room top area: an autonomy status banner or compact switch for the current conversation.
- First project authorization: a bottom sheet showing target directory, permissions, and one-time authorization.
- During tasks: append concise status messages to chat and show a small "自治任务运行中" state with stop action.
- Settings: rename "AI 文件处理" to "AI 工作根目录".
- Character/settings memory viewer: inspect, delete, and correct memory entries.

Avoid turning the chat app into a separate project management dashboard in the first implementation. The journal files and chat status messages are enough for v1.

## Testing Strategy

Unit tests:

- trigger detector classifies broad real-output intents and ordinary chat correctly
- conversation config stores per-group and per-direct-chat autonomy settings
- work directory builder creates safe group/direct/task paths
- authorization bypasses tool approval only in enabled and authorized contexts
- team runtime advances phases and loops verification failures back to execution
- recovery resumes from Hive plus `handoff.json`
- repeated block signatures pause a task after repeated identical blockers
- evidence memory extraction rejects unsupported facts
- prompt builder includes fact discipline and only injects evidence-backed memory
- memory correction overrides older entries

Integration-style tests with fakes:

- product -> executor -> tester -> product confirmation completes a document task
- code task produces patch step, command step, failed verification, bugfix step, passing verification
- app restart simulation resumes a paused/running task from persisted state

Regression tests:

- existing ordinary chat, auto-chat, direct chat, and single-character agentic execution still work when autonomy is disabled
- existing generated `.g.dart` adapters remain consistent after model changes

Commands:

```bash
dart run build_runner build
flutter test
flutter analyze
```

## Implementation Boundaries

First implementation should deliver:

- per-conversation autonomy switch
- AI work root setting reuse/rename
- conversation/task directories
- once-per-project authorization
- autonomous task model and service
- basic team runtime with requirements, execution, verification, confirmation, handoff
- automatic skill download/create through existing handlers
- recovery on app startup
- evidence memory model, prompt injection, and basic viewer/correction flow

Later polish can add richer task dashboards, more specialized media tooling, finer-grained cost controls, and task history search.

## Self-Review

- Spec coverage: covers autonomous triggering, one-time authorization, direct project edits, no sandbox requirement, directories, skill download/create, recovery, goal-driven execution, permanent evidence memory, anti-fabrication prompts, and memory correction.
- Completion scan: no open fill-in items remain.
- Scope check: large but coherent. The implementation plan should break it into independently testable tasks.
- Ambiguity check: "no time limit" is implemented as no time-based stop, with repeated-blocker pause as the only automatic non-completion stop.
