import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/memory_governance_store.dart';

Map<String, dynamic> responseFor(ApiProtocol protocol, {bool usage = true}) {
  return switch (protocol) {
    ApiProtocol.openAiChatCompletions => {
        'choices': [
          {
            'message': {'content': 'OK'}
          }
        ],
        if (usage)
          'usage': {
            'prompt_tokens': 100, 'completion_tokens': 20,
            'prompt_tokens_details': {
              'cached_tokens': 40,
              'cache_write_tokens': 15
            },
            'cached_tokens': 40, // An alias, not another 40 tokens.
            'completion_tokens_details': {'reasoning_tokens': 5},
          },
      },
    ApiProtocol.openAiResponses => {
        'output_text': 'OK',
        if (usage)
          'usage': {
            'input_tokens': 100,
            'output_tokens': 20,
            'input_tokens_details': {
              'cached_tokens': 40,
              'cache_write_tokens': 15
            },
            'output_tokens_details': {'reasoning_tokens': 5},
          },
      },
    ApiProtocol.anthropicMessages => {
        'content': [
          {'type': 'text', 'text': 'OK'}
        ],
        if (usage)
          'usage': {
            'input_tokens': 45,
            'output_tokens': 20,
            'cache_read_input_tokens': 40,
            'cache_creation_input_tokens': 15,
          },
      },
    ApiProtocol.geminiGenerateContent => {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'OK'}
              ]
            }
          }
        ],
        if (usage)
          'usageMetadata': {
            'promptTokenCount': 95,
            'toolUsePromptTokenCount': 5,
            'candidatesTokenCount': 15,
            'thoughtsTokenCount': 5,
            'totalTokenCount': 120,
            'cachedContentTokenCount': 40,
          },
      },
  };
}

String streamFor(ApiProtocol protocol, Map<String, dynamic> response) {
  final usage = response['usage'];
  final frames = switch (protocol) {
    ApiProtocol.openAiChatCompletions => [
        {
          'choices': [
            {
              'delta': {'content': 'OK'},
              'finish_reason': 'stop'
            }
          ]
        },
        if (usage != null) {'choices': [], 'usage': usage},
      ],
    ApiProtocol.openAiResponses => [
        {'type': 'response.completed', 'response': response},
      ],
    ApiProtocol.anthropicMessages => [
        {
          'type': 'message_start',
          'message': {if (usage != null) 'usage': usage}
        },
        {
          'type': 'content_block_delta',
          'delta': {'text': 'OK'}
        },
        if (usage != null)
          {
            'type': 'message_delta',
            'usage': {'output_tokens': 20}
          },
        {'type': 'message_stop'},
      ],
    ApiProtocol.geminiGenerateContent => [response],
  };
  return '${frames.map((frame) => 'data: ${jsonEncode(frame)}\n\n').join()}data: [DONE]\n\n';
}

