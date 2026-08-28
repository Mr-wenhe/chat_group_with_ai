part of 'chat_room_page.dart';

class _ChatRoomPageState extends ConsumerState<ChatRoomPage>
    with WidgetsBindingObserver {
  /// 输入框文本控制器。
  final _textController = TextEditingController();

  /// 消息列表滚动控制器（同时用于触顶加载更早消息）。
  final _scrollController = ScrollController();

  /// 输入框焦点，用于 @ 弹窗、发送后重新聚焦等。
  final _inputFocusNode = FocusNode();

  /// API 凭证解析器：从安全存储中取出 apiKey，避免明文散落在业务层。
  late final ApiCredentialResolver _credentialResolver;

  /// 通用随机源（挑选发言人、随机文案等）。
  final _random = Random();

  /// 语音朗读服务（TTS），长按 AI 消息可朗读。
  late final MessageSpeechService _speech;

  /// Hive 数据访问入口。
  late final DatabaseService _db;

  /// AI 治理数据存储（预算 / 限流 / 用量 / 搜索策略）。
  late final AiGovernanceStore _governanceStore;

  /// AI 请求网关：所有 LLM 调用先过它做限流与预算校验。
  late final AiRequestGateway _aiGateway;

  /// Search provider routing, runtime settings, and per-turn associations.
  late final ChatRoomSearchRuntimeController _searchRuntime;

  /// Cancellation scope for the search preparation currently owned by this
  /// room. It is separate from the LLM stream token so closing/stopping a
  /// room also releases a Provider request that is still resolving.
  CancelToken? _activeSearchCancelToken;

  SearchCoordinator get _searchCoordinator => _searchRuntime.coordinator;
  SearchTurnContextController get _searchTurnController =>
      _searchRuntime.turnController;
  SearchRuntimeSettings get _searchRuntimeSettings =>
      _searchRuntime.runtimeSettings;

  /// 回复资格策略：判断某角色本轮能否发言（API 配置、频率上限等）。
  late final ReplyEligibilityPolicy _replyEligibility;

  /// 当前会话的消息仓储（分页加载 / 落库）。
  late final ChatRoomRepository _repository;

  /// 首屏数据加载器（群信息、成员、消息、记忆、关系态一次性取回）。
  late final ChatRoomLoader _loader;

  /// 记忆控制器：群记忆 / 角色记忆的生成与更新。
  late final MemoryControls _memoryControls;

  /// 统一全局记忆上下文选择器（跨群/DM，按 observerCharacterId 读取）。
  late final MemoryContextSelector _memoryContextSelector;

  /// 统一全局永久记忆观察入口（落库后触发记忆提炼）。
  late final ObservationEntry _observationEntry;

  /// 关系事件服务（方向性关系历史 + 幂等快照更新）。
  late final RelationshipEventService _relationshipEventService;

  /// 会话串行控制器：保证同一时刻只有一轮 AI 回复在跑，并支持中断。
  final ConversationController _conversationController =
      ConversationController();

  /// 空闲自动聊天调度器（按随机间隔触发 [_tryAutoChatRound]）。
  late final AutoChatScheduler _autoChatScheduler;

  /// 当前群信息；私聊场景为 loader 构造出的"展示用"伪群对象。
  ChatGroup? _group;

  /// 全局用户人物信息卡（来自 UserProfile box）。
  UserProfile? _userProfile;

  /// 活跃角色（用于 AI 回复等逻辑）
  List<AICharacter> _characters = [];

  /// 全部群成员（含停用），供 @ 弹窗使用
  List<AICharacter> _allGroupCharacters = [];

  /// 当前已加载到内存的消息（按时间升序，仅当前分页窗口）。
  List<Message> _messages = [];

  /// 完整历史中是否存在当前成员不可共同查看的消息。
  bool _hasRestrictedHistory = false;

  /// 是否还有更早的历史消息可以向上加载。
  bool _hasOlderMessages = false;

  /// 正在加载更早消息的重入保护标记。
  bool _isLoadingOlder = false;

  /// 会话的消息总数（用于展示"共 N 条"等信息）。
  int _totalMessageCount = 0;

  /// 群级周记忆（按 year_week 归档）。
  GroupMemory? _groupMemory;

  /// 每个角色在本会话中的分层记忆。
  List<CharacterMemory> _characterMemories = [];
  // ponytail: pinned compression stays in this room session; recompute after
  // reopening instead of creating another persisted memory channel.
  /// 上下文压缩的会话内缓存：characterId -> (压缩检查点, 压缩摘要)。
  ///
  /// 故意不落库——离开页面后重新计算，避免再引入一条需要维护的持久化记忆通道。
  final Map<String, ({String checkpoint, String summary})>
      _transientContextCompression = {};

  /// 角色之间的有向关系状态（好感 / 熟悉度等），影响发言意图选择。
  List<RelationshipState> _relationshipStates = [];

  /// 工作模式仅在页面保存开关；任务执行、取消和审批都归全局协调器。
  final WorkModeSession _workModeSession = WorkModeSession();

  /// 本轮已为各角色决策好但尚未消费的发言意图：characterId -> 意图。
  final Map<String, ReplyIntent> _pendingReplyIntents = {};

  /// 自动聊天轮次计数器，用于按固定节奏（而非每轮）触发记忆更新，降低成本。
  int _autoChatMemoryTick = 0;

  /// 是否处于工作模式（工作模式下禁用空闲自动聊天）。
  bool get _workModeEnabled => _workModeSession.enabled;

  /// 首屏数据是否仍在加载。
  bool _isLoading = true;

  /// 当前是否有 AI 回复回合正在进行（发送按钮、停止按钮等据此变化）。
  bool get _isAiReplying => _conversationController.isBusy;

  /// 用户本次发言后已自动进行的连续轮数。
  int _consecutiveRound = 0;

  /// 用户发言后的普通群聊最多连续三轮，避免角色互相回复形成无限循环。
  static const int _maxAutoRounds = 3;

  // 用户消息队列：AI 回复期间用户发的消息排队在此，回合结束后自动触发回复。

  // @ 成员选择弹窗
  /// @ 成员弹窗的 Overlay 句柄（非空表示弹窗已插入 Overlay）。
  OverlayEntry? _mentionOverlay;

  /// 是否正在展示 @ 成员弹窗。
  bool _showMentionPopup = false;

  /// 按搜索词过滤后的候选 @ 成员。
  List<AICharacter> _filteredMentionMembers = [];

  /// 键盘上下选择的高亮项
  int _mentionSelectedIndex = 0;

  /// @ 弹窗内的搜索输入控制器。
  final TextEditingController _mentionSearchController =
      TextEditingController();

  // 输入框 GlobalKey，用于精确定位 @ 弹窗。
  final GlobalKey _inputFieldKey = GlobalKey();

  // AI 自主聊天
  /// 空闲自动聊天开关（同时受治理设置里的全局开关约束）。
  bool _isAutoChatEnabled = true;

  /// 页面是否在前台活跃（deactivate 时置 false，防止异步回调在路由弹出后重建页面）。
  bool _pageActive = true;

  /// 当前 burst 内已执行的自动聊天轮数。
  int _autoChatRoundCount = 0;

  /// 丢弃当前流式输出的标记：用户点"停止生成"后置位，让流回调不再写状态。
  bool _discardCurrentStream = false;

  /// 一次空闲自动聊天 burst 的上限；达到后进入冷却，而不是持续灌水。
  static const int _maxAutoChatRounds = 4;

  /// 进入房间后延迟多久启动空闲自动聊天。
  static const Duration _autoChatInitialDelay = Duration(seconds: 8);

  /// 一个 burst 结束后的冷却时长。
  static const Duration _autoChatBurstPause = Duration(seconds: 35);

  /// 消息搜索输入的防抖时长。
  static const Duration _searchDebounceDuration = Duration(milliseconds: 250);

  /// 自动聊天两轮之间的最小间隔（秒）。
  static const int _autoChatMinIntervalSeconds = 12;

  /// 叠加在最小间隔之上的随机抖动上限（秒），避免节奏机械。
  static const int _autoChatIntervalJitterSeconds = 9;

  /// 自动聊天专用随机源（与 [_random] 分离，便于独立推理其随机性）。
  final Random _autoChatRandom = Random();

  /// 自动聊天当前状态（驱动顶部状态条 UI）。
  AutoChatStatus _autoChatStatus = AutoChatStatus.idle;

  /// 最近一次"无人可回复"的原因，用于给用户明确提示（如未配置 API Key）。
  ReplyBlockReason? _lastReplyBlockReason;

  // 待回应 @ 列表
  /// 用户 @ 到但尚未回复的角色 id 队列，下一轮优先让这些角色发言。
  final List<String> _pendingMentionedIds = [];

  // 并发兜底：记录当前正在执行 agentic 任务的角色 id，防止同一角色在同一轮内
  // 被重复触发（极端情况下的重入会产生重复消息 / 重复文件）。
  final Set<String> _agenticRunningCharacterIds = {};

  /// 输入框是否为空（缓存以避免每次输入都全量 rebuild）。
  bool _isInputEmpty = true;

  /// 是否允许发送：文案非空 或 有待发送附件。
  bool get _canSend => !_isInputEmpty || _pendingAttachments.isNotEmpty;

  // —— 待发送附件（图片多选 / 视频单选），发送后清空 ——
  final List<MediaAttachment> _pendingAttachments = [];

  /// 系统相册 / 相机选择器。
  final ImagePicker _imagePicker = ImagePicker();

  /// 正在把剪贴板内容转成附件（避免重复粘贴）。
  bool _isPastingAttachments = false;

  /// 桌面端是否有文件正被拖拽悬停在窗口上（用于高亮拖放区域）。
  bool _isDraggingFiles = false;

  // —— 引用回复（quote-reply）——
  /// 当前被引用的消息；非空时输入框上方显示引用条。
  Message? _quotedMessage;

  // —— 重新生成 ——
  /// 是否处于"重新生成"流程中。
  bool _isRegenerating = false;

  /// 正在被重新生成的消息 id。
  String _regenerateMessageId = '';

  /// 重新生成时使用的上下文快照（该消息之前的历史）。
  List<Message> _regenerateContext = [];

  // —— 搜索 ——
  /// 是否处于消息搜索模式（AppBar 切换为搜索框）。
  bool _isSearching = false;

  /// 搜索关键词输入控制器。
  final TextEditingController _searchController = TextEditingController();

  /// 当前搜索命中的消息列表。
  List<Message> _searchResults = [];

  /// 搜索结果中当前定位到的下标（用于上一条 / 下一条跳转）。
  int? _searchFocusIndex;
  // 是否存在已配置 API Key 的角色（决定 AI 能否回复/自动聊天）
  bool _hasAnyApiConfig = false;

  /// 搜索输入防抖定时器。
  Timer? _searchDebounceTimer;

  /// 联网搜索状态 banner 自动隐藏定时器。
  Timer? _searchBannerDismissTimer;

  /// 自动聊天启动延迟定时器（页面离开时取消，避免测试挂起）。
  Timer? _autoChatStartTimer;

  /// 用户在本会话手动覆盖的联网搜索策略（为空表示用全局策略）。
  WebSearchPolicy? _searchPolicyOverride;

  /// 联网搜索的运行状态（用于展示"正在搜索…"等提示）。
  SearchRunState _webSearchState = const SearchRunState(SearchRunStatus.idle);

  // —— 流式输出（打字机）相关状态 ——
  /// 正在逐 token 渲染的内存态临时消息（不落库）
  Message? _streamingMessage;

  /// 当前流式回复会话（持有 StreamSubscription，可取消）。
  StreamingReplySession? _streamingSession;

  /// 文档解析任务令牌（可取消长时间的文档理解流程）。
  DocumentProcessingToken? _documentProcessingToken;

  /// 文档解析进度 0~1。
  double _documentProcessingProgress = 0;

  /// 当前是否正在流式输出。
  bool get _isStreaming => _streamingSession?.isActive ?? false;

  /// dispose 守卫，避免异步回调在销毁后写状态
  bool _disposed = false;

  /// 消息列表控制器（供列表内部做定位、动画等）。
  final ChatMessageListController _messageListController =
      ChatMessageListController();

  // —— @我 提醒 ——
  /// 已收到但用户还没查看的"@我"消息 id 队列。
  final List<String> _pendingUserMentionMessageIds = [];

  /// 当前被临时高亮的消息 id（跳转定位后短暂高亮）。
  String? _highlightedMentionMessageId;

  /// 高亮自动取消定时器。
  Timer? _mentionHighlightTimer;

  /// 统一保护异步回调，避免页面离开后继续写入 State。
  bool get _canTouchUi => mounted && !_disposed && _pageActive;

  @override
  void setState(VoidCallback fn) {
    if (!_canTouchUi) return;
    super.setState(fn);
  }

  /// Extension parts use this wrapper so Flutter's protected [setState] API
  /// remains accessed from the State subclass itself.
  void _setUiState(VoidCallback fn) => setState(fn);

  // —— 语音播放 ——
  /// 当前是否正在朗读。
  bool _isSpeaking = false;

  /// 正在被朗读的消息 id（用于把按钮切成“停止朗读”）。
  String? _speakingMessageId;

  /// Stable test and feature boundary for building a character prompt.
  /// The implementation lives in the message-context part file.
  Future<List<Map<String, dynamic>>> buildPromptMessages({
    required AICharacter character,
    required List<Message> context,
    String? userMessage,
    bool isAutoChat = false,
    ReplyIntent? intent,
    bool supportsVision = false,
    Message? currentUserMessage,
    String? transientContextSummary,
  }) {
    return _buildPromptMessagesInternal(
      character: character,
      context: context,
      userMessage: userMessage,
      isAutoChat: isAutoChat,
      intent: intent,
      supportsVision: supportsVision,
      currentUserMessage: currentUserMessage,
      transientContextSummary: transientContextSummary,
    );
  }

  @override
  void initState() {
    super.initState();
    // 监听 App 生命周期，用于前台恢复时刷新在场状态 / 已读状态。
    WidgetsBinding.instance.addObserver(this);
    // 登记"当前正在查看该会话"，让主动私聊的通知逻辑不打扰当前界面。
    ConversationPresenceService.instance.enter(widget.groupId);
    _db = ref.read(databaseServiceProvider);
    _credentialResolver =
        widget.credentialResolver ?? SecureApiCredentialResolver();
    _governanceStore = AiGovernanceStore.forDatabase(_db);
    // 所有 LLM 调用都经由网关，超限时通过 onWarning 回调向用户提示。
    _aiGateway = AiRequestGateway(
      store: _governanceStore,
      client: widget.chatApi,
      onWarning: _showGovernanceWarning,
    );
    _initializeSearchRuntime();
    // 读取本会话此前保存过的搜索策略覆盖值。
    _searchPolicyOverride =
        _governanceStore.conversationSearchPolicy(widget.groupId);
    _loader = ChatRoomLoader(db: _db, resolveApiConfig: _resolveApiConfig);
    _memoryControls = MemoryControls(_db);
    _memoryContextSelector = MemoryContextSelector(_db);
    _observationEntry = ObservationEntry(db: _db);
    _relationshipEventService = RelationshipEventService(_db);
    _replyEligibility = ReplyEligibilityPolicy(
      resolveApiConfig: _resolveApiConfig,
    );
    _repository = ChatRoomRepository(
      db: _db,
      conversationId: widget.groupId,
      isDirectChat: _isDirectChat,
    );
    // 调度器只负责"何时触发"，具体一轮怎么跑交给 _tryAutoChatRound。
    _autoChatScheduler = AutoChatScheduler(
      nextInterval: () => Duration(
        seconds: _autoChatBaseIntervalSeconds +
            _autoChatRandom.nextInt(_autoChatIntervalJitterSeconds),
      ),
      runRound: _tryAutoChatRound,
    );
    _speech = MessageSpeechService(
      engine: FlutterTtsSpeechEngine(),
      onStateChanged: _handleSpeechState,
    );
    // 仅在"空/非空"状态翻转时 setState，避免每敲一个字都重建整页。
    _textController.addListener(() {
      final isEmpty = _textController.text.trim().isEmpty;
      if (isEmpty != _isInputEmpty) {
        setState(() => _isInputEmpty = isEmpty);
      }
    });
    // 触顶时加载更早的历史消息。
    _scrollController.addListener(_handleMessageScroll);
    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _handleDependenciesChanged();
  }

  @override
  void deactivate() {
    _deactivatePage();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _activatePage();
  }

  @override
  void dispose() {
    _disposePage();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _handleAppLifecycleState(state);
  }

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
