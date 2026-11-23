import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;

import 'othello_move_parser.dart';
import 'othello_types.dart';

const Duration othelloModelRequestTimeout = Duration(seconds: 18);
const Duration othelloModelTurnTimeout = Duration(seconds: 37);
const int othelloFallbackMaxTokens = 1024;

typedef OthelloBudgetResolver = int Function(
    ApiProvider provider, String model);

enum OthelloModelFailure {
  unavailable,
  request,
  empty,
  format,
  illegalMove,
  cancelled,
}

class OthelloModelDecision {
  const OthelloModelDecision._({
    required this.move,
    required this.reason,
    required this.failure,
    required this.attempts,
  });

  factory OthelloModelDecision.success({
    required OthelloMove move,
    required String reason,
    required int attempts,
  }) =>
      OthelloModelDecision._(
        move: move,
        reason: reason,
        failure: null,
        attempts: attempts,
      );

  factory OthelloModelDecision.failed(
    OthelloModelFailure failure, {
    required int attempts,
  }) =>
      OthelloModelDecision._(
        move: null,
        reason: '',
        failure: failure,
        attempts: attempts,
      );

  final OthelloMove? move;
  final String reason;
  final OthelloModelFailure? failure;
  final int attempts;

  bool get isSuccess => move != null && failure == null;
  bool get wasCancelled => failure == OthelloModelFailure.cancelled;
}

/// Role-backed move selection. A legal model choice is returned immediately;
/// Hard fallback is owned by [CharacterOthelloPlayer] and runs only on failure.
class AiOthelloPlayer {
  AiOthelloPlayer({
    required this.character,
    required this.config,
    ChatApiService? api,
    ApiCredentialResolver? credentials,
    OthelloBudgetResolver? budgetResolver,
    this.requestTimeout = othelloModelRequestTimeout,
    this.turnTimeout = othelloModelTurnTimeout,
  })  : _api = api ?? ChatApiService(),
        _credentials = credentials ?? SecureApiCredentialResolver(),
        _budgetResolver =
            budgetResolver ?? ((_, __) => othelloFallbackMaxTokens);

  final AICharacter character;
  final ApiConfig? config;
  final ChatApiService _api;
  final ApiCredentialResolver _credentials;
  final OthelloBudgetResolver _budgetResolver;
  final Duration requestTimeout;
  final Duration turnTimeout;

  static const int _maxRetries = 1;
  static const int _retryDelayMs = 300;

  /// Tactical instructions supplement the character persona, matching the
  /// user-provided Othello strategy text.
  static const String tacticalPrompt = '''
你正在以指定颜色参加一局标准黑白棋。目标是赢得终局。只能从本回合给出的合法坐标中选一个。

先比较主要候选，并估计对手最强回应及自己下一步。开局和中盘优先考虑控制对手的合法着法、保留自己的选择、争取角和稳定子。角仍为空时，谨慎走与它相邻的 X 格和 C 格，先检查是否会让对手拿角。避免只因本步翻子多就选择它。

残局根据剩余空格、行动顺序、可迫使对手跳过的局面和最终棋子数选走法。能判断终局时，以胜负为先。若只有一步合法动作，直接选它。

只返回一个 JSON 对象。move 是合法列表中的坐标，reason 是一句简短、公开、与本步相关的中文战术说明。不要输出额外文本、多个候选或详细推理过程。''';

