import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/character_gender_inference.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';

/// Safe result of one remote inference phase.
class CharacterGenderLlmInferenceReport {
  final genders = <String, CharacterGender>{};
  final reasonCodes = <String>{};
  int batchCount = 0;
}

class _GroupInferenceResult {
  final Map<String, CharacterGender> genders;
  final String? reasonCode;

  const _GroupInferenceResult({
    this.genders = const {},
    this.reasonCode,
  });
}

class _InferenceBatch {
  final ApiConfig config;
  final List<AICharacter> characters;

  const _InferenceBatch(this.config, this.characters);
}

/// Coordinates credential resolution, grouped requests, and cancellation.
class CharacterGenderLlmInference {
  static const maxCharactersPerRequest = 4;
  static const maxConcurrentRequests = 2;
  static const apiRequestTimeout = Duration(seconds: 4);

  final ChatApiService api;
  final ApiCredentialResolver credentials;
  final Duration phaseTimeout;
  final _activeCancelTokens = <CancelToken>{};

  CharacterGenderLlmInference({
    required this.api,
    required this.credentials,
    required this.phaseTimeout,
  });

  void cancel() {
    for (final token in List<CancelToken>.of(_activeCancelTokens)) {
      if (!token.isCancelled) token.cancel();
    }
  }

  Future<CharacterGenderLlmInferenceReport> infer(
    List<AICharacter> characters,
    Map<String, List<String>> replies, {
    required Iterable<ApiConfig> configs,
    required Future<void>? cancellation,
    required bool Function() isCancelled,
  }) async {
    final report = CharacterGenderLlmInferenceReport();
    final stopwatch = Stopwatch()..start();
    if (isCancelled()) {
      report.reasonCodes.add('cancelled');
      return report;
    }
    final grouped = _groupCharactersByConfig(characters, configs, report);
    if (grouped.isEmpty) return report;

    final batches = _splitIntoBatches(grouped);
    report.batchCount = batches.length;
    final completedGroups = await _runBatches(
      batches,
      replies,
      cancellation,
      isCancelled,
      report,
      stopwatch,
    );
    if (isCancelled()) {
      report.reasonCodes.add('cancelled');
      return report;
    }
    for (final result in completedGroups) {
      report.genders.addAll(result.genders);
      if (result.reasonCode != null) report.reasonCodes.add(result.reasonCode!);
    }
    return report;
  }

  List<_InferenceBatch> _splitIntoBatches(
    Map<ApiConfig, List<AICharacter>> grouped,
  ) {
    final batches = <_InferenceBatch>[];
    for (final entry in grouped.entries) {
      for (var start = 0; start < entry.value.length;) {
        final end = start + maxCharactersPerRequest < entry.value.length
            ? start + maxCharactersPerRequest
            : entry.value.length;
        batches
            .add(_InferenceBatch(entry.key, entry.value.sublist(start, end)));
        start = end;
      }
    }
    return batches;
  }

  Map<ApiConfig, List<AICharacter>> _groupCharactersByConfig(
    List<AICharacter> characters,
    Iterable<ApiConfig> configs,
    CharacterGenderLlmInferenceReport report,
  ) {
    final configsById = {for (final config in configs) config.id: config};
    final grouped = <ApiConfig, List<AICharacter>>{};
    for (final character in characters) {
      final config = configsById[character.apiConfigId];
      if (config == null) {
        report.reasonCodes.add('missing_config');
        continue;
      }
      grouped.putIfAbsent(config, () => []).add(character);
    }
    return grouped;
  }

  Future<List<_GroupInferenceResult>> _runBatches(
    List<_InferenceBatch> batches,
    Map<String, List<String>> replies,
    Future<void>? cancellation,
    bool Function() isCancelled,
    CharacterGenderLlmInferenceReport report,
    Stopwatch stopwatch,
  ) async {
    final completedGroups = <_GroupInferenceResult>[];
    for (var start = 0; start < batches.length;) {
      if (isCancelled()) break;
      if (!_hasTimeRemaining(stopwatch)) {
        report.reasonCodes.add('timeout');
        break;
      }
      final end = start + maxConcurrentRequests < batches.length
          ? start + maxConcurrentRequests
          : batches.length;
      final completed = await _runBatchWave(
        batches.sublist(start, end),
        replies,
        cancellation,
        isCancelled,
        report,
        completedGroups,
        stopwatch,
      );
      if (!completed) break;
      start = end;
    }
    return completedGroups;
  }

