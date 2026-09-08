import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:chat_group/features/web_search/application/search_coordinator.dart';
import 'package:chat_group/features/web_search/application/search_turn_context.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

void main() {
  test('reply message preserves its search snapshot for restart recovery', () {
    final dynamic snapshot = WebSearchSnapshot(
      requestId: 'request-1',
      rootRequestId: 'user-message-1',
      executedQueries: const ['Flutter latest release'],
      searchedAt: DateTime.utc(2026, 8, 24),
      provider: 'Brave',
      results: [
        WebSearchResult(
          sourceId: 'S1',
          title: 'Flutter release notes',
          snippet: 'Official notes',
          url: Uri.parse('https://docs.flutter.dev/release/notes'),
          provider: 'Brave',
        ),
      ],
    );
    final dynamic message = Message(
      id: 'ai-message-1',
      groupId: 'group-1',
      senderId: 'character-1',
      senderType: 'ai',
      content: 'See [S1].',
    );

    message.webSearchSnapshot = snapshot.toMap();
    final encoded = BackupEntityCodec.message(message, const []);
    final decoded = BackupEntityCodec.decodeMessage(encoded, (_) => '');
    final restored = WebSearchSnapshot.fromMap(
      Map<dynamic, dynamic>.from(decoded.webSearchSnapshot as Map),
    );

    expect(restored?.rootRequestId, 'user-message-1');
    expect(restored?.results.single.url,
        Uri.parse('https://docs.flutter.dev/release/notes'));
  });

  test('one user turn shares one snapshot across two AI replies', () async {
    final provider = _CountingProvider();
    final coordinator = _coordinator(provider);
    final controller = SearchTurnContextController(coordinator: coordinator);

    final turn = await controller.prepareUserTurn(
      conversationId: 'group-1',
      sourceMessageId: 'user-message-1',
      turnId: 'user-message-1',
      userMessage: 'search the web for the latest Flutter release',
      requestConsent: (_) async => true,
    );
    controller.bindReply('ai-message-1', turn);
    controller.bindReply('ai-message-2', turn);

    expect(provider.searchCount, 1);
    expect(provider.requests.single.sourceMessageId, 'user-message-1');
    expect(turn.snapshot?.rootRequestId, 'user-message-1');
    expect(controller.contextForReply('ai-message-1')?.snapshot,
        same(turn.snapshot));
    expect(controller.contextForReply('ai-message-2')?.snapshot,
        same(turn.snapshot));
  });

  test('group and DM turns use their own stable source message IDs', () async {
    final provider = _CountingProvider();
    final controller = SearchTurnContextController(
      coordinator: _coordinator(provider),
    );

    await controller.prepareUserTurn(
      conversationId: 'group-1',
      sourceMessageId: 'group-user-message',
      turnId: 'group-user-message',
      userMessage: '查一下 Flutter 最新版本',
      requestConsent: (_) async => true,
    );
    await controller.prepareUserTurn(
      conversationId: 'dm:character-1',
      sourceMessageId: 'dm-user-message',
      turnId: 'dm-user-message',
      userMessage: '查一下 Dart 当前版本',
      requestConsent: (_) async => true,
    );

    expect(
      provider.requests.map((request) => request.sourceMessageId),
      ['group-user-message', 'dm-user-message'],
    );
  });

  test('group and DM policies are evaluated independently at turn preparation',
      () async {
    final provider = _CountingProvider();
    final store =
        MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto)
          ..conversationPolicies['dm:character-1'] = WebSearchPolicy.off;
    final controller = SearchTurnContextController(
      coordinator: SearchCoordinator(
        store: store,
        routes: [SearchProviderRoute(provider: provider)],
      ),
    );

    final group = await controller.prepareUserTurn(
      conversationId: 'group-1',
      sourceMessageId: 'group-user-message',
      turnId: 'group-user-message',
      userMessage: '查一下 Flutter 最新版本',
      requestConsent: (_) async => true,
    );
    final dm = await controller.prepareUserTurn(
      conversationId: 'dm:character-1',
      sourceMessageId: 'dm-user-message',
      turnId: 'dm-user-message',
      userMessage: '查一下 Dart 当前版本',
      requestConsent: (_) async => true,
    );

    expect(group.hasSnapshot, isTrue);
    expect(dm.snapshot, isNull);
    expect(provider.searchCount, 1);
  });

  test('regeneration reuses the snapshot unless explicitly refreshed',
      () async {
    final provider = _CountingProvider();
    final controller = SearchTurnContextController(
      coordinator: _coordinator(provider),
    );
    final turn = await controller.prepareUserTurn(
      conversationId: 'group-1',
      sourceMessageId: 'user-message-1',
      turnId: 'user-message-1',
      userMessage: 'search the web for the latest Flutter release',
      requestConsent: (_) async => true,
    );
    controller.bindReply('ai-message-1', turn);

    final reused = controller.contextForRegeneration('ai-message-1');
    expect(reused?.snapshot, same(turn.snapshot));
    expect(provider.searchCount, 1);

    final refreshed = await controller.refreshRegeneration(
      originalReplyId: 'ai-message-1',
      requestConsent: (_) async => true,
    );
    expect(provider.searchCount, 2);
    expect(refreshed?.snapshot, isNot(same(turn.snapshot)));
    expect(provider.requests.last.forceRefresh, isTrue);
  });

  test('source follow-up reuses evidence without a second provider request',
      () {
    final provider = _CountingProvider();
    final controller = SearchTurnContextController(
      coordinator: _coordinator(provider),
    );
    final snapshot = WebSearchSnapshot(
      requestId: 'request-1',
      rootRequestId: 'turn-1',
      executedQueries: const ['Flutter latest'],
      searchedAt: DateTime.utc(2026, 8, 24),
      provider: 'keyless-html',
      results: [
        WebSearchResult(
          sourceId: 'S1',
          title: 'Flutter',
          snippet: 'release',
          url: Uri.parse('https://docs.flutter.dev'),
          provider: 'keyless-html',
        ),
      ],
    );

    final followUp = controller.reuseSourcesForFollowUp(
      conversationId: 'group-1',
      sourceMessageId: 'user-message-2',
      turnId: 'user-message-2',
      query: '给我来源链接',
      snapshot: snapshot,
    );

    expect(const SearchIntentDetector().isSourceLinkRequest('给我来源链接'), isTrue);
    expect(followUp.allowSourceLinks, isTrue);
    expect(followUp.snapshot, same(snapshot));
    expect(provider.searchCount, 0);
    expect(
      controller.contextForTurn(
        conversationId: 'group-1',
        sourceMessageId: 'user-message-2',
      ),
      same(followUp),
    );
  });

  test('autoChat and proactive origins do not call a third-party provider',
      () async {
    final provider = _CountingProvider();
    final controller = SearchTurnContextController(
      coordinator: _coordinator(provider),
    );

    final autoChat = await controller.prepareUserTurn(
      conversationId: 'group-1',
      sourceMessageId: 'auto-message',
      turnId: 'auto-message',
      userMessage: 'search the web for the latest news',
      origin: SearchMessageOrigin.autoChat,
      requestConsent: (_) async => true,
    );
    final proactive = await controller.prepareUserTurn(
      conversationId: 'dm:character-1',
      sourceMessageId: 'proactive-message',
      turnId: 'proactive-message',
      userMessage: 'search the web for the latest news',
      origin: SearchMessageOrigin.proactive,
      requestConsent: (_) async => true,
    );

    expect(provider.searchCount, 0);
    expect(autoChat.isSuppressed, isTrue);
    expect(proactive.isSuppressed, isTrue);
  });

  test('settings cache clear invalidates completed turn cache entries',
      () async {
    final cache = SearchTurnCache();
    final key = SearchTurnCacheKey(
      sourceMessageId: 'user-message-1',
      turnId: 'user-message-1',
      normalizedQuery: 'latest Flutter',
      freshness: SearchFreshness.any,
      provider: 'brave',
    );
    var loadCount = 0;
    Future<String> load() async => 'result-${++loadCount}';

    expect(
      await cache.getOrLoad(
        key: key,
        ttl: const Duration(minutes: 5),
        loader: load,
      ),
      'result-1',
    );
    expect(cache.completedCount, 1);

    SearchTurnCache.clearAll();
    expect(cache.completedCount, 0);
    expect(
      await cache.getOrLoad(
        key: key,
        ttl: const Duration(minutes: 5),
        loader: load,
      ),
      'result-2',
    );
  });

  test('turn context controller bounds retained turn and reply associations',
      () async {
    final provider = _CountingProvider();
    final controller = SearchTurnContextController(
      coordinator: _coordinator(provider),
      maxTurns: 2,
      maxReplyContexts: 2,
    );

    final contexts = <SearchTurnContext>[];
    for (var index = 0; index < 3; index++) {
      final context = await controller.prepareUserTurn(
        conversationId: 'group-1',
        sourceMessageId: 'turn-$index',
        turnId: 'turn-$index',
        userMessage: '查一下 Flutter $index',
        requestConsent: (_) async => true,
      );
      contexts.add(context);
      controller.bindReply('reply-$index', context);
    }

    expect(
        controller.contextForTurn(
          conversationId: 'group-1',
          sourceMessageId: 'turn-0',
        ),
        isNull);
    expect(
        controller.contextForTurn(
          conversationId: 'group-1',
          sourceMessageId: 'turn-2',
        ),
        same(contexts.last));
    expect(controller.contextForReply('reply-0'), isNull);
    expect(controller.contextForReply('reply-2'), same(contexts.last));
  });
}

SearchCoordinator _coordinator(_CountingProvider provider) {
  return SearchCoordinator(
    store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
    routes: [SearchProviderRoute(provider: provider)],
  );
}

class _CountingProvider implements SearchProvider {
  final List<SearchRequest> requests = [];

  int get searchCount => requests.length;

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    requests.add(request);
    return SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'Flutter release notes',
          snippet: 'A current release result.',
          url: Uri.parse('https://example.com/flutter-release'),
        ),
      ],
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}