  Future<OthelloModelDecision> decideMove({
    required OthelloBoard board,
    required OthelloSide mySide,
    required List<OthelloValidMove> legalMoves,
    CancelToken? cancelToken,
  }) async {
    final turnStopwatch = Stopwatch()..start();
    if (legalMoves.isEmpty) {
      return OthelloModelDecision.failed(
        OthelloModelFailure.illegalMove,
        attempts: 0,
      );
    }
    if (cancelToken?.isCancelled == true) {
      return OthelloModelDecision.failed(
        OthelloModelFailure.cancelled,
        attempts: 0,
      );
    }

    final currentConfig = config;
    if (currentConfig == null || !currentConfig.hasCredential) {
      return OthelloModelDecision.failed(
        OthelloModelFailure.unavailable,
        attempts: 0,
      );
    }

    final String? apiKey;
    try {
      final credentialResolution = _credentials.resolve(currentConfig);
      final pendingCredentials = <Future<String?>>[credentialResolution];
      if (cancelToken != null) {
        pendingCredentials.add(cancelToken.whenCancel.then((_) {
          throw const _OthelloRequestCancelled();
        }));
      }
      apiKey = await Future.any(pendingCredentials)
          .timeout(_remaining(turnStopwatch));
    } on Object {
      if (cancelToken?.isCancelled == true) {
        return OthelloModelDecision.failed(
          OthelloModelFailure.cancelled,
          attempts: 0,
        );
      }
      return OthelloModelDecision.failed(
        turnStopwatch.elapsed >= turnTimeout
            ? OthelloModelFailure.request
            : OthelloModelFailure.unavailable,
        attempts: 0,
      );
    }
    if (cancelToken?.isCancelled == true) {
      return OthelloModelDecision.failed(
        OthelloModelFailure.cancelled,
        attempts: 0,
      );
    }
    if (apiKey == null || apiKey.isEmpty) {
      return OthelloModelDecision.failed(
        OthelloModelFailure.unavailable,
        attempts: 0,
      );
    }

    final provider = ApiProvider.values.firstWhere(
      (candidate) => candidate.name == currentConfig.provider,
      orElse: () => ApiProvider.custom,
    );
    var lastFailure = OthelloModelFailure.request;
    var attemptsMade = 0;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (cancelToken?.isCancelled == true) {
        return OthelloModelDecision.failed(
          OthelloModelFailure.cancelled,
          attempts: attempt,
        );
      }
      final remaining = _remaining(turnStopwatch);
      if (remaining <= Duration.zero) {
        lastFailure = OthelloModelFailure.request;
        break;
      }
      attemptsMade++;
      final attemptTimeout =
          requestTimeout < remaining ? requestTimeout : remaining;
      final requestCancelToken = CancelToken();
      if (cancelToken != null) {
        unawaited(cancelToken.whenCancel.then((_) {
          if (!requestCancelToken.isCancelled) {
            requestCancelToken.cancel('Othello parent turn cancelled');
          }
        }));
      }
      final Map<String, dynamic> response;
      try {
        final request = _api.sendChatMessage(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: currentConfig.protocol,
          customBaseUrl: currentConfig.customBaseUrl,
          userAgent: currentConfig.userAgentOverride,
          model: currentConfig.modelName,
          messages: _buildMessages(
            board,
            mySide,
            legalMoves,
            compact: attempt > 0,
          ),
          temperature: 0,
          maxTokens: _budgetResolver(provider, currentConfig.modelName),
          receiveTimeout: attemptTimeout,
          maxRetries: 0,
          cancelToken: requestCancelToken,
          // 与五子棋一致：部分推理模型只在 reasoning_content 返回内容。
          allowReasoningContentFallback: true,
        );
        final pending = <Future<Map<String, dynamic>>>[request];
        if (cancelToken != null) {
          pending.add(cancelToken.whenCancel.then((_) {
            throw const _OthelloRequestCancelled();
          }));
        }
        response = await Future.any(pending).timeout(
          attemptTimeout,
          onTimeout: () {
            requestCancelToken.cancel('Othello model turn timed out');
            throw TimeoutException('Othello model turn timed out');
          },
        );
      } on Object {
        if (cancelToken?.isCancelled == true) {
          return OthelloModelDecision.failed(
            OthelloModelFailure.cancelled,
            attempts: attempt + 1,
          );
        }
        lastFailure = OthelloModelFailure.request;
        await _waitBeforeRetry(attempt, turnStopwatch, cancelToken);
        continue;
      }

      if (cancelToken?.isCancelled == true) {
        return OthelloModelDecision.failed(
          OthelloModelFailure.cancelled,
          attempts: attempt + 1,
        );
      }
      if (response['success'] != true) {
        final message = response['message']?.toString().trim() ?? '';
        lastFailure =
            message.isEmpty || response['failureCode'] == 'emptyResponse'
                ? OthelloModelFailure.empty
                : OthelloModelFailure.request;
        if (attempt < _maxRetries) {
          await _waitBeforeRetry(attempt, turnStopwatch, cancelToken);
        }
        continue;
      }

      final content = response['message']?.toString() ?? '';
      final parsed = OthelloMoveParser.parse(content);
      if (parsed == null) {
        lastFailure = content.trim().isEmpty
            ? OthelloModelFailure.empty
            : OthelloModelFailure.format;
        continue;
      }
      if (!legalMoves.any((candidate) => candidate.move == parsed.move)) {
        lastFailure = OthelloModelFailure.illegalMove;
        continue;
      }
      return OthelloModelDecision.success(
        move: parsed.move,
        reason: parsed.reason,
        attempts: attempt + 1,
      );
    }