  Future<bool> _runBatchWave(
    List<_InferenceBatch> batches,
    Map<String, List<String>> replies,
    Future<void>? cancellation,
    bool Function() isCancelled,
    CharacterGenderLlmInferenceReport report,
    List<_GroupInferenceResult> completedGroups,
    Stopwatch stopwatch,
  ) async {
    final requests = <Future<void>>[];
    for (final batch in batches) {
      final token = CancelToken();
      _activeCancelTokens.add(token);
      requests.add(
        _inferGroup(
          batch.config,
          batch.characters,
          replies,
          cancelToken: token,
          isCancelled: isCancelled,
        ).then<void>((result) {
          if (!isCancelled() && !token.isCancelled) {
            completedGroups.add(result);
          }
        }).whenComplete(() => _activeCancelTokens.remove(token)),
      );
    }
    final waitForRequests = Future.wait(requests).then<void>((_) {});
    try {
      await _waitForRequests(waitForRequests, cancellation, stopwatch);
    } on TimeoutException {
      report.reasonCodes.add('timeout');
      _cancelActiveRequests();
      return false;
    } on Object {
      // Each group converts its own failure to a safe reason code.
      report.reasonCodes.add('request_failed');
      _cancelActiveRequests();
      return false;
    }
    return true;
  }

  Future<void> _waitForRequests(
    Future<void> requests,
    Future<void>? cancellation,
    Stopwatch stopwatch,
  ) {
    final remaining = phaseTimeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('LLM inference phase timed out');
    }
    final wait = cancellation == null
        ? requests
        : Future.any<void>([
            requests,
            cancellation,
          ]);
    return wait.timeout(remaining);
  }

  bool _hasTimeRemaining(Stopwatch stopwatch) =>
      stopwatch.elapsed < phaseTimeout;

  Future<_GroupInferenceResult> _inferGroup(
    ApiConfig config,
    List<AICharacter> characters,
    Map<String, List<String>> replies, {
    required CancelToken cancelToken,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled() || cancelToken.isCancelled) {
      return const _GroupInferenceResult(reasonCode: 'cancelled');
    }
    if (!config.hasCredential) {
      return const _GroupInferenceResult(reasonCode: 'missing_credential');
    }
    try {
      final apiKey = await credentials.resolve(config);
      if (apiKey == null || apiKey.isEmpty) {
        return const _GroupInferenceResult(reasonCode: 'missing_credential');
      }
      if (isCancelled() || cancelToken.isCancelled) {
        return const _GroupInferenceResult(reasonCode: 'cancelled');
      }
      final result = await _requestGroupInference(
        config,
        characters,
        replies,
        apiKey,
        cancelToken,
      );
      if (isCancelled() || cancelToken.isCancelled) {
        return const _GroupInferenceResult(reasonCode: 'cancelled');
      }
      return _parseGroupResult(result, characters);
    } on Object {
      return const _GroupInferenceResult(reasonCode: 'request_failed');
    }
  }

  Future<Map<String, dynamic>> _requestGroupInference(
    ApiConfig config,
    List<AICharacter> characters,
    Map<String, List<String>> replies,
    String apiKey,
    CancelToken cancelToken,
  ) =>
      api.sendChatMessage(
        apiKey: apiKey,
        provider: ApiProvider.values.firstWhere(
          (provider) => provider.name == config.provider,
          orElse: () => ApiProvider.custom,
        ),
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        temperature: 0,
        maxTokens: 2048,
        maxRetries: 0,
        receiveTimeout: apiRequestTimeout,
        cancelToken: cancelToken,
        messages: [
          {
            'role': 'system',
            'content': '判断每个虚拟角色的性别，只允许男或女。综合名字、职业、人设和历史回复。'
                '只输出 JSON 数组，格式为 [{"id":"角色ID","gender":"男或女"}]。',
          },
          {
            'role': 'user',
            'content': jsonEncode(
              CharacterGenderInference.buildInferenceEntriesFromReplies(
                characters,
                replies,
              ),
            ),
          },
        ],
      );

  _GroupInferenceResult _parseGroupResult(
    Map<String, dynamic> result,
    List<AICharacter> characters,
  ) {
    if (result['success'] != true) {
      return const _GroupInferenceResult(reasonCode: 'request_failed');
    }
    final genders = CharacterGenderInference.parseLlmResult(
      result['message']?.toString() ?? '',
      knownCharacterIds: characters.map((character) => character.id).toSet(),
    );
    if (genders.isEmpty) {
      return const _GroupInferenceResult(reasonCode: 'empty_response');
    }
    return _GroupInferenceResult(
      genders: genders,
      reasonCode:
          genders.length == characters.length ? null : 'partial_response',
    );
  }

  void _cancelActiveRequests() {
    for (final token in List<CancelToken>.of(_activeCancelTokens)) {
      if (!token.isCancelled) token.cancel();
    }
  }
}
