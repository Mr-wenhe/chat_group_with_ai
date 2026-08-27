part of 'search_stage06_test.dart';

SearchQueryPlanner _planner(MemoryGovernanceStore store, _PlannerClient client,
    {Duration? requestTimeout}) {
  return SearchQueryPlanner(
    gateway: AiRequestGateway(store: store, client: client),
    config: const SearchPlannerConfig(
      apiKey: 'planner-key',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      conversationId: 'conversation-1',
    ),
    requestTimeout: requestTimeout ?? SearchQueryPlanner.defaultRequestTimeout,
  );
}

String _validPlanJson() => jsonEncode({
      'blocked': false,
      'block_reason': '',
      'primary_query': 'Flutter latest stable release',
      'fallback_query': 'site:docs.flutter.dev release notes',
      'category': 'software',
      'freshness': 'month',
      'country': '',
      'language': 'en',
      'required_terms': ['Flutter', 'release'],
      'excluded_terms': [],
      'reason': '需要近期官方发布资料',
    });

String _blockedPlanJson() => jsonEncode({
      'blocked': true,
      'block_reason': 'private_content',
      'primary_query': '',
      'fallback_query': '',
      'category': 'general',
      'freshness': 'any',
      'country': '',
      'language': 'zh',
      'required_terms': [],
      'excluded_terms': [],
      'reason': '输入包含不应外发的私密内容',
    });

class _PlannerClient extends ChatApiService {
  final List<String> responses;
  final bool hang;
  final List<Map<String, dynamic>> calls = [];
  CancelToken? receivedCancelToken;
  Duration? receivedReceiveTimeout;
  int? receivedMaxResponseBytes;
  int? _responseLimitForNextCall;
  int sendCount = 0;

  _PlannerClient(Iterable<String> responses, {this.hang = false})
      : responses = List<String>.from(responses);

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    int? maxTokens,
    Duration? receiveTimeout,
    int? maxRetries,
    CancelToken? cancelToken,
  }) async {
    sendCount++;
    receivedCancelToken = cancelToken;
    receivedReceiveTimeout = receiveTimeout;
    calls.add({...messages.last});
    if (hang) {
      final pending = Completer<Map<String, dynamic>>();
      cancelToken?.whenCancel.then((_) {
        if (!pending.isCompleted) {
          pending.complete({'success': false, 'message': '请求已取消'});
        }
      });
      return pending.future;
    }
    final response = responses.isEmpty ? '' : responses.removeAt(0);
    final responseLimit = _responseLimitForNextCall;
    _responseLimitForNextCall = null;
    if (responseLimit != null && utf8.encode(response).length > responseLimit) {
      return {
        'success': false,
        'message': '响应超过测试客户端声明的大小上限',
      };
    }
    return {
      'success': true,
      'message': response,
      'promptTokens': 20,
      'completionTokens': 20,
    };
  }

  @override
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    int? maxTokens,
    Duration? receiveTimeout,
    int? maxRetries,
    CancelToken? cancelToken,
    required int maxResponseBytes,
  }) {
    receivedMaxResponseBytes = maxResponseBytes;
    _responseLimitForNextCall = maxResponseBytes;
    return sendChatMessage(
      apiKey: apiKey,
      provider: provider,
      customBaseUrl: customBaseUrl,
      model: model,
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      receiveTimeout: receiveTimeout,
      maxRetries: maxRetries,
      cancelToken: cancelToken,
    );
  }

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
    required List<Map<String, dynamic>> messages,
  }) async* {
    yield ChatStreamEvent.done('');
  }
}

class _SequenceProvider implements SearchProvider {
  final List<SearchProviderResponse> responses;
  final Duration delay;
  final List<SearchRequest> requests = [];
  int searchCount = 0;

  _SequenceProvider(
    Iterable<SearchProviderResponse> responses, {
    this.delay = Duration.zero,
  }) : responses = List<SearchProviderResponse>.from(responses);

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    searchCount++;
    requests.add(request);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return responses.isEmpty ? _successResponse() : responses.removeAt(0);
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}

SearchProviderResponse _successResponse() => SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'Flutter release notes',
          snippet: 'Stable release notes',
          url: Uri.parse('https://docs.flutter.dev/release/notes'),
        ),
      ],
    );

SearchProviderResponse _noResultsResponse() => SearchProviderResponse(
      items: [],
      failure: const SearchFailure(
        type: SearchFailureType.noResults,
        safeMessage: '',
        retryable: false,
      ),
    );