    return OthelloModelDecision.failed(
      lastFailure,
      attempts: attemptsMade,
    );
  }

  Duration _remaining(Stopwatch stopwatch) {
    final remaining = turnTimeout - stopwatch.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  Future<void> _waitBeforeRetry(
    int attempt,
    Stopwatch stopwatch,
    CancelToken? cancelToken,
  ) async {
    if (attempt < _maxRetries) {
      final remaining = _remaining(stopwatch);
      if (remaining <= Duration.zero) return;
      final delay = Duration(milliseconds: _retryDelayMs * (attempt + 1));
      final waits = <Future<void>>[
        Future<void>.delayed(delay < remaining ? delay : remaining),
      ];
      if (cancelToken != null) {
        waits.add(cancelToken.whenCancel.then<void>((_) {}));
      }
      await Future.any(waits);
    }
  }

  List<Map<String, dynamic>> _buildMessages(
      OthelloBoard board, OthelloSide mySide, List<OthelloValidMove> legalMoves,
      {bool compact = false}) {
    final columnLabels = List.generate(
      othelloBoardSize,
      (col) => String.fromCharCode(65 + col),
    ).join(' ');
    final rows = <String>[
      compact ? columnLabels : '    $columnLabels',
      for (var row = 0; row < othelloBoardSize; row++)
        compact
            ? '${row + 1} ${board[row].map(_cellLabel).join()} '
            : '${(row + 1).toString().padLeft(2)}  ${board[row].map(_cellLabel).join(' ')}',
    ];
    final legalCoordinates =
        legalMoves.map((candidate) => candidate.move.toCoordinate()).join(', ');
    return [
      {
        'role': 'system',
        'content': [
          character.rolePlaySystemPrompt,
          tacticalPrompt,
        ].where((part) => part.trim().isNotEmpty).join('\n\n'),
      },
      {
        'role': 'user',
        'content': compact
            ? [
                '${mySide.shortLabel}。A–H 从左到右，1–8 从上到下。B 黑，W 白，. 空。',
                ...rows,
                '合法落点：$legalCoordinates',
                '只返回 JSON：{"move":"C4","reason":"简短战术说明"}',
              ].join('\n')
            : [
                '你执${mySide.label}（${mySide.shortLabel}），本回合必须落子。',
                '坐标说明：列为 A–H，行从上到下为 1–8；例如 A1 是左上角，H8 是右下角。',
                '当前完整棋盘（B=黑，W=白，.=空）：',
                ...rows,
                '全部合法落点：$legalCoordinates',
                '只按要求返回 JSON，例如：{"move":"C4","reason":"争取角位并限制对手选择。"}',
              ].join('\n'),
      },
    ];
  }

  String _cellLabel(int? value) => switch (value) {
        othelloBlackValue => 'B',
        othelloWhiteValue => 'W',
        _ => '.',
      };
}

class _OthelloRequestCancelled implements Exception {
  const _OthelloRequestCancelled();
}
