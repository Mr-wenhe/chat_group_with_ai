import 'package:chat_group/features/agentic/tool_request.dart';

/// The only actions understood by the Stage 03 work-mode protocol.
enum AgentDecisionAction {
  plan('plan'),
  tool('tool'),
  clarify('clarify'),
  handoff('handoff'),
  finish('finish');

  final String wireName;

  const AgentDecisionAction(this.wireName);

  static AgentDecisionAction? fromWire(Object? value) {
    if (value is! String) return null;
    for (final action in values) {
      if (action.wireName == value) return action;
    }
    return null;
  }
}

/// The small public error vocabulary exposed to the future AgentLoop.
enum AgentDecisionParseFailure {
  emptyResponse('emptyResponse'),
  modelProtocol('modelProtocol');

  final String wireName;

  const AgentDecisionParseFailure(this.wireName);
}

/// A validated tool call. The argument payload intentionally remains a map so
/// the registry can evolve without adding a new Dart class for every tool.
class AgentToolCall {
  final AgentToolName name;
  final Map<String, dynamic> arguments;

  const AgentToolCall({required this.name, required this.arguments});

  Map<String, dynamic> toJson() => {
        'name': name.wireName,
        'arguments': arguments,
      };
}

/// Action-specific completion payloads. They are kept separate from the
/// public update so UI text can never be mistaken for a private protocol field.
sealed class AgentCompletionPayload {
  const AgentCompletionPayload();

  Map<String, dynamic> toJson();
}

class AgentPlanCompletion extends AgentCompletionPayload {
  final List<String> steps;

  const AgentPlanCompletion({required this.steps});

  @override
  Map<String, dynamic> toJson() => {'steps': steps};
}

class AgentClarifyCompletion extends AgentCompletionPayload {
  final String question;
  final List<String> options;

  const AgentClarifyCompletion({
    required this.question,
    this.options = const [],
  });

  @override
  Map<String, dynamic> toJson() => {
        'question': question,
        'options': options,
      };
}

class AgentHandoffCompletion extends AgentCompletionPayload {
  final String target;
  final String summary;

  const AgentHandoffCompletion({
    required this.target,
    required this.summary,
  });

  @override
  Map<String, dynamic> toJson() => {
        'target': target,
        'summary': summary,
      };
}

class AgentFinishCompletion extends AgentCompletionPayload {
  final String summary;
  final List<String> evidence;

  const AgentFinishCompletion({
    required this.summary,
    this.evidence = const [],
  });

  @override
  Map<String, dynamic> toJson() => {
        'summary': summary,
        'evidence': evidence,
      };
}

/// Base type for every parsed decision. The strict parser is the production
/// boundary for the single Stage 03 work-mode loop.
sealed class AgentDecision {
  final AgentDecisionAction action;
  final String publicUpdate;

  const AgentDecision({
    required this.action,
    required this.publicUpdate,
  });

  Map<String, dynamic> toJson();
}

class AgentPlanDecision extends AgentDecision {
  final AgentPlanCompletion completion;

  const AgentPlanDecision({
    required super.publicUpdate,
    required this.completion,
  }) : super(action: AgentDecisionAction.plan);

  @override
  Map<String, dynamic> toJson() => {
        'action': action.wireName,
        'public_update': publicUpdate,
        'tool': null,
        'completion': completion.toJson(),
      };
}

class AgentToolDecision extends AgentDecision {
  final AgentToolCall tool;

  const AgentToolDecision({
    required super.publicUpdate,
    required this.tool,
  }) : super(action: AgentDecisionAction.tool);

  @override
  Map<String, dynamic> toJson() => {
        'action': action.wireName,
        'public_update': publicUpdate,
        'tool': tool.toJson(),
        'completion': null,
      };
}

class AgentClarifyDecision extends AgentDecision {
  final AgentClarifyCompletion completion;

  const AgentClarifyDecision({
    required super.publicUpdate,
    required this.completion,
  }) : super(action: AgentDecisionAction.clarify);

  @override
  Map<String, dynamic> toJson() => {
        'action': action.wireName,
        'public_update': publicUpdate,
        'tool': null,
        'completion': completion.toJson(),
      };
}

class AgentHandoffDecision extends AgentDecision {
  final AgentHandoffCompletion completion;

  const AgentHandoffDecision({
    required super.publicUpdate,
    required this.completion,
  }) : super(action: AgentDecisionAction.handoff);

  @override
  Map<String, dynamic> toJson() => {
        'action': action.wireName,
        'public_update': publicUpdate,
        'tool': null,
        'completion': completion.toJson(),
      };
}

class AgentFinishDecision extends AgentDecision {
  final AgentFinishCompletion completion;

  const AgentFinishDecision({
    required super.publicUpdate,
    required this.completion,
  }) : super(action: AgentDecisionAction.finish);

  @override
  Map<String, dynamic> toJson() => {
        'action': action.wireName,
        'public_update': publicUpdate,
        'tool': null,
        'completion': completion.toJson(),
      };
}