void main() {
  for (final protocol in ApiProtocol.values) {
    for (final streaming in [false, true]) {
      for (final hasUsage in [false, true]) {
        test('$protocol streaming=$streaming reported=$hasUsage', () async {
          final store = MemoryGovernanceStore();
          final response = responseFor(protocol, usage: hasUsage);
          final dio = Dio()
            ..interceptors
                .add(InterceptorsWrapper(onRequest: (options, handler) {
              expect(options.followRedirects, isFalse);
              handler.resolve(Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: streaming
                      ? ResponseBody.fromString(
                          streamFor(protocol, response), 200)
                      : response));
            }));
          addTearDown(dio.close);
          final gateway =
              AiRequestGateway(store: store, client: ChatApiService(dio: dio));
          final send = streaming
              ? gateway.sendChatMessageStreamed
              : gateway.sendChatMessage;
          final result = await send(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            apiProtocol: protocol,
            customBaseUrl: 'https://example.test/v1',
            model: 'test-model',
            messages: [
              {'role': 'user', 'content': 'hello'}
            ],
            purpose: AiRequestPurpose.agent,
            taskId: 'task',
            conversationId: 'room',
            characterId: 'actor',
            maxRetries: 0,
          );
          expect(result['success'], isTrue);
          final entry = store.ledgerEntries.single;
          final reported = entry.reportedUsage!;
          expect(entry.exactUsage, hasUsage);
          expect(reported.inputTokens, hasUsage ? 100 : null);
          expect(reported.outputTokens, hasUsage ? 20 : null);
          expect(reported.cachedTokens, hasUsage ? 40 : null);
          expect(
              reported.cacheWriteTokens,
              hasUsage && protocol != ApiProtocol.geminiGenerateContent
                  ? 15
                  : null);
          expect(reported.valid, isTrue);
          expect(UsageLedgerEntry.fromMap(entry.toMap()).reportedUsage!.toMap(),
              reported.toMap());
          expect(
              AiRequestDiagnostic.fromMap(store.diagnostics.single.toMap())
                  .reportedUsage!
                  .toMap(),
              reported.toMap());
        });
      }
    }
  }

  for (final protocol in ApiProtocol.values) {
    test('cache opt-in is scoped to $protocol and leaves text intact',
        () async {
      final bodies = <Map>[];
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          bodies.add(options.data as Map);
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: responseFor(protocol)));
        }));
      addTearDown(dio.close);
      final client = ChatApiService(dio: dio);
      const content =
          'fixed rules\n${AgentPromptBuilder.dynamicContextMarker}\noriginal request';
      for (final enabled in [false, true]) {
        await client.sendChatMessage(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          apiProtocol: protocol,
          customBaseUrl: 'https://example.test/v1',
          model: 'test-model',
          messages: [
            {'role': 'system', 'content': content},
            {'role': 'user', 'content': 'original request'}
          ],
          promptCacheKey: enabled ? 'stable-key' : null,
          maxRetries: 0,
        );
      }
      expect(bodies.first.containsKey('prompt_cache_key'), isFalse);
      if (protocol == ApiProtocol.anthropicMessages) {
        expect(bodies.first['system'], content);
        final blocks = bodies.last['system'] as List;
        expect(blocks.map((e) => e['text']).join(), content);
        expect(blocks.first['cache_control'], {'type': 'ephemeral'});
        expect(blocks.last.containsKey('cache_control'), isFalse);
      } else if (protocol != ApiProtocol.geminiGenerateContent) {
        expect(bodies.last['prompt_cache_key'], 'stable-key');
      } else {
        expect(bodies.last.containsKey('prompt_cache_key'), isFalse);
      }
    });
  }

  test(
      'work stream drains trailing usage but does not wait for connection close',
      () async {
    final response = responseFor(ApiProtocol.openAiChatCompletions);
    final controller = StreamController<List<int>>();
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data:
                ResponseBody(controller.stream.map(Uint8List.fromList), 200)));
        controller.add(utf8.encode(
            'data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}\n\n'));
        controller.add(utf8.encode('data: ${jsonEncode({
              'choices': [],
              'usage': response['usage']
            })}\n\n'));
      }));
    addTearDown(dio.close);
    final events = await ChatApiService(dio: dio)
        .streamChatMessage(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          model: 'test-model',
          customBaseUrl: 'https://example.test/v1',
          messages: [
            {'role': 'user', 'content': 'hello'}
          ],
          finishOnTerminalFrame: true,
        )
        .toList()
        .timeout(const Duration(seconds: 2));
    expect(events.last.promptTokens, 100);
    expect(events.last.cachedTokens, 40);
    await controller.close();
  });

  test('cache key is stable and isolated by API configuration and actor', () {
    final config = ApiConfig(id: 'one', name: 'one', provider: 'custom');
    expect(config.workPromptCacheKey('actor'), isNull);
    config.enableWorkPromptCaching = true;
    final key = config.workPromptCacheKey('actor');
    expect(key, config.workPromptCacheKey('actor'));
    expect(key!.length, 64);
    expect(key, isNot(config.workPromptCacheKey('another')));
    config.id = 'two';
    expect(key, isNot(config.workPromptCacheKey('actor')));
  });
  test(
      'cache option survives backup without credentials and old backups stay off',
      () {
    final config = ApiConfig(
        name: 'relay',
        provider: 'custom',
        enableWorkPromptCaching: true,
        apiKey: 'never-export');
    final encoded = BackupEntityCodec.apiConfig(config);
    expect(encoded['enableWorkPromptCaching'], isTrue);
    expect(jsonEncode(encoded), isNot(contains('never-export')));
    expect(BackupEntityCodec.decodeApiConfig(encoded).enableWorkPromptCaching,
        isTrue);
    encoded.remove('enableWorkPromptCaching');
    expect(BackupEntityCodec.decodeApiConfig(encoded).enableWorkPromptCaching,
        isFalse);
  });

  test('task changes preserve fixed prefix and original user request', () {
    String prompt(String context, String request) =>
        AgentPromptBuilder.buildAgentDecisionPrompt(
            rolePlaySystemPrompt: 'role',
            skills: [],
            userRequest: request,
            workModeContext: context);
    final before = prompt('step one', 'original request');
    final after = prompt('step two', 'revised request');
    expect(before.split(AgentPromptBuilder.dynamicContextMarker).first,
        after.split(AgentPromptBuilder.dynamicContextMarker).first);
    expect(before, contains('original request'));
    expect(after, contains('revised request'));
  });

  test('empty SSE and nonstream fallback are separate accounting attempts',
      () async {
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        calls++;
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: calls == 1
                ? ResponseBody.fromString('data: [DONE]\n\n', 200)
                : responseFor(ApiProtocol.openAiChatCompletions)));
      }));
    addTearDown(dio.close);
    final store = MemoryGovernanceStore();
    final gateway =
        AiRequestGateway(store: store, client: ChatApiService(dio: dio));
    final result = await gateway.sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      model: 'test-model',
      customBaseUrl: 'https://example.test/v1',
      messages: [
        {'role': 'user', 'content': 'hello'}
      ],
      purpose: AiRequestPurpose.agent,
      conversationId: 'room',
      characterId: 'actor',
      taskId: 'task',
      maxRetries: 0,
    );
    expect(result['success'], isTrue);
    expect(calls, 2);
    expect(store.diagnostics.length, 2);
    expect(store.ledgerEntries.length, 2);
    expect(store.ledgerEntries.first.reportedUsage!.hasValues, isFalse);
    expect(store.diagnostics.first.reportedUsage!.hasValues, isFalse);
    expect(store.diagnostics.last.reportedUsage!.inputTokens, 100);
    expect(store.diagnostics.map((e) => e.requestId).toSet().length, 2);
  });

  test('failed Responses stream preserves reported consumption', () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: ResponseBody.fromString(
                'data: ${jsonEncode({
                      'type': 'response.incomplete',
                      'response': {
                        'usage': {
                          'input_tokens': 100,
                          'output_tokens': 20,
                          'input_tokens_details': {'cached_tokens': 40},
                        }
                      },
                    })}\n\n',
                200)));
      }));
    addTearDown(dio.close);
    final store = MemoryGovernanceStore();
    final gateway =
        AiRequestGateway(store: store, client: ChatApiService(dio: dio));
    final result = await gateway.sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiResponses,
      customBaseUrl: 'https://example.test/v1',
      model: 'test-model',
      messages: [
        {'role': 'user', 'content': 'hello'}
      ],
      purpose: AiRequestPurpose.agent,
      conversationId: 'room',
      characterId: 'actor',
      taskId: 'task',
      maxRetries: 0,
    );
    expect(result['success'], isFalse);
    expect(store.ledgerEntries.single.status, 'failed');
    expect(store.ledgerEntries.single.reportedUsage!.inputTokens, 100);
    expect(store.ledgerEntries.single.reportedUsage!.cachedTokens, 40);
  });

  test('unsupported caching returns once without a plain duplicate request',
      () async {
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        calls++;
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 400,
            data: ResponseBody.fromString(
                '{"error":{"message":"unsupported parameter"}}', 400)));
      }));
    addTearDown(dio.close);
    final gateway = AiRequestGateway(
        store: MemoryGovernanceStore(), client: ChatApiService(dio: dio));
    final result = await gateway.sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://example.test/v1',
      model: 'test-model',
      messages: [
        {'role': 'user', 'content': 'hello'}
      ],
      purpose: AiRequestPurpose.agent,
      conversationId: 'room',
      characterId: 'actor',
      taskId: 'task',
      requiresTools: true,
      promptCacheKey: 'stable-key',
      maxRetries: 0,
    );
    expect(result['success'], isFalse);
    expect(calls, 1);
  });
  test('Anthropic missing cache counters cannot claim a complete total input',
      () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'content': [
            {'type': 'text', 'text': 'OK'}
          ],
          'usage': {'input_tokens': 50, 'output_tokens': 20},
        }));
      }));
    addTearDown(dio.close);
    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.anthropicMessages,
      model: 'test-model',
      customBaseUrl: 'https://example.test/v1',
      messages: [],
      maxRetries: 0,
    );
    expect(result['promptTokens'], isNull);
    expect(result['uncachedInputTokens'], 50);
    expect(result['cachedTokens'], isNull);
    expect(result['completionTokens'], 20);
  });

  test(
      'cancelled Anthropic output keeps known input but not initial output snapshot',
      () async {
    final wire = StreamController<Uint8List>();
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: ResponseBody(wire.stream, 200)));
        wire.add(Uint8List.fromList(utf8.encode('data: ${jsonEncode({
              'type': 'message_start',
              'message': {
                'usage': {
                  'input_tokens': 50,
                  'cache_read_input_tokens': 40,
                  'cache_creation_input_tokens': 10,
                  'output_tokens': 1,
                }
              },
            })}\n\n')));
      }));
    addTearDown(dio.close);
    final store = MemoryGovernanceStore();
    final gateway =
        AiRequestGateway(store: store, client: ChatApiService(dio: dio));
    await gateway
        .streamChatMessage(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          apiProtocol: ApiProtocol.anthropicMessages,
          model: 'test-model',
          customBaseUrl: 'https://example.test/v1',
          messages: [],
          purpose: AiRequestPurpose.agent,
          conversationId: 'room',
          characterId: 'actor',
          taskId: 'task',
        )
        .take(1)
        .drain<void>();
    await wire.close();
    final entry = store.ledgerEntries.single;
    expect(entry.status, 'cancelled');
    expect(entry.reportedUsage!.inputTokens, 100);
    expect(entry.reportedUsage!.outputTokens, isNull);
    expect(entry.exactUsage, isFalse);
  });
}
