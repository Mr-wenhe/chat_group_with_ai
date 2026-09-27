import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

import 'work_task_user_action.dart';

/// Persists one chat entry for each currently actionable task blocker.
///
/// Message ids carry the task, blocker and checkpoint version. This keeps the
/// bridge idempotent across coordinator replays and app restarts without
/// adding a second relation table or changing the Hive Message schema.
class WorkTaskActionMessageService {
  static const Duration credentialTimeout = Duration(seconds: 8);

  final DatabaseService database;
  final ApiCredentialResolver credentials;
  final DateTime Function() _clock;
  final Map<String, Future<void>> _writes = <String, Future<void>>{};

  WorkTaskActionMessageService({
    required this.database,
    ApiCredentialResolver? credentials,
    DateTime Function()? clock,
  })  : credentials = credentials ?? SecureApiCredentialResolver(),
        _clock = clock ?? DateTime.now;

  Future<void> notify(AgentTask task) async {
    // 私聊和群聊一样会在等待审批、授权或补充信息时卡住。提醒必须投递到用户
    // 正看着的那个对话里，否则用户唯一的入口就是去任务面板里翻找——而隐藏的
    // 标签根本不在标签栏上。隔离由发送者身份保证：私聊永远不会替另一个角色
    // 发言，找不到合格发送者时退化为系统提醒。
    final actions = WorkTaskUserAction.forTask(task);
    for (final action in actions) {
      // One broken message write must not prevent the other independent
      // blockers from receiving their reminders. The coordinator retries the
      // failed projection on the next durable task save or restore.
      try {
        await _writeOnce(task, action);
      } on Object {
        // Best-effort chat projection; the task panel remains authoritative.
      }
    }
  }

  Future<void> _writeOnce(
    AgentTask task,
    WorkTaskUserAction action,
  ) {
    final previous = _writes[action.messageId] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.catchError((Object _) {}).then((_) async {
      if (database.messageBox.containsKey(action.messageId)) return;
      // The credential lookup and Hive write are asynchronous. A newer task
      // checkpoint may replace this reminder while they are in flight; do not
      // publish an obsolete @ button after the user has already repaired,
      // cancelled, or revised the task.
      final storedTask = database.agentTaskBox.get(task.id);
      if (storedTask == null ||
          !WorkTaskUserAction.isCurrent(
            storedTask,
            blockerId: action.blockerId,
            version: action.version,
          )) {
        return;
      }
      final sender = await _senderFor(storedTask);
      final latestTask = database.agentTaskBox.get(task.id);
      if (latestTask == null ||
          !WorkTaskUserAction.isCurrent(
            latestTask,
            blockerId: action.blockerId,
            version: action.version,
          )) {
        return;
      }
      final group = database.chatGroupBox.get(latestTask.groupId);
      // Group membership may change while the credential lookup is in flight.
      // A role that was removed must never speak through a reminder that was
      // created before the membership edit; fall back to the system sender.
      final currentSender =
          sender != null && group?.aiCharacterIds.contains(sender.id) == true
              ? sender
              : null;
      final ownerName = database.ownerNameFromProfile();
      final content = _contentFor(
        action,
        latestTask,
        ownerName: ownerName,
        group: group,
        sender: currentSender,
      );
      final memberIds = group?.aiCharacterIds ?? const <String>[];
      final message = Message(
        id: action.messageId,
        groupId: latestTask.groupId,
        senderId: currentSender?.id ?? 'system',
        senderType: currentSender == null ? 'system' : 'ai',
        content: content,
        timestamp: _clock(),
        isMention: true,
        visibleToCharacterIds: List<String>.from(memberIds),
      );
      await database.persistMessage(message);
    });
    late final Future<void> tracked;
    tracked = operation.then<void>(
      (_) {
        // Map.remove returns the removed Future. Returning it from this
        // completion callback would make `tracked` try to complete with
        // itself, which surfaces as "Cannot complete a future with itself".
        if (identical(_writes[action.messageId], tracked)) {
          _writes.remove(action.messageId);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_writes[action.messageId], tracked)) {
          _writes.remove(action.messageId);
        }
        Error.throwWithStackTrace(error, stack);
      },
    );
    _writes[action.messageId] = tracked;
    return tracked;
  }

  Future<AICharacter?> _senderFor(AgentTask task) async {
    final group = database.chatGroupBox.get(task.groupId);
    final memberIds = group?.aiCharacterIds.toSet() ?? const <String>{};
    // Once a task has an executor identity, a reminder must never be written
    // in the voice of a different available member. This is especially
    // important for `executorUnavailable`: a healthy backup in the same group
    // is not an implicit reassignment and must not appear to have accepted the
    // task. Tasks that have not elected an owner may still use an eligible
    // active member to deliver the group reminder.
    final designated = _designatedExecutor(task);
    final candidates = designated == null
        ? <String>[
            ...task.assignedCharacterIds,
            ...memberIds,
          ]
        : <String>[designated];
    final seen = <String>{};
    final characters = <AICharacter>[];
    for (final id in candidates) {
      if (!seen.add(id) || !memberIds.contains(id)) continue;
      final character = database.aiCharacterBox.get(id);
      if (character == null ||
          !character.isActive ||
          !character.agenticEnabled) {
        continue;
      }
      characters.add(character);
    }
    // Resolve candidates concurrently so one revoked or unavailable Keychain
    // entry cannot make a group of otherwise valid members wait N×timeout
    // before the system reminder is persisted.
    final checks = await Future.wait(
      characters.map((character) async {
        final config = _resolveApiConfig(character);
        if (config == null || !config.hasCredential) return false;
        try {
          final key =
              await credentials.resolve(config).timeout(credentialTimeout);
          return key != null && key.trim().isNotEmpty;
        } on Object {
          // A stale/revoked credential must produce a system reminder rather
          // than a message that falsely speaks for an unavailable role.
          return false;
        }
      }),
    );
    for (var index = 0; index < checks.length; index++) {
      if (checks[index]) return characters[index];
    }
    return null;
  }

  ApiConfig? _resolveApiConfig(AICharacter character) {
    final configuredId = character.apiConfigId.trim();
    if (configuredId.isNotEmpty) {
      final configured = database.apiConfigBox.get(configuredId);
      if (configured != null) return configured;
    }
    // Older character records may not have apiConfigId even though their
    // provider/model pair still maps to a saved configuration. Match the
    // same fallback used by the discussion and execution runners so a valid
    // role reminder is not downgraded to a system notice solely because the
    // record predates the binding field.
    for (final config in database.apiConfigBox.values) {
      if (config.provider == character.apiProvider &&
          config.modelName == character.modelName) {
        return config;
      }
    }
    return null;
  }

  String? _designatedExecutor(AgentTask task) {
    final discussion = _discussionExecutor(task);
    if (discussion != null) return discussion;
    final raw = task.executionStateJson.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final state = decoded is Map ? decoded['discussionState'] : null;
        final contract = state is Map ? state['deliverableContract'] : null;
        final explicit = contract is Map
            ? contract['explicitExecutorId']
            : decoded is Map
                ? decoded['explicitExecutorId']
                : null;
        if (explicit is String && explicit.trim().isNotEmpty) {
          return explicit.trim();
        }
      } on Object {
        // A malformed extension cannot designate a sender. The system
        // fallback below is safer than guessing from stale task fields.
      }
    }
    final taskCharacter = task.characterId.trim();
    return taskCharacter.isEmpty ? null : taskCharacter;
  }

  String? _discussionExecutor(AgentTask task) {
    final raw = task.executionStateJson.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      final discussion = decoded is Map ? decoded['discussionState'] : null;
      final value = discussion is Map ? discussion['executorId'] : null;
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    } on Object {
      return null;
    }
  }

  String _contentFor(
    WorkTaskUserAction action,
    AgentTask task, {
    required String ownerName,
    required ChatGroup? group,
    required AICharacter? sender,
  }) {
    final mention = '@${ownerName.trim().isEmpty ? '我' : ownerName.trim()}';
    final prefix = sender == null ? '系统任务提醒' : '工作任务提醒';
    final taskName = _conversationLabel(task, group);
    final reason = switch (action.kind) {
      WorkTaskUserActionKind.addMember => '任务需要符合目标职业能力的群成员，当前角色资格或执行人仍未确认。',
      WorkTaskUserActionKind.answerQuestion => '任务还缺少必要信息或需要你回答讨论问题。',
      WorkTaskUserActionKind.installTool => '继续任务前需要安装一个可信的缺失工具。',
      WorkTaskUserActionKind.authorizeFolder => '继续任务前需要授权工作目录。',
      WorkTaskUserActionKind.approveCommand => '任务准备执行一项需要你确认的命令操作。',
      WorkTaskUserActionKind.openTask => '任务在等待你的处理。',
    };
    return '$mention $prefix：$taskName $reason '
        '请点击“${action.label}”打开对应任务（${task.id.substring(0, _shortIdLength(task.id))}）。';
  }

  /// 私聊没有群名，必须说「当前对话」而不是「当前群聊」，否则提醒看起来像是
  /// 从另一个会话飘过来的。私聊本身不写入 chat_groups，所以还要看任务自己的
  /// 会话标识。
  String _conversationLabel(AgentTask task, ChatGroup? group) {
    final name = group?.name.trim() ?? '';
    if (name.isNotEmpty) return '「$name」';
    final conversationId = group?.id.trim().isNotEmpty == true
        ? group!.id.trim()
        : task.groupId.trim();
    if (DirectChatSession.isDirectConversationId(conversationId)) {
      return '当前对话';
    }
    return '当前群聊';
  }

  int _shortIdLength(String id) => id.length < 8 ? id.length : 8;
}
