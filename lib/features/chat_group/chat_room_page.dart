import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/agent_task_recovery_dialog.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/ai_character/ai_character_form_page.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/search_coordinator.dart';
import 'package:chat_group/features/chat_group/agentic_reply_utils.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/chat_group/auto_chat_scheduler.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/chat_group/chat_group_form_page.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/chat_group/chat_room_repository.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:chat_group/features/chat_group/chat_scroll_utils.dart';
import 'package:chat_group/features/chat_group/conversation_controller.dart';
import 'package:chat_group/features/chat_group/direct_read_receipt_policy.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/observation_entry.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';
import 'package:chat_group/features/chat_group/models/chat_room_models.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/chat_group/picked_attachment_payload.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:chat_group/features/chat_group/scene_behavior.dart';
import 'package:chat_group/features/chat_group/streaming_reply_session.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_list.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_app_bar.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_banners.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:chat_group/features/chat_group/widgets/hint_chip.dart';
import 'package:chat_group/features/chat_group/widgets/member_sheet.dart';
import 'package:chat_group/features/chat_group/widgets/sheet_button.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/features/work_mode/work_mode_config_service.dart';
import 'package:chat_group/features/work_mode/work_mode_memory_runner.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_session.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/services/message_speech_service.dart';
import 'package:chat_group/services/web_search_service.dart';
import 'package:chat_group/services/wecom_push_service.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

/// 空闲自动聊天（idle auto-chat）的对外可见状态，用于顶部状态条展示。
///
/// - [idle]：未启动 / 已停止
/// - [waiting]：已启动，正在等待下一次触发的间隔
/// - [generating]：本轮正在调用 LLM 生成回复
/// - [paused]：一个 burst 达到上限后的冷却期
/// - [unavailable]：没有任何配置了 API Key 的角色，功能不可用
/// - [error]：上一轮生成失败
enum AutoChatStatus { idle, waiting, generating, paused, unavailable, error }

/// 聊天页面（群聊 + 私聊共用）。
///
/// 路由既可以是 `/chat/{groupId}`（群聊），也可以是 `/dm/{characterId}`（私聊）；
/// 私聊场景下 [groupId] 传入的是 `dm:{characterId}` 形式的会话键，
/// 由 [DirectChatSession] 负责识别与解析。
class ChatRoomPage extends ConsumerStatefulWidget {
  /// 会话 id：群聊为 ChatGroup.id，私聊为 `dm:{characterId}`。
  final String groupId;

  /// 可选的定位目标消息 id（例如从搜索结果 / 通知跳转进来时），
  /// 打开后会加载该消息所在分页并高亮滚动定位。
  final String? initialMessageId;

  /// 测试或嵌入场景可替换 API client，不改变生产默认网关。
  final ChatApiService? chatApi;

  /// 测试或嵌入场景可替换凭据解析器，不改变生产安全边界。
  final ApiCredentialResolver? credentialResolver;

  const ChatRoomPage({
    super.key,
    required this.groupId,
    this.initialMessageId,
    this.chatApi,
    this.credentialResolver,
  });

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

/// 聊天页面状态。
///
/// 混入 [WidgetsBindingObserver] 以监听 App 前后台切换：回到前台时重新登记
/// 当前会话的"在场状态"并把消息标记为已读。
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

  /// 联网搜索协调器：决定是否搜索、执行搜索并计入治理用量。
  late final SearchCoordinator _searchCoordinator;

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

  /// 工作模式会话状态：是否启用、待用户审批的工具调用、停止请求等。
  final WorkModeSession<PendingAgentToolApproval> _workModeSession =
      WorkModeSession<PendingAgentToolApproval>();

  /// 本轮已为各角色决策好但尚未消费的发言意图：characterId -> 意图。
  final Map<String, ReplyIntent> _pendingReplyIntents = {};

  /// 自动聊天轮次计数器，用于按固定节奏（而非每轮）触发记忆更新，降低成本。
  int _autoChatMemoryTick = 0;

  /// 是否处于工作模式（工作模式下禁用空闲自动聊天）。
  bool get _workModeEnabled => _workModeSession.enabled;

  /// 当前等待用户确认的 agentic 工具调用（为空表示无待审批项）。
  PendingAgentToolApproval? get _pendingAgentApproval =>
      _workModeSession.pendingApproval;
  set _pendingAgentApproval(PendingAgentToolApproval? value) =>
      _workModeSession.pendingApproval = value;

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
    _searchCoordinator = SearchCoordinator(store: _governanceStore);
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
    // 依赖变化（例如路由复用同一 State）时重新登记在场状态。
    ConversationPresenceService.instance.enter(widget.groupId);
  }

  @override
  void dispose() {
    // 先置位守卫标记，后续异步回调据此直接返回，不再触碰已销毁的 State。
    _disposed = true;
    ConversationPresenceService.instance.leave(widget.groupId);
    WidgetsBinding.instance.removeObserver(this);
    // 未发送的附件已落盘到临时目录，需要清理避免残留垃圾文件。
    if (_pendingAttachments.isNotEmpty) {
      unawaited(_cleanupMediaPaths(_pendingAttachments));
    }
    _pendingAttachments.clear();
    _workModeSession.requestStop('页面已关闭');
    _documentProcessingToken?.cancel();
    _conversationController.dispose();
    _autoChatScheduler.dispose();
    // 关闭本地 agent 桥接进程，避免页面退出后仍有子进程驻留。
    unawaited(LocalAgentBridgeLauncher().stop());
    unawaited(_streamingSession?.dispose());
    _streamingSession = null;
    _searchDebounceTimer?.cancel();
    _searchBannerDismissTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    _searchController.dispose();
    _mentionHighlightTimer?.cancel();
    _hideMentionOverlay();
    _mentionSearchController.dispose();
    unawaited(_speech.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台：重新登记在场并把当前会话标记为已读。
    if (state == AppLifecycleState.resumed) {
      ConversationPresenceService.instance.enter(widget.groupId);
      unawaited(_markCurrentConversationRead());
    }
  }

  /// 当前会话是否为私聊（`dm:` 前缀）。
  bool get _isDirectChat =>
      DirectChatSession.isDirectConversationId(widget.groupId);

  /// 私聊对应的角色 id；群聊场景返回 null。
  String? get _directCharacterId =>
      DirectChatSession.characterIdFrom(widget.groupId);

  /// 首屏加载：一次性取回群信息、成员、消息分页、记忆与关系态。
  ///
  /// 若带了 [ChatRoomPage.initialMessageId] 且该消息不在首屏分页内，
  /// 会改为加载"目标消息所在窗口"，再高亮定位过去。
  /// 加载失败（会话已被删除等）时弹提示并退出页面。
  Future<void> _loadData() async {
    try {
      final loaded = await _loader.load(widget.groupId);
      var initialMessages = loaded.messages;
      var hasOlderMessages = loaded.hasOlderMessages;
      final targetId = widget.initialMessageId;
      // 目标消息不在默认分页中：改用"围绕目标消息"的分页窗口。
      if (targetId != null &&
          !initialMessages.any((message) => message.id == targetId)) {
        final page = await _repository.loadAround(targetId);
        initialMessages = page.messages;
        hasOlderMessages = page.hasOlder;
      }
      if (!_canTouchUi) return;

      setState(() {
        _group = loaded.displayGroup;
        _userProfile = loaded.userProfile;
        _characters = loaded.activeCharacters;
        _allGroupCharacters = loaded.allCharacters;
        _messages = initialMessages;
        _hasOlderMessages = hasOlderMessages;
        _totalMessageCount = loaded.totalMessageCount;
        _groupMemory = loaded.groupMemory;
        _characterMemories = loaded.characterMemories;
        _relationshipStates = loaded.relationships;
        _workModeSession.setEnabled(
          WorkModeConfigService(db: _db).isWorkMode(widget.groupId),
        );
        _hasAnyApiConfig = loaded.hasAnyApiConfig;
        _isAutoChatEnabled = _governanceStore.budgetSettings.autoChatEnabled;
        _autoChatStatus = loaded.hasAnyApiConfig
            ? AutoChatStatus.waiting
            : AutoChatStatus.unavailable;
        // 私聊且对方没有可用 API 配置时，直接给出明确的阻塞原因提示。
        _lastReplyBlockReason = loaded.isDirectChat &&
                loaded.allCharacters.isNotEmpty &&
                !loaded.hasAnyApiConfig
            ? _blockReasonFor(loaded.allCharacters.first)
            : null;
        _isLoading = false;
      });

      if (targetId == null) {
        // 常规进入：首帧布局完成后滚到底部。
        scrollToBottomAfterInitialLayout(_scrollController);
      } else {
        // 带定位目标：高亮并滚动到该消息。
        _highlightMessageTemporarily(targetId);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_canTouchUi) return;
          final target = _messages.where((message) => message.id == targetId);
          if (target.isNotEmpty) unawaited(_focusSearchResult(target.first));
        });
      }
      // 检查是否有上次异常中断的 agentic 任务需要恢复。
      _scheduleAgentTaskRecovery();
      if (ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: _workModeEnabled,
        autoChatEnabled: _isAutoChatEnabled,
        hasCharacters: loaded.activeCharacters.isNotEmpty,
        hasApiConfig: loaded.hasAnyApiConfig,
      )) {
        // 私聊更克制：延迟更久再主动开口，避免一进来就被打扰。
        final delay = loaded.isDirectChat
            ? const Duration(seconds: 18)
            : _autoChatInitialDelay;
        Future.delayed(delay, () {
          if (_canTouchUi && !_workModeEnabled) _startAutoChat();
        });
      }
    } on ChatRoomLoadException catch (error) {
      if (!mounted || _disposed) return;
      AppToast.show(context, error.message, icon: Icons.error_outline_rounded);
      Navigator.pop(context);
    }
  }

  /// 滚动监听：接近顶部（<120px）且还有历史消息时，自动加载上一页。
  void _handleMessageScroll() {
    if (!_scrollController.hasClients ||
        _scrollController.position.pixels > 120 ||
        !_hasOlderMessages ||
        _isLoadingOlder) {
      return;
    }
    unawaited(_loadOlderMessages());
  }

  /// 向上加载更早的一页消息，并保持用户当前视觉位置不跳动。
  ///
  /// 做法：记录加载前的滚动偏移与内容总高，插入新消息后在下一帧
  /// 按"新增高度"补偿偏移，避免列表顶部插入导致内容瞬移。
  Future<void> _loadOlderMessages() async {
    if (_messages.isEmpty || _isLoadingOlder || !_hasOlderMessages) return;
    _isLoadingOlder = true;
    final oldPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    final oldExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    try {
      final page = await _repository.loadOlder(_messages.first.id);
      if (!_canTouchUi) return;
      final existingIds = _messages.map((message) => message.id).toSet();
      setState(() {
        // 用 Set.add 的返回值顺手去重，防止分页边界重复插入同一条消息。
        _messages = [
          ...page.messages.where((message) => existingIds.add(message.id)),
          ..._messages,
        ];
        _hasOlderMessages = page.hasOlder;
        _totalMessageCount = page.totalCount;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final addedExtent =
            _scrollController.position.maxScrollExtent - oldExtent;
        _scrollController.jumpTo(oldPixels + addedExtent);
      });
    } finally {
      _isLoadingOlder = false;
    }
  }

  /// 在首帧之后异步询问是否恢复中断的 agentic 任务。
  ///
  /// 放到 post-frame 是为了确保此时已有可用的 context 弹出对话框。
  void _scheduleAgentTaskRecovery() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canTouchUi) unawaited(_offerAgentTaskRecovery());
    });
  }

  /// 查找本会话中"可在工作模式下恢复"的 agentic 任务，取最近一条询问用户。
  ///
  /// 仅工作模式生效；用户选择继续则续跑，否则标记为放弃并清理。
  Future<void> _offerAgentTaskRecovery() async {
    if (!_workModeEnabled) return;
    final tasks = _db.agentTaskBox.values
        .where((task) =>
            task.groupId == widget.groupId && task.canResumeInWorkMode)
        .toList()
      // 按最后更新时间倒序，优先恢复最近中断的那个任务。
      ..sort((a, b) =>
          (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt));
    if (tasks.isEmpty || !_canTouchUi) return;
    final task = tasks.first;
    final continueTask = await showDialog<bool>(
      context: context,
      // 强制用户明确选择"继续/放弃"，避免任务悬挂在不确定状态。
      barrierDismissible: false,
      builder: (dialogContext) => AgentTaskRecoveryDialog(
        task: task,
        onAbandon: () => Navigator.pop(dialogContext, false),
        onContinue: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (continueTask == true) {
      await _resumeAgentTask(task);
    } else {
      await _cancelAgentTask(task, reason: '用户放弃恢复任务。');
    }
  }

  /// 恢复一个中断的 agentic 任务。
  ///
  /// 两种恢复路径：
  /// 1. 任务卡在"等待工具审批"→ 重建审批项并再次弹给用户确认；
  /// 2. 否则从已完成的操作列表继续跑 agentic 循环。
  Future<void> _resumeAgentTask(AgentTask task) async {
    if (!_workModeEnabled || !task.workModeTask) return;
    final character = _db.aiCharacterBox.get(task.characterId);
    if (character == null) return;
    final config = _resolveApiConfig(character);
    if (config == null) return;
    final provider = ApiProvider.values.firstWhere(
      (value) => value.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    final workspace = await WorkModeWorkspaceService(db: _db).loadOrCreate(
      conversationId: widget.groupId,
      isDirectChat: _isDirectChat,
    );
    // 每个 await 之后都要复检：期间用户可能已退出页面或关闭工作模式。
    if (!_canTouchUi || !_workModeEnabled) return;
    await LocalAgentBridgeLauncher().registerWorkspace(
      conversationId: widget.groupId,
      workspacePath: workspace.workDirPath,
    );
    if (!_canTouchUi || !_workModeEnabled) return;
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending != null) {
      // 路径 1：中断点正好停在待审批的工具调用上。
      final approval = PendingAgentToolApproval(
        character: character,
        config: config,
        provider: provider,
        userRequest: task.userRequest,
        request: pending,
        priorExecutedRequests: _restoredExecutedRequests(task),
        task: task,
      );
      await _presentPendingAgentApproval(approval);
      return;
    }
    // 路径 2：直接续跑 agentic 循环。
    if (_conversationController.beginWork() == null) return;
    if (_canTouchUi) setState(() {});
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    try {
      await _generateAgenticReply(
        character: character,
        config: config,
        provider: provider,
        userMessage: task.userRequest,
        context: _recentMessagesForContext(),
        resumeTask: task,
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
    } finally {
      _workModeSession.finishRun(workModeRun);
      await _finishWorkActivityAndDispatchNext();
    }
  }

  /// 把任务里以 JSON 字符串保存的"已执行操作"还原成 [ToolRequest] 列表。
  ///
  /// 解析失败的条目会被 [Iterable.whereType] 静默丢弃——历史数据格式变化时
  /// 不应阻断整个任务恢复。
  List<ToolRequest> _restoredExecutedRequests(AgentTask task) {
    return task.completedOperations
        .map(ToolRequest.fromJsonString)
        .whereType<ToolRequest>()
        .toList();
  }

  /// 启动空闲自动聊天调度器（首次延迟带随机抖动）。
  void _startAutoChat() {
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
    )) {
      return;
    }
    if (!_canTouchUi) return;
    setState(() => _autoChatStatus = AutoChatStatus.waiting);
    _autoChatScheduler.start(
      initialDelay: Duration(
        seconds: _autoChatBaseIntervalSeconds +
            _autoChatRandom.nextInt(_autoChatIntervalJitterSeconds),
      ),
    );
  }

  /// 自动聊天的基础间隔（秒）。
  ///
  /// 私聊固定 45 秒（更克制）；群聊取群配置的 replyIntervalSeconds，
  /// 并夹到 5~60 秒防止用户配出极端值把接口打爆或几乎不说话。
  int get _autoChatBaseIntervalSeconds {
    if (_isDirectChat) return 45;
    final configured =
        _group?.replyIntervalSeconds ?? _autoChatMinIntervalSeconds;
    return configured.clamp(5, 60);
  }

  /// 停止自动聊天并把轮次计数归零，状态置为 [AutoChatStatus.paused]。
  void _stopAutoChat() {
    _autoChatScheduler.stop();
    _autoChatRoundCount = 0;
    if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
  }

  /// 执行一轮空闲自动聊天。
  ///
  /// 多重让位条件（任一命中则本轮跳过或进入冷却）：
  /// - 策略层不允许（工作模式 / 开关关闭 / 无角色 / 无 API 配置）；
  /// - 已有回复在跑、正在流式输出、或用户正在输入（不打断用户）；
  /// - 私聊里 AI 已连说 3 条而用户没回（避免单方面刷屏）；
  /// - 本 burst 轮数达上限 → 停止并冷却 [_autoChatBurstPause]。
  Future<void> _tryAutoChatRound() async {
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
    )) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (!_canTouchUi) return;
    if (_isAiReplying ||
        _isStreaming ||
        _textController.text.trim().isNotEmpty) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (_isDirectChat && _directAiMessagesSinceLastUser() >= 3) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (_autoChatRoundCount >= _maxAutoChatRounds) {
      _stopAutoChat();
      _autoChatScheduler.coolDown(_autoChatBurstPause);
      return;
    }

    // 由拟人化编排器根据记忆、关系、话题契合度挑选本轮发言者及其发言意图。
    final autoIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _messages.toList(),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: null,
      mentionedIds: const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _autoChatRandom,
      isAutoChat: true,
    );
    // 排除正在跑 agentic 任务的角色，防止同一角色重入产生重复消息/文件。
    var speakers = _charactersForIntents(autoIntents)
        .where((c) => !_agenticRunningCharacterIds.contains(c.id))
        .toList();
    final lastAiSenderId = _lastAiSenderId;
    // 有多个候选时避免让上一条的发言者连说两轮；只剩一个候选就不再过滤。
    final speakersToUse = speakers.length <= 1
        ? speakers
        : speakers.where((c) => c.id != lastAiSenderId).toList();
    _pendingReplyIntents
      ..clear()
      ..addEntries(
          autoIntents.map((intent) => MapEntry(intent.speakerId, intent)));

    if (speakersToUse.isEmpty) {
      if (_canTouchUi) {
        setState(() {
          _autoChatStatus = AutoChatStatus.unavailable;
          _lastReplyBlockReason = _eligibleCharacters.isEmpty
              ? _firstBlockReason(_characters)
              : null;
        });
      }
      return;
    }

    // beginAuto 返回 null 表示已有回合占用，本轮直接放弃。
    if (_conversationController.beginAuto() == null) return;
    setState(() {
      _autoChatRoundCount++;
      _autoChatStatus = AutoChatStatus.generating;
    });

    try {
      for (final speaker in speakersToUse) {
        // 循环内逐次复检开关：用户可能中途关闭自动聊天或切到工作模式。
        if (!_isAutoChatEnabled || _workModeEnabled) break;
        if (!_isEligibleToReply(speaker)) continue;
        final replyContent = await _generateAiReply(
          speaker,
          _messages.toList(),
          null,
          isAutoChat: true,
          intent: _pendingReplyIntents[speaker.id],
        );
        if (_workModeEnabled) break;
        if (_conversationController.state.phase == ConversationPhase.stopping) {
          break;
        }
        // 按内容长度模拟"打字时间"，让多人接话有真实节奏。
        await _delay(replyContent);
      }

      // 自动聊天每 3 轮才更新一次记忆，避免每轮都额外调用一次 LLM。
      if (!_workModeEnabled) {
        _autoChatMemoryTick++;
        if (_autoChatMemoryTick >= 3) {
          _autoChatMemoryTick = 0;
          await _maybeUpdateMemory();
        }
      }
    } finally {
      if (_canTouchUi) {
        _conversationController.complete();
        setState(() {
          _autoChatStatus = _isAutoChatEnabled && !_workModeEnabled
              ? AutoChatStatus.waiting
              : AutoChatStatus.paused;
        });
      }
    }

    // 处理排队中的用户消息：当前回合结束后自动触发下一轮 AI 回复。
    final next = _conversationController.takeNext();
    if (next != null && _canTouchUi) {
      await _runAiRound(
          userMessage: next.text, mentionedIds: next.mentionedIds);
    }
  }

  /// 是否可以安全操作 UI / 写 State（未卸载且未 dispose）。
  bool get _canTouchUi => mounted && !_disposed;

  /// 覆盖 [setState] 统一加守卫：异步回调无需各自判断是否已销毁。
  @override
  void setState(VoidCallback fn) {
    if (!_canTouchUi) return;
    super.setState(fn);
  }

  /// 计算这批消息对应的"已读截止时间"。
  DateTime _readThrough(List<Message> messages) {
    return ChatRoomLoader.readThrough(
      messages.map((message) => message.timestamp),
    );
  }

  /// 把当前会话标记为已读并清除"@我"横幅。
  ///
  /// 传 [throughMessage] 时只按该条消息的时间戳推进已读位置，
  /// 否则按当前已加载消息的最大时间戳。
  Future<void> _markCurrentConversationRead({Message? throughMessage}) async {
    await _repository.markRead(
      throughMessage == null
          ? _readThrough(_messages)
          : _readThrough([throughMessage]),
    );
    _clearActiveUserMentionBanner();
  }

  /// 发送用户消息的主入口。
  ///
  /// 顺序：收起 @ 弹窗 → 解析 @ 列表 → 拦截工具审批指令 → 构造并落库消息
  /// → 私聊标记来源/已读 → 清理引用与附件 → 派发 AI 回复（或排队）。
  Future<void> _sendMessage() async {
    _hideMentionOverlay();
    final text = _textController.text.trim();
    final hasAttachments = _pendingAttachments.isNotEmpty;
    // 放宽发送条件：文案非空 或 有附件均可发送。
    if (text.isEmpty && !hasAttachments) return;

    _textController.clear();
    final mentionedIds = _parseMentions(text);
    for (final id in mentionedIds) {
      if (!_pendingMentionedIds.contains(id)) {
        _pendingMentionedIds.add(id);
      }
    }

    // 审批词（「批准」「取消」等）不应作为普通用户消息落库。
    if (await _handlePendingAgentApproval(text)) {
      // 发送后清空待发送附件（即使审批消息本身不展示）。
      if (hasAttachments && mounted) {
        setState(() => _pendingAttachments.clear());
      }
      return;
    }

    // 构造带媒体附件的用户消息（媒体为不可变快照，避免后续清空影响已落库消息）。
    final userMessage = Message(
      groupId: widget.groupId,
      senderId: 'user',
      senderType: 'user',
      content: text,
      replyToMessageId: _quotedMessage?.id,
      media: hasAttachments
          ? List<MediaAttachment>.from(_pendingAttachments)
          : null,
    );
    await _appendMessage(userMessage);
    if (_isDirectChat) {
      // 记录该私聊由用户主动发起，影响后续主动联系的冷却判断。
      await _db.saveDirectChatSource(widget.groupId, DirectChatSource.direct);
      await _repository.markRead(_readThrough(_messages));
    }
    _cancelQuote();

    // 发送后清空待发送附件。
    if (hasAttachments && mounted) {
      setState(() => _pendingAttachments.clear());
    }

    // 用户开口即重置 burst 计数，让自动聊天重新获得完整额度。
    _autoChatRoundCount = 0;

    if (_characters.isEmpty) {
      if (mounted) {
        AppToast.show(context, _isDirectChat ? '该角色当前不可回复' : '该群聊没有活跃的角色',
            icon: Icons.info_outline_rounded);
      }
      return;
    }

    if (_isAiReplying) {
      // AI 正在回复中，排队等待当前回合结束后再处理。
      _conversationController.enqueue(PendingUserMessage(
        text,
        mentionedIds,
        message: userMessage,
      ));
      return;
    }

    await _dispatchUserRequest(
      text: text,
      mentionedIds: mentionedIds,
      userMessage: userMessage,
    );
  }

  /// 根据当前模式把用户请求派发给"工作模式任务"或"普通聊天回合"。
  Future<void> _dispatchUserRequest({
    required String text,
    required List<String> mentionedIds,
    Message? userMessage,
  }) async {
    if (_workModeEnabled) {
      await _runWorkModeTask(
        text: text,
        mentionedIds: mentionedIds,
        userMessage: userMessage,
      );
      return;
    }
    final sentiment = UserMessageSentimentAnalyzer.analyze(text);
    await _runAiRound(
      userMessage: text,
      mentionedIds: mentionedIds,
      currentUserMessage: userMessage,
      userSentiment: sentiment,
    );
  }

  /// 工作模式：选出唯一执行者，准备工作区，然后跑 agentic 工具循环。
  ///
  /// 与普通群聊不同，工作模式只让一个角色执行（避免多角色并发写同一工作区），
  /// 且必须是启用了 Agentic 能力的活跃角色。
  Future<void> _runWorkModeTask({
    required String text,
    required List<String> mentionedIds,
    Message? userMessage,
  }) async {
    final executor = WorkModePolicy.selectExecutor(
      characters: _characters,
      mentionedIds: mentionedIds,
    );
    if (executor == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式需要至少一个已启用 Agentic 的活跃角色。',
      ));
      return;
    }
    // 策略层判断这条输入是否值得触发一次工作任务（例如纯闲聊则跳过）。
    if (!WorkModePolicy.shouldRun(
      enabled: _workModeEnabled,
      character: executor,
      userRequest: text,
    )) {
      return;
    }
    final config = _resolveApiConfig(executor);
    if (config == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: executor.id,
        senderType: 'ai',
        content: '[${executor.name} 未配置 API，无法执行工作任务]',
      ));
      return;
    }
    // 配置里存的是 provider 名字符串，找不到时兜底为 deepseek。
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    if (_conversationController.beginWork() == null) return;
    // 空 setState 用于让"正在执行"相关的按钮态立即刷新。
    if (_canTouchUi) setState(() {});
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    try {
      // 为本会话准备（或复用）独立工作目录，并注册给本地 agent 桥接进程。
      final workspace = await WorkModeWorkspaceService(db: _db).loadOrCreate(
        conversationId: widget.groupId,
        isDirectChat: _isDirectChat,
      );
      await LocalAgentBridgeLauncher().registerWorkspace(
        conversationId: widget.groupId,
        workspacePath: workspace.workDirPath,
      );
      await _generateAgenticReply(
        character: executor,
        config: config,
        provider: provider,
        userMessage: text,
        media: userMessage?.media,
        context: _recentMessagesForContext(),
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
    } finally {
      _workModeSession.finishRun(workModeRun);
      await _finishWorkActivityAndDispatchNext();
    }
  }

  /// 结束工作活动状态，并在没有待审批项时继续处理排队的用户消息。
  ///
  /// 有待审批工具时故意不取队列——必须等用户先决定批准或取消。
  Future<void> _finishWorkActivityAndDispatchNext() async {
    _finishWorkActivity();
    final next = _pendingAgentApproval == null
        ? _conversationController.takeNext()
        : null;
    if (next != null && _canTouchUi) {
      await _dispatchUserRequest(
        text: next.text,
        mentionedIds: next.mentionedIds,
        userMessage: next.message,
      );
    }
  }

  /// 执行一轮普通群聊 / 私聊的 AI 回复。
  ///
  /// [userMessage] 本轮触发的用户文本（自动聊天时为 null）；
  /// [mentionedIds] 用户 @ 到的角色；[isAutoChat] 区分空闲自动聊天；
  /// [currentUserMessage] 用户消息实体（含附件），供多模态上下文使用。
  ///
  /// 非自动轮受 [_maxAutoRounds] 约束，防止角色互相接话形成无限循环。
  Future<void> _runAiRound(
      {String? userMessage,
      List<String>? mentionedIds,
      bool isAutoChat = false,
      Message? currentUserMessage,
      UserMessageSentiment? userSentiment}) async {
    if (!isAutoChat && _consecutiveRound >= _maxAutoRounds) {
      if (_pendingMentionedIds.isNotEmpty) {
        _pendingMentionedIds.clear();
      }
      return;
    }

    final conversationRun = isAutoChat
        ? _conversationController.beginAuto()
        : _conversationController.beginNormal();
    if (conversationRun == null) return;
    setState(() {
      if (!isAutoChat) _consecutiveRound++;
    });

    // 私聊固定由对方角色回复；群聊则由意图编排器挑选发言者。
    var charactersToReply = _isDirectChat
        ? _directReplyCharacters()
        : _charactersForIntents(_selectGroupReplyIntents(
            userMessage: userMessage!, // nullable param, non-null at this point
            mentionedIds: mentionedIds,
            isAutoChat: isAutoChat,
            userSentiment: userSentiment,
          ));
    if (charactersToReply.isEmpty) {
      // 有人有资格但编排器选择"本轮沉默"：静默收尾，不算异常。
      if (_characters.any(_isEligibleToReply)) {
        setState(() {
          _conversationController.complete();
          if (!isAutoChat) _consecutiveRound = 0;
        });
        return;
      }
      // 确实没人能回复：记录原因并给出可操作提示（如跳转设置页配 API Key）。
      final blockReason = _firstBlockReason(_characters);
      setState(() {
        _conversationController.complete();
        if (!isAutoChat) _consecutiveRound = 0;
        _lastReplyBlockReason = blockReason;
        _autoChatStatus = AutoChatStatus.unavailable;
      });
      if (mounted && !isAutoChat) {
        AppToast.show(
          context,
          _replyBlockText(blockReason),
          icon: Icons.info_outline_rounded,
          actionLabel:
              blockReason == ReplyBlockReason.noApiConfig ? '去设置' : null,
          onTap: blockReason == ReplyBlockReason.noApiConfig
              ? () => Navigator.pushNamed(context, '/settings')
              : null,
        );
      }
      return;
    }

    final repliedIds = <String>[];
    for (final character in charactersToReply) {
      final wasPendingReply = _pendingMentionedIds.contains(character.id);
      late final String replyContent;
      try {
        replyContent = await _generateAiReply(
          character,
          _recentMessagesForContext(),
          userMessage,
          isAutoChat: isAutoChat,
          intent: _pendingReplyIntents[character.id],
          currentUserMessage: currentUserMessage,
          userSentiment: userSentiment,
        );
      } catch (e) {
        // 单个角色失败不中断整轮：写入可见的失败气泡，继续下一个角色。
        replyContent = '[${character.name} 回复失败: $e]';
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: character.id,
          senderType: 'ai',
          content: replyContent,
        ));
        if (_canTouchUi) {
          setState(() {
            _autoChatStatus = AutoChatStatus.error;
            _lastReplyBlockReason = ReplyBlockReason.networkError;
          });
        }
      }
      repliedIds.add(character.id);
      if (_conversationController.state.phase == ConversationPhase.stopping) {
        break;
      }
      // 被 @ 的角色回复更快，符合"被点名会立刻应答"的直觉。
      await _delay(
        replyContent,
        fast: mentionedIds?.contains(character.id) ?? false,
      );
      if (wasPendingReply) {
        _pendingMentionedIds.remove(character.id);
      }
    }

    // 代 @ 提醒：用户 @ 的人本轮都没回复时，让另一个在场角色帮忙 @ 一下，
    // 模拟真实群里"某人没看到，别人帮他叫一声"的行为。
    if (!_isDirectChat &&
        mentionedIds != null &&
        mentionedIds.isNotEmpty &&
        repliedIds.every((id) => !mentionedIds.contains(id)) &&
        _pendingMentionedIds.isNotEmpty) {
      final notMentionedPending = _pendingMentionedIds
          .where((id) => !mentionedIds.contains(id))
          .toList();
      if (notMentionedPending.isNotEmpty) {
        final proxyId = notMentionedPending.first;
        // 仅在 proxyId 真实对应一个角色时才播报提醒；兜底分支（proxyId 不属于
        // 任何已知角色）不伪造 @，也避免把脏 id 留在集合里导致后续轮次重复播报。
        final matched = _characters.where((c) => c.id == proxyId).toList();
        if (matched.isNotEmpty && _isEligibleToReply(matched.first)) {
          final proxyChar = matched.first;
          final targetName = proxyChar.name;
          await _appendMessage(Message(
            groupId: widget.groupId,
            senderId: proxyChar.id,
            senderType: 'ai',
            content: '$targetName 刚才没看到，我帮你@他一下 @$targetName',
            isMention: true,
            mentionedAiIds: [proxyId],
          ));
        }
        // 无论是否真正播报，都从待提醒集合中移除该 id，防止跨轮膨胀 / 重复刷屏。
        _pendingMentionedIds.remove(proxyId);
      }
    }

    await _maybeUpdateMemory();

    // widget 可能在 _maybeUpdateMemory 的 await 期间被 dispose，
    // 恢复后必须重新检查 _canTouchUi 才能调用 setState。
    if (!_canTouchUi) return;

    setState(() {
      _conversationController.complete();
      if (!isAutoChat) _consecutiveRound = 0;
    });

    // 处理排队中的用户消息：当前回合结束后自动触发下一轮 AI 回复。
    final next = _conversationController.takeNext();
    if (next != null && _canTouchUi) {
      await _dispatchUserRequest(
        text: next.text,
        mentionedIds: next.mentionedIds,
        userMessage: next.message,
      );
    }
  }

  /// 生成单个角色的一条回复（流式打字机路径），返回最终文本。
  ///
  /// 主要步骤：
  /// 1. 解析 API 配置与密钥，缺失则写入占位消息并置位阻塞原因；
  /// 2. 必要时压缩上下文（[_compactContextIfNeeded]）；
  /// 3. 按策略决定是否联网搜索，并把搜索结果作为 system 上下文注入；
  /// 4. 插入一条内存态空消息用于逐 token 渲染，**不立即落库**；
  /// 5. 失败则重试一次；空回复用兜底文案；重复回复直接丢弃；
  /// 6. 完成后清洗内容（去名字前缀、去 tool_call 协议泄漏），只落库一次；
  /// 7. 更新用量、关系态与角色记忆。
  Future<String> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false,
      ReplyIntent? intent,
      Message? currentUserMessage,
      UserMessageSentiment? userSentiment}) async {
    if (isAutoChat && _workModeEnabled) return '';
    // 并发兜底：同一角色正在执行 agentic 任务时，auto-chat / 其他并发路径
    // 不得触发同一角色的普通 LLM 回复，否则会出现「agentic 兜底文案 + 普通
    // LLM 泄漏代码」两条消息的 Bug（auto-chat 传 userMessage=null 会绕过 agentic
    // 分支直接走流式路径，而 _agenticRunningCharacterIds 此前仅在 _generateAgenticReply
    // 入口检查，覆盖不到这里）。
    if (_agenticRunningCharacterIds.contains(character.id)) {
      return '';
    }

    final config = _resolveApiConfig(character);
    final apiKey =
        config == null ? null : await _credentialResolver.resolve(config);
    if (config == null || apiKey == null) {
      if (_canTouchUi) {
        setState(() {
          _autoChatStatus = AutoChatStatus.unavailable;
          _lastReplyBlockReason = ReplyBlockReason.noApiConfig;
        });
      }
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: '[${character.name} 未配置 API]',
      ));
      return '[${character.name} 未配置 API]';
    }

    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    // 上下文超出模型窗口时先做压缩，拿到压缩后的消息与摘要。
    final compactedContext = await _compactContextIfNeeded(
      character: character,
      config: config,
      provider: provider,
      fallbackContext: context,
    );

    // 按会话/全局策略决定是否联网搜索；ask 策略下通过 _confirmWebSearch 征求同意。
    final webSearch = await _searchCoordinator.searchIfAllowed(
      text: userMessage,
      conversationId: widget.groupId,
      requestConsent: _confirmWebSearch,
      onStatus: (state) {
        if (!_canTouchUi) return;
        _searchBannerDismissTimer?.cancel();
        setState(() => _webSearchState = state);
        if (!state.status.isTerminal) return;
        _searchBannerDismissTimer = Timer(const Duration(seconds: 3), () {
          if (_canTouchUi) {
            setState(() =>
                _webSearchState = const SearchRunState(SearchRunStatus.idle));
          }
        });
      },
    );
    // 查询模型能力（是否支持图片输入），决定要不要拼多模态内容。
    final capability = _aiGateway.capability(provider, config.modelName);
    final apiMessages = _withWebSearchContext(
      await buildPromptMessages(
        character: character,
        context: compactedContext.messages,
        userMessage: userMessage,
        isAutoChat: isAutoChat,
        intent: intent,
        supportsVision: capability.supportsVision,
        currentUserMessage: currentUserMessage,
        transientContextSummary: compactedContext.summary,
      ),
      webSearch,
    );
    // 上面的 await 期间用户可能切到工作模式，此时放弃这次自动聊天回复。
    if (isAutoChat && _workModeEnabled) {
      _discardCurrentStream = false;
      return '';
    }
    // —— 内存态临时消息：先以空内容入列用于增量渲染，整条完成后再落库一次 ——
    final temp = Message(
      groupId: widget.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: '',
    );
    if (mounted) {
      setState(() {
        _streamingMessage = temp;
        _messages = List.from(_messages)..add(temp);
      });
    }
    _scrollToBottom();

    final session = StreamingReplySession();
    _streamingSession = session;
    if (_canTouchUi) setState(() {});
    final result = await session.run(
      _aiGateway.streamChatMessage(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: apiMessages,
        purpose:
            isAutoChat ? AiRequestPurpose.autoChat : AiRequestPurpose.reply,
        conversationId: widget.groupId,
        characterId: character.id,
        userInitiated: !isAutoChat,
      ),
      // 每收到一段增量就直接改临时消息的 content 并请求重绘（不走 setState 全量重建）。
      onDraft: (draft) {
        temp.content = draft;
        _conversationController.updateStreamingDraft(draft);
        _flushStreamingUi();
      },
    );
    if (_disposed) return '';
    var fullContent = result.content;
    var failed = result.failed;
    if (failed) {
      _lastReplyBlockReason = ReplyBlockReason.networkError;
      fullContent = '[${character.name} 回复失败: ${result.error}]';
      temp.content = fullContent;
      if (_canTouchUi) {
        setState(() => _autoChatStatus = AutoChatStatus.error);
      }
    }
    // 仅当 _streamingSession 还是本次会话时才清空，避免误清后来者。
    if (identical(_streamingSession, session)) _streamingSession = null;

    // 用户点了"停止生成"：丢弃这条内存态消息，不落库。
    if (_discardCurrentStream) {
      _discardCurrentStream = false;
      if (_canTouchUi) {
        setState(() {
          _streamingMessage = null;
          _messages = List<Message>.from(_messages)
            ..removeWhere((message) => message.id == temp.id);
        });
      }
      return '';
    }

    if (_canTouchUi) setState(() {});

    // 空内容也给出可见反馈，否则 @ 触发会像没有人理会。
    if (!failed && fullContent.trim().isEmpty) {
      fullContent = ChatActivityPolicy.emptyReplyFallback(
        characterName: character.name,
        role: character.role,
        groupTheme: _group?.theme ?? '',
        userMessage: userMessage,
        isAutoChat: isAutoChat,
        random: _random,
      );
      temp.content = fullContent;
      _flushStreamingUi();
    }

    // 失败重试一次；但被治理网关拦下（超预算/限流）时不重试，否则只是重复挨拒。
    if (failed && !AiRequestGateway.isBlockedMessage(result.error)) {
      final retryContent = await _retryFailedReply(
        character: character,
        config: config,
        provider: provider,
        apiMessages: apiMessages,
        userInitiated: !isAutoChat,
      );
      if (retryContent != null && retryContent.trim().isNotEmpty) {
        failed = false;
        fullContent = retryContent.trim();
        temp.content = fullContent;
        if (_canTouchUi) _flushStreamingUi();
      }
    }

    // 解析 @ 提及 → mentionedAiIds（未知名称忽略，避免误指向第一个成员）。
    final mentionedIds = _isDirectChat
        ? const <String>[]
        : parseMentionedCharacterIds(fullContent, _characters);

    // 移除 LLM 可能附带的名字前缀（UI 已独立显示角色名）。
    fullContent = _stripNamePrefix(fullContent, character.name);
    // 防御：非 agentic 路径下 LLM 可能自发输出 tool_call 协议标签文本
    // （尤其使用过 agentic 能力的角色，system prompt 里可能残留工具说明）。
    // 在落库与返回前清洗之，避免协议泄漏被当作普通聊天贴出来。
    fullContent = sanitizeNonAgenticReply(fullContent);
    // 与近期消息重复时直接丢弃这条（只记用量），避免刷屏式复读。
    if (!failed &&
        isDuplicateAiReply(
          fullContent,
          _messages,
          excludeMessageId: temp.id,
        )) {
      await _recordReplyUsage(character);
      if (_canTouchUi) {
        setState(() {
          _messages = List.from(_messages)
            ..removeWhere((message) => message.id == temp.id);
          _streamingMessage = null;
        });
      }
      return '';
    }
    // 持久化纪律：仅完成时 put 一次（包含失败占位消息）。
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    // media 置空：AI 流式回复不携带附件，清掉以免残留脏数据落库。
    temp.media = null;
    await _appendMessage(temp);
    await _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    // 关系态与角色记忆只在成功回复后更新，失败占位不该污染长期状态。
    if (!failed) {
      // 私聊中 _directReplyCharacters 清空了 _pendingReplyIntents，但实际
      // 传进来的 intent 可能 targetId=null（来源待查），需同时兜底这两种情况。
      final effectiveIntent = (intent == null || intent.targetId == null)
          ? (_isDirectChat
              ? ReplyIntent(
                  speakerId: character.id,
                  action: ReplyAction.answer,
                  targetId: 'user',
                  lengthHint: ReplyLengthHint.normal,
                  toneHint: 'neutral',
                  reason: 'Direct chat reply',
                )
              : null)
          : intent;
      if (effectiveIntent != null) {
        await _persistRelationshipForIntent(
          character: character,
          intent: effectiveIntent,
          aiReplyMessage: temp,
          userMessage: userMessage,
          userSentiment: userSentiment,
        );
      }
    }
    if (_canTouchUi) setState(() => _streamingMessage = null);
    return fullContent;
  }

  /// 对失败的回复做一次非流式重试，成功返回内容，否则返回 null。
  ///
  /// 用非流式接口重试是为了简化逻辑：此时 UI 上已有占位气泡，只需拿到完整文本替换。
  Future<String?> _retryFailedReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Map<String, dynamic>> apiMessages,
    required bool userInitiated,
  }) async {
    final apiKey = await _credentialResolver.resolve(config);
    if (apiKey == null) return null;
    final result = await _aiGateway.sendChatMessageStreamed(
      apiKey: apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
      temperature: 0.75,
      purpose: AiRequestPurpose.retry,
      conversationId: widget.groupId,
      characterId: character.id,
      userInitiated: userInitiated,
    );
    if (result['success'] == true) {
      final content = result['message']?.toString().trim() ?? '';
      if (content.isNotEmpty) return content;
    }
    return null;
  }

  /// 当前生效的联网搜索策略：会话级覆盖优先于全局设置。
  WebSearchPolicy get _effectiveWebSearchPolicy =>
      _searchPolicyOverride ?? _governanceStore.globalSearchPolicy;

  /// 展示 AI 治理网关的告警（预算即将耗尽 / 被限流等）。
  void _showGovernanceWarning(String warning) {
    if (!_canTouchUi) return;
    AppToast.show(
      context,
      warning,
      icon: Icons.account_balance_wallet_outlined,
    );
  }

  /// 搜索策略对应的 AppBar 图标。
  IconData get _webSearchPolicyIcon => switch (_effectiveWebSearchPolicy) {
        WebSearchPolicy.off => Icons.public_off_rounded,
        WebSearchPolicy.ask => Icons.help_outline_rounded,
        WebSearchPolicy.auto => Icons.public_rounded,
      };

  /// `ask` 策略下逐次征求用户同意；明确展示查询内容与接收方，便于知情决定。
  Future<bool> _confirmWebSearch(String query) async {
    if (!_canTouchUi) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('允许本次联网搜索？'),
            content: Text(
              '查询将发送给 DuckDuckGo Instant Answer：\n\n$query',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('不搜索'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('仅本次允许'),
              ),
            ],
          ),
        ) ??
        // 用户点空白关闭对话框视为不允许（默认保守）。
        false;
  }

  /// 配置本会话的联网搜索策略（可选择跟随全局，即清除覆盖值）。
  Future<void> _configureWebSearchPolicy() async {
    final selection = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('本会话联网搜索'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'global'),
            child: Text('跟随全局（${_governanceStore.globalSearchPolicy.label}）'),
          ),
          for (final policy in WebSearchPolicy.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, policy.name),
              child: Text(policy.label),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text(
              '搜索会把查询发送到 DuckDuckGo Instant Answer；它不是完整网页搜索。',
            ),
          ),
        ],
      ),
    );
    if (selection == null) return;
    // 'global' 哨兵值表示清除会话级覆盖，回落到全局策略。
    final policy = selection == 'global'
        ? null
        : WebSearchPolicy.values.firstWhere(
            (value) => value.name == selection,
          );
    await _governanceStore.saveConversationSearchPolicy(
      widget.groupId,
      policy,
    );
    if (_canTouchUi) setState(() => _searchPolicyOverride = policy);
  }

  /// 联网搜索状态对应的用户可读提示文案。
  String get _webSearchStatusText => switch (_webSearchState.status) {
        SearchRunStatus.idle => '',
        SearchRunStatus.disabled => '联网搜索已关闭，本次未发送第三方请求',
        SearchRunStatus.awaitingConsent => '等待确认是否联网搜索',
        SearchRunStatus.denied => '本次联网搜索未获同意',
        SearchRunStatus.searching =>
          '正在通过 DuckDuckGo 搜索：${_webSearchState.query}',
        SearchRunStatus.completed =>
          '联网搜索完成 · ${_webSearchState.snapshot?.results.length ?? 0} 个来源',
        SearchRunStatus.noResults => '联网搜索完成，但资料不足',
        SearchRunStatus.failed => '联网搜索失败，回复将明确标注资料不足',
      };

  /// 展示上一次联网搜索命中的来源列表（查询词、时间、标题、摘要、链接）。
  void _showWebSearchSources() {
    final snapshot = _webSearchState.snapshot;
    if (snapshot == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('联网搜索来源'),
        content: SizedBox(
          width: 520,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('查询：${snapshot.query}'),
              Text('时间：${snapshot.searchedAt.toLocal()}'),
              if (snapshot.error != null) Text('状态：${snapshot.error}'),
              for (final result in snapshot.results)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(result.title),
                  subtitle: Text('${result.snippet}\n${result.url}'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 把搜索结果作为一条 system 消息注入到请求消息列表中。
  ///
  /// 插入位置在"最后一条 system 消息之后、第一条非 system 消息之前"，
  /// 既不破坏人格设定的优先级，也确保搜索资料在对话内容之前被模型看到。
  List<Map<String, dynamic>> _withWebSearchContext(
    List<Map<String, dynamic>> messages,
    WebSearchSnapshot? snapshot,
  ) {
    if (snapshot == null) return messages;
    final next = List<Map<String, dynamic>>.from(messages);
    final insertAt = next.indexWhere((message) => message['role'] != 'system');
    final contextMessage = {
      'role': 'system',
      'content': snapshot.toPromptContext(),
    };
    // insertAt <= 0：全是 system 消息（-1）或首条就是非 system（0），都插到最前。
    if (insertAt <= 0) {
      next.insert(0, contextMessage);
    } else {
      next.insert(insertAt, contextMessage);
    }
    return next;
  }

  /// 生成 agentic（工具调用）回复：跑 [AgentRuntime] 多步循环并落库结果。
  ///
  /// [resumeTask] 非空表示从检查点恢复；[workMode] 表示工作模式（更强的规划上下文
  /// 与工作区支持）；[cancelToken] / [workModeRun] 用于中途取消。
  ///
  /// 三种结束路径：
  /// - 等待工具审批 → 弹审批 UI，任务挂起；
  /// - 未完成（超步数/超时/出错）→ 写部分完成报告，并提示可恢复；
  /// - 完成 → 写最终消息（可能带生成的文件附件），更新用量与记忆。
  Future<String> _generateAgenticReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required String userMessage,
    List<MediaAttachment>? media,
    List<Message>? context,
    AgentTask? resumeTask,
    bool workMode = false,
    CancelToken? cancelToken,
    WorkModeRunHandle? workModeRun,
  }) async {
    // 并发兜底：同一角色已在执行 agentic 任务时，跳过本次重复调用，
    // 避免重入导致重复文件生成 / 重复消息。该角色的本轮任务由首次调用负责。
    if (_agenticRunningCharacterIds.contains(character.id)) {
      return '';
    }
    _agenticRunningCharacterIds.add(character.id);
    try {
      final task = resumeTask ??
          AgentTask(
            groupId: widget.groupId,
            characterId: character.id,
            userRequest: userMessage,
            requestedPermissions: character.toolPermissions,
            workModeTask: workMode,
          );
      task
        ..status = AgentTaskStatus.planning
        ..updatedAt = DateTime.now();
      // 先落库任务：即使 App 崩溃也能在下次打开时提供恢复入口。
      await _db.agentTaskBox.put(task.id, task);
      // 在聊天流里插入一条"正在执行"的进度消息，后续原地更新。
      await _upsertAgentProgressMessage(
        task,
        agentProgressMessageContent(characterName: character.name),
      );
      final runtime = _agentRuntimeFor(
        character: character,
        config: config,
        provider: provider,
        task: task,
        workMode: workMode,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );

      // 把附件（图片/文档）解析成文本描述并拼进请求，让 agent 能"看到"附件。
      final mediaEnhancedRequest =
          await AgentAttachmentContext.enhanceCurrentRequest(
        userRequest: userMessage,
        media: media,
      );
      final conversationHistory = await _agenticHistory(
        userMessage,
        messages: context,
      );
      final restoredRequests = resumeTask == null
          ? const <ToolRequest>[]
          : _restoredExecutedRequests(resumeTask);
      // 恢复场景：显式告知模型哪些工具操作已完成，防止重复写文件 / 重复执行副作用。
      if (restoredRequests.isNotEmpty) {
        conversationHistory.insert(0, {
          'role': 'system',
          'content': '这是从检查点恢复的任务。以下工具操作已经完成，'
              '不要重复执行：${restoredRequests.map((request) => request.toJsonString()).join('；')}',
        });
      }
      // 依据请求内容匹配该角色可用的技能（含是否需要新建技能的判断）。
      final skillResolution =
          CharacterSkillResolver.resolveFor(character, userMessage);

      Future<AgentRuntimeResult> runRuntime(
        List<Map<String, dynamic>> preparedHistory,
      ) {
        return runtime.run(
          character: character,
          skills: _agenticSkillsFor(
            character,
            userMessage,
            resolution: skillResolution,
          ),
          userRequest: mediaEnhancedRequest,
          conversationHistory: preparedHistory,
          priorExecutedRequests: restoredRequests,
          // 已有保存过的匹配技能时就不再强制创建，避免重复造轮子。
          forceSkillCreation: skillResolution.needsSkillCreation &&
              !_savedSkillMatchesRequest(character, userMessage),
          workModeContext:
              workMode ? WorkModePolicy.planningContext(character) : '',
        );
      }

      final result = workMode
          ? await runWithUnifiedMemory(
              selector: _memoryContextSelector,
              conversationHistory: conversationHistory,
              observerCharacterId: character.id,
              participantCharacterIds: _characters.map((c) => c.id).toList(),
              userMessage: userMessage,
              run: runRuntime,
            )
          : await runRuntime(conversationHistory);
      // 路径一：需要用户批准某个工具调用，任务挂起等待。
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        final approval = PendingAgentToolApproval(
          character: character,
          config: config,
          provider: provider,
          userRequest: mediaEnhancedRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
          conversationHistory: conversationHistory,
          task: task,
        );
        await _presentPendingAgentApproval(approval);
        return result.message;
      }
      await _finishAgentTask(task, result);
      // 路径二：未跑完（超步数 / 超时 / 失败）。有已执行操作时给出部分完成报告。
      if (result.status != AgentRuntimeStatus.completed) {
        final rawContent = result.executedToolRequests.isEmpty
            ? result.message
            : _partialCompletionReport(result);
        final content = _stripNamePrefix(rawContent, character.name);
        final message = Message(
          groupId: widget.groupId,
          senderId: character.id,
          senderType: 'ai',
          content: content,
        );
        await _appendMessage(message);
        // 已有实际进展才值得提示恢复，否则从头重跑更简单。
        if (result.executedToolRequests.isNotEmpty) {
          _scheduleAgentTaskRecovery();
        }
        return content;
      }
      // 路径三：正常完成。把工具产出的文件作为附件挂在消息上。
      final content = _stripNamePrefix(result.message, character.name);
      final attachments = await _attachmentsForAgentToolResult(
        character: character,
        result: result,
      );
      final message = Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: content,
        media: attachments.isEmpty ? null : attachments,
      );
      await _appendMessage(message);
      await _recordReplyUsage(character);
      _registerUserMentionIfNeeded(message);
      return content;
    } finally {
      // 无论成功失败都要释放并发标记，否则该角色将永久无法再触发 agentic。
      _agenticRunningCharacterIds.remove(character.id);
    }
  }

  /// 把 agentic 工具产出的工作区文件复制成可在聊天里查看的附件。
  ///
  /// 只处理 [AgentToolName.workspacePatch] 类工具：从 patch 与参数里收集目标路径，
  /// 经 [WorkspacePathGuard] 过滤掉越权路径（如 `../`），最多取 6 个文件。
  /// 每个文件按优先级取内容：工具回读 → patch 里的 content → 通过桥接重新读盘。
  Future<List<MediaAttachment>> _attachmentsForAgentToolResult({
    required AICharacter character,
    required AgentRuntimeResult result,
  }) async {
    final request = result.pendingToolRequest;
    final patchRequests = <ToolRequest>[
      ...result.executedToolRequests
          .where((request) => request.tool == AgentToolName.workspacePatch),
      if (request != null && request.tool == AgentToolName.workspacePatch)
        request,
    ];
    if (patchRequests.isEmpty) {
      return const [];
    }
    final requestedPaths = <String>[];

    /// 归一化并去重收集安全的相对路径；越权路径直接丢弃。
    void addPath(String raw) {
      final path = WorkspacePathGuard.normalizeToRelative(raw);
      if (!WorkspacePathGuard.isSafeRelativePath(path)) return;
      if (!requestedPaths.contains(path)) requestedPaths.add(path);
    }

    // 路径来源有两处：工具参数里的 path，以及 patch 文本里的 +++ / diff --git 行。
    for (final request in patchRequests) {
      final directPath = request.args['path'];
      if (directPath is String) {
        addPath(directPath);
      }
      for (final path in _pathsFromPatch(
        request.args['patch'] as String? ?? '',
      )) {
        addPath(path);
      }
    }
    // 不同工具用 ok / exitCode 表达成功，两者任一成立即视为成功。
    final resultOk =
        result.toolResult?['ok'] == true || result.toolResult?['exitCode'] == 0;
    final normalizedResultPath = result.toolResult?['path'] is String
        ? WorkspacePathGuard.normalizeToRelative(
            result.toolResult!['path'] as String,
          )
        : null;
    // 汇总"请求写入的路径"与"工具实际报告的路径"，得到最终产物清单。
    final paths = resolveAgentArtifactPaths(
      requestedPaths: requestedPaths,
      actualResultPath: normalizedResultPath,
      resultSucceeded: resultOk,
    ).where(WorkspacePathGuard.isSafeRelativePath).toList();
    if (paths.isEmpty) return const [];

    final attachments = <MediaAttachment>[];
    final bridge = LocalAgentBridgeClient();
    final workspaceTool = WorkspaceFileTool(
      bridge,
      conversationId: widget.groupId,
    );
    // 取最后一个带 content 的 patch：多次修改同一文件时后写的才是最终内容。
    final lastPatchWithContent = patchRequests.reversed.firstWhere(
      (request) => request.args['content'] is String,
      orElse: () => patchRequests.last,
    );
    // 上限 6 个附件，防止一次任务产出大量文件把聊天界面撑爆。
    for (final path in paths.take(6)) {
      try {
        // 优先级 1：工具执行后自己回读的内容，最可信。
        final readback = resultOk && path == normalizedResultPath
            ? result.toolResult!['readbackContent']
            : null;
        if (readback is String && readback.isNotEmpty) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(readback),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }
        // 优先级 2：patch 请求里携带的完整内容。
        final generatedContent = resultOk &&
                (path == normalizedResultPath || normalizedResultPath == null)
            ? lastPatchWithContent.args['content']
            : null;
        if (generatedContent is String && generatedContent.isNotEmpty) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(generatedContent),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }
        // Always read through the active bridge. Resolving [path] against the
        // app process cwd can attach a same-named file from the old workspace
        // immediately after the user switches project directories.
        // 优先级 3：通过桥接重新读盘（必须走桥接，不能按进程 cwd 解析）。
        final read = await workspaceTool.read(path);
        final content = read['content'];
        if (content is String) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(content),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
        }
      } catch (_) {
        // A single generated file failing to copy must not expose its path.
        // 单个文件复制失败不影响其余附件，也不把路径泄漏到 UI 上。
      }
    }
    return attachments;
  }

  /// 从 unified diff 文本里提取被修改的目标文件路径。
  ///
  /// 识别两种行：`+++ b/path`（新文件内容侧）与 `diff --git a/x b/y`（取 b 侧）。
  /// `/dev/null`（删除文件）与越权路径会被跳过。
  List<String> _pathsFromPatch(String patch) {
    final paths = <String>[];
    void addPath(String raw) {
      final path = raw.trim();
      if (path.isEmpty || path == '/dev/null') return;
      // 去掉 diff 惯例的 `b/` 前缀，得到工作区相对路径。
      final normalized = path.startsWith('b/') ? path.substring(2) : path;
      if (!WorkspacePathGuard.isSafeRelativePath(normalized)) return;
      if (!paths.contains(normalized)) paths.add(normalized);
    }

    for (final line in const LineSplitter().convert(patch)) {
      final plus = RegExp(r'^\+\+\+\s+(.+)$').firstMatch(line);
      if (plus != null) {
        addPath(plus.group(1) ?? '');
        continue;
      }
      final diff = RegExp(r'^diff --git\s+a/(.+?)\s+b/(.+)$').firstMatch(line);
      if (diff != null) {
        addPath(diff.group(2) ?? '');
      }
    }
    return paths;
  }

  /// 为一次 agentic 运行组装 [AgentRuntime]（补全回调、工具集、审批策略等）。
  ///
  /// 关键约定：
  /// - 输出 token 上限取"运行时偏好值"与"模型能力上限"的较小者；
  /// - 所有 LLM 调用都经 [_aiGateway]，由网关统一做预算预检与重试；
  /// - 工作模式下放开全部工具权限并使用工作模式的审批策略；
  /// - 停止检查绑定到本次 run 的句柄（而非共享标志），避免新 run 复活旧 run。
  AgentRuntime _agentRuntimeFor({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required AgentTask task,
    bool workMode = false,
    CancelToken? cancelToken,
    WorkModeRunHandle? workModeRun,
  }) {
    final bridge = LocalAgentBridgeClient();
    final capability = _aiGateway.capability(provider, config.modelName);
    final agentMaxTokens =
        min(AgentRuntime.preferredMaxOutputTokens, capability.maxOutput);
    final summaryMaxTokens =
        min(AgentRuntime.preferredSummaryOutputTokens, capability.maxOutput);
    return AgentRuntime(
      // agentic 主循环的补全回调：每一步"思考/决定调用哪个工具"都走这里。
      complete: (messages) async {
        final apiKey = await _credentialResolver.resolve(config);
        if (apiKey == null) {
          return const {'success': false, 'message': 'API 凭据不可用'};
        }
        return _aiGateway.sendChatMessageStreamed(
          apiKey: apiKey,
          provider: provider,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: messages,
          maxTokens: agentMaxTokens,
          receiveTimeout: AgentRuntime.completionTimeout,
          cancelToken: cancelToken,
          purpose: AiRequestPurpose.agent,
          conversationId: widget.groupId,
          characterId: character.id,
          requiresTools: true,
          userInitiated: true,
        );
      },
      workspaceFileTool: WorkspaceFileTool(
        bridge,
        conversationId: widget.groupId,
      ),
      browserContextTool: BrowserContextTool(bridge),
      skillCreateHandler: (args) => _saveGeneratedSkillFromArgs(
        character: character,
        args: args,
      ),
      skillDownloadHandler: (args) => _downloadExpertSkillFromArgs(
        character: character,
        args: args,
      ),
      // 关闭本地快速规划器：它原本会绕过 LLM 直接写死一个空壳模板，
      // 导致用户“生成个人主页”却只得到 <p>内容由AI生成</p>。关闭后由 LLM
      // 通过 planning prompt 生成真实文件内容（args.content 放完整内容）。
      enableLocalFilePlanner: false,
      // 统一网关负责逐次预算预检和重试；Runtime 不再嵌套重试。
      completionMaxRetries: 0,
      onProgress: (progress) => _persistAgentProgress(task, progress),
      // 上下文接近模型窗口时自动摘要压缩；阈值 = 窗口 - 输出预留，并夹到安全区间。
      contextWindowManager: ContextWindowManager(
        maxRetries: 0,
        thresholdTokens: (capability.contextWindow - agentMaxTokens)
            .clamp(4096, kContextCompressThresholdTokens)
            .toInt(),
        // 压缩用低温度、独立的 summary 预算通道，与主循环区分计费用途。
        complete: (contextMessages) async {
          final apiKey = await _credentialResolver.resolve(config);
          if (apiKey == null) {
            return const {'success': false, 'message': 'API 凭据不可用'};
          }
          return _aiGateway.sendChatMessage(
            apiKey: apiKey,
            provider: provider,
            customBaseUrl: config.customBaseUrl,
            model: config.modelName,
            messages: contextMessages,
            temperature: 0.3,
            maxTokens: summaryMaxTokens,
            cancelToken: cancelToken,
            purpose: AiRequestPurpose.summary,
            conversationId: widget.groupId,
            characterId: character.id,
            userInitiated: true,
          );
        },
      ),
      contextIsDirectChat: _isDirectChat,
      onContextSummary: _persistAgentContextSummary,
      approvalPolicy: workMode
          ? WorkModePolicy.requiresApproval
          : AgentRuntime.requiresApproval,
      // 工作模式默认授予全部工具权限（仍受审批策略约束）。
      grantedPermissions: workMode ? ToolPermission.values.toSet() : null,
      // per-run 停止状态：捕获本 run 的句柄，而非共享标志。新 run 的 beginRun
      // 不会把旧 run 复活，旧 run 在自己的检查点读到的是自己的停止状态。
      shouldCancel:
          workMode ? () => workModeRun?.isRequestedStop ?? false : null,
    );
  }

  /// Agentic 摘要只在当前运行时使用；长期记忆统一由 ObservationEntry 管理。
  Future<void> _persistAgentContextSummary(
    AICharacter character,
    ContextSummary summary,
  ) async {}

  /// 记录每个任务最后一次上报的进度，供 [_finishAgentTask] 生成终态 ✅ 摘要。
  /// 仅运行时态，不写入 Hive。
  final Map<String, AgentRuntimeProgress> _lastAgentProgress = {};

  /// P2：内存 Map，key=task.id，value=runStartedAtMs（进度总耗时起点）；
  /// 非持久化，不写入 Hive。供进度气泡实时耗时展示查表。
  final Map<String, int> _progressStartTimes = {};

  /// 每次 agent 进度上报：更新内存态、落库任务检查点、刷新进度气泡文案。
  ///
  /// 落库检查点是任务可恢复的前提——App 崩溃后靠它续跑。
  Future<void> _persistAgentProgress(
    AgentTask task,
    AgentRuntimeProgress progress,
  ) async {
    _lastAgentProgress[task.id] = progress;
    // P2：仅首个非空值写入，天然幂等（后续 progress.runStartedAtMs 一致，不漂移）。
    // 若上报未携带 runStartedAtMs，则回退到当前时刻，保证耗时可展示。
    _progressStartTimes[task.id] ??=
        progress.runStartedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    task.markProgress(
      step: progress.executedRequests.length,
      operations: progress.executedRequests
          .map((request) => request.toJsonString())
          .toList(),
      pendingToolJson: progress.pendingRequest?.toJsonString() ?? '',
    );
    await _db.agentTaskBox.put(task.id, task);
    final character = _db.aiCharacterBox.get(task.characterId);
    await _upsertAgentProgressMessage(
      task,
      agentProgressMessageContent(
        characterName: character?.name ?? 'AI',
        progress: progress,
      ),
    );
  }

  /// 原地更新（或首次插入）任务的进度气泡消息。
  ///
  /// 消息 id 由任务派生（[WorkModeTaskLifecycle.progressMessageId]），
  /// 保证多次进度上报复用同一条消息，而不是刷出一串进度消息。
  Future<void> _upsertAgentProgressMessage(
    AgentTask task,
    String content,
  ) async {
    final id = WorkModeTaskLifecycle.progressMessageId(task);
    final existing = _db.messageBox.get(id);
    if (existing != null) {
      existing.content = content;
      await _repository.updateMessage(existing);
      if (_canTouchUi) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == id);
          if (idx >= 0) {
            _messages[idx] = existing;
          }
        });
      }
      return;
    }
    await _appendMessage(Message(
      id: id,
      groupId: task.groupId,
      senderId: task.characterId,
      senderType: 'ai',
      content: content,
    ));
  }

  /// 结算一个 agentic 任务的终态：写入状态/摘要，并处理进度气泡的去留。
  ///
  /// 状态判定：完成 → completed；未完成但有已执行操作 → 部分完成（可恢复）；
  /// 什么都没做成 → failed。
  Future<void> _finishAgentTask(
    AgentTask task,
    AgentRuntimeResult result,
  ) async {
    task
      ..resultSummary = result.message
      ..updatedAt = DateTime.now()
      ..pendingToolRequestJson =
          result.pendingToolRequest?.toJsonString() ?? '';
    if (result.status == AgentRuntimeStatus.completed) {
      task
        ..status = AgentTaskStatus.completed
        ..lastError = '';
    } else if (result.executedToolRequests.isNotEmpty) {
      task.markPartiallyCompleted(result.message);
    } else {
      task
        ..status = AgentTaskStatus.failed
        ..lastError = result.message;
    }
    await _db.agentTaskBox.put(task.id, task);
    // 终态气泡处理：
    // - 工作模式：仅 cancelled 删除；completed/failed/partiallyCompleted 保留，
    //   并刷新为终态 ✅ 摘要（末行 ⏳→✅、去光标）。
    // - 非工作模式：沿用旧行为，终态即删除，避免普通回复路径出现残留气泡。
    final removeProgress = task.workModeTask
        ? WorkModeTaskLifecycle.shouldRemoveProgress(task.status)
        : task.isTerminal;
    if (removeProgress) {
      await _removeAgentProgressMessage(task);
    } else {
      final lastProgress = _lastAgentProgress[task.id];
      final character = _db.aiCharacterBox.get(task.characterId);
      // 终态冻结耗时：基于 _progressStartTimes 记录的运行起点计算秒数，
      // 烘焙进终态摘要首行（⏱ Ns），即使随后清理 map 也不丢失耗时展示。
      final startMs = _progressStartTimes[task.id];
      final elapsed = startMs == null
          ? null
          : ((DateTime.now().millisecondsSinceEpoch - startMs) / 1000).round();
      await _upsertAgentProgressMessage(
        task,
        agentProgressMessageContent(
          characterName: character?.name ?? 'AI',
          progress: lastProgress,
          finalResult: true,
          elapsedSeconds: elapsed,
        ),
      );
    }
    // 终态清理：移除内存表里的进度与耗时起点，避免随任务数无界增长。
    // 终态内容已烘焙耗时，气泡不再依赖该表 live 计算，清理后展示不受影响。
    _lastAgentProgress.remove(task.id);
    _progressStartTimes.remove(task.id);
  }

  /// 删除任务对应的进度气泡消息（内存与库中同时移除）。
  Future<void> _removeAgentProgressMessage(AgentTask task) async {
    final id = WorkModeTaskLifecycle.progressMessageId(task);
    await _repository.deleteMessage(id);
    if (_canTouchUi) {
      setState(() {
        _messages = List<Message>.from(_messages)
          ..removeWhere((message) => message.id == id);
      });
    }
  }

  /// 取消一个 agentic 任务：标记取消原因、落库、删除进度气泡并清理内存表。
  Future<void> _cancelAgentTask(
    AgentTask task, {
    required String reason,
  }) async {
    WorkModeTaskLifecycle.cancelTask(task, reason: reason);
    await _db.agentTaskBox.put(task.id, task);
    await _removeAgentProgressMessage(task);
    // 终态清理：cancelled 气泡已删，无需展示耗时，移除内存表条目避免无界增长。
    _lastAgentProgress.remove(task.id);
    _progressStartTimes.remove(task.id);
  }

  /// 生成"任务部分完成"的用户可读报告：列出已完成的工具操作与中断原因，
  /// 并提示可从检查点继续或放弃。
  String _partialCompletionReport(AgentRuntimeResult result) {
    final operations = result.executedToolRequests.map((request) {
      final path = request.args['path']?.toString();
      return path == null || path.isEmpty
          ? request.tool.wireName
          : '${request.tool.wireName}：$path';
    }).join('；');
    return '任务部分完成，已完成的工具操作和文件均已保留。\n'
        '已完成：$operations\n'
        '中断原因：${result.message}\n'
        '你可以选择“继续执行”从检查点恢复，或“放弃”结束任务。';
  }

  /// 把用户输入解释为对"待审批工具调用"的裁决并执行。
  ///
  /// 返回 true 表示这条输入已被当作审批指令消耗掉（不应再作为普通消息落库）。
  ///
  /// 三种裁决：
  /// - [WorkModeApprovalAction.reject]：跳过该工具，让 agent 换个方式继续；
  /// - [WorkModeApprovalAction.cancelPending]：用户发了新指令，取消旧任务
  ///   （返回 false，让这条新输入继续走正常发送流程）；
  /// - 其余（批准）：执行该工具并继续 agent 循环。
  ///
  /// 批准/拒绝后都可能再次遇到新的待审批工具，此时递归回到
  /// [_presentPendingAgentApproval] 形成多步审批链。
  Future<bool> _handlePendingAgentApproval(String text) async {
    final pending = _pendingAgentApproval;
    if (pending == null) return false;
    final action = WorkModeTaskLifecycle.actionForInput(text);
    if (action == WorkModeApprovalAction.reject) {
      // 拒绝：先清空待审批项，再让 runtime 跳过该工具继续推进。
      _pendingAgentApproval = null;
      final workModeRun = _workModeSession.beginRun();
      final cancelToken = workModeRun.token;
      _beginWorkActivity();
      try {
        final runtime = _agentRuntimeFor(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          task: pending.task,
          workMode: true,
          cancelToken: cancelToken,
          workModeRun: workModeRun,
        );
        final result = await runtime.skipRejectedTool(
          character: pending.character,
          request: pending.request,
          userRequest: pending.userRequest,
          priorExecutedRequests: pending.priorExecutedRequests,
          conversationHistory: pending.conversationHistory,
        );
        // 跳过后又碰到新的待审批工具：递归进入下一轮审批。
        if (result.status == AgentRuntimeStatus.waitingForApproval &&
            result.pendingToolRequest != null) {
          final nextApproval = PendingAgentToolApproval(
            character: pending.character,
            config: pending.config,
            provider: pending.provider,
            userRequest: pending.userRequest,
            request: result.pendingToolRequest!,
            priorExecutedRequests: result.executedToolRequests,
            conversationHistory: pending.conversationHistory,
            task: pending.task,
          );
          return _presentPendingAgentApproval(nextApproval);
        }
        await _finishAgentTask(pending.task, result);
        final content =
            _stripNamePrefix(result.message, pending.character.name);
        final attachments = await _attachmentsForAgentToolResult(
          character: pending.character,
          result: result,
        );
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: pending.character.id,
          senderType: 'ai',
          content: content,
          media: attachments.isEmpty ? null : attachments,
        ));
        return true;
      } finally {
        _workModeSession.finishRun(workModeRun);
        await _finishWorkActivityAndDispatchNext();
      }
    }
    if (action == WorkModeApprovalAction.cancelPending) {
      // 用户没在回答审批，而是发了新指令：取消旧任务，返回 false 让这条
      // 新输入按普通消息继续走发送流程。
      _pendingAgentApproval = null;
      await _cancelAgentTask(
        pending.task,
        reason: '用户发送了新的工作指令，旧审批任务已取消。',
      );
      _conversationController.complete();
      if (_canTouchUi) setState(() {});
      return false;
    }

    // 批准：执行该工具，然后继续 agent 循环。
    _pendingAgentApproval = null;
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    _beginWorkActivity();
    try {
      final runtime = _agentRuntimeFor(
        character: pending.character,
        config: pending.config,
        provider: pending.provider,
        task: pending.task,
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
      final result = await runtime.executeApprovedTool(
        character: pending.character,
        request: pending.request,
        userRequest: pending.userRequest,
        priorExecutedRequests: pending.priorExecutedRequests,
        conversationHistory: pending.conversationHistory,
      );
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        final nextApproval = PendingAgentToolApproval(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          userRequest: pending.userRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
          conversationHistory: pending.conversationHistory,
          task: pending.task,
        );
        return _presentPendingAgentApproval(nextApproval);
      }
      await _finishAgentTask(pending.task, result);
      // 工具跑完但模型没给文字总结时，也要给用户一个明确的完成反馈。
      final content = _stripNamePrefix(
        result.message.trim().isEmpty
            ? '[${pending.character.name} 工具执行完成，但没有返回内容]'
            : result.message.trim(),
        pending.character.name,
      );
      final attachments = await _attachmentsForAgentToolResult(
        character: pending.character,
        result: result,
      );
      final message = Message(
        groupId: widget.groupId,
        senderId: pending.character.id,
        senderType: 'ai',
        content: content,
        media: attachments.isEmpty ? null : attachments,
      );
      await _appendMessage(message);
      await _recordReplyUsage(pending.character);
      _registerUserMentionIfNeeded(message);
      return true;
    } finally {
      _workModeSession.finishRun(workModeRun);
      await _finishWorkActivityAndDispatchNext();
    }
  }

  /// 挂起任务并弹出工具审批对话框，把用户的选择交给 [_handlePendingAgentApproval]。
  ///
  /// 对话框被返回键关闭（decision 为 null）会被统一当作取消任务，
  /// 避免任务永久停在 waitingForApproval 检查点上。
  Future<bool> _presentPendingAgentApproval(
    PendingAgentToolApproval approval,
  ) async {
    _pendingAgentApproval = approval;
    // 从"恢复任务"路径进来时可能还没有活跃回合，这里补一个。
    if (!_conversationController.isBusy) {
      _conversationController.beginWork();
    }
    _conversationController.waitForApproval();
    if (_canTouchUi) setState(() {});
    final decision = await _showAgentApprovalDialog(
      approval.request,
      approval.character,
    );
    final action = WorkModeTaskLifecycle.actionForDialogDecision(decision);
    if (action == WorkModeApprovalAction.cancelPending) {
      // identical 校验：期间可能已被别的路径替换成新的审批项，只清自己那个。
      if (identical(_pendingAgentApproval, approval)) {
        _pendingAgentApproval = null;
      }
      await _cancelAgentTask(
        approval.task,
        reason: '用户关闭了工具审批对话框，任务已取消。',
      );
      _conversationController.complete();
      if (_canTouchUi) setState(() {});
      return true;
    }
    // 复用文本审批入口，保证弹层与打字两种方式走完全相同的后续逻辑。
    return _handlePendingAgentApproval(
      action == WorkModeApprovalAction.approve ? '批准' : '拒绝',
    );
  }

  /// 标记进入"工作执行中"状态（恢复已挂起的回合，或开启新回合）。
  void _beginWorkActivity() {
    if (!_conversationController.resumeWork()) {
      _conversationController.beginWork();
    }
    if (_canTouchUi) setState(() {});
  }

  /// 结束工作活动：仍有待审批项时停在"等待审批"，否则彻底完成本回合。
  void _finishWorkActivity() {
    if (_pendingAgentApproval != null) {
      _conversationController.waitForApproval();
    } else {
      _conversationController.complete();
    }
    if (_canTouchUi) setState(() {});
  }

  /// 以弹层（AlertDialog）形式请求用户批准/拒绝工具调用，替代原来的“打字批准”。
  ///
  /// 返回 `true`=批准，`false`=拒绝，`null`=返回键关闭或无法弹层。
  /// 所有入口都由 [_presentPendingAgentApproval] 将 null 统一转为任务取消，
  /// 避免多步审批遗留 waitingForApproval 检查点。
  Future<bool?> _showAgentApprovalDialog(
    ToolRequest request,
    AICharacter character,
  ) async {
    if (!_canTouchUi || !mounted) return null;
    final decision = await showDialog<bool>(
      context: context,
      // 不允许点遮罩关闭：审批是明确的二选一决定。
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('${character.name} 请求使用工具'),
        content: SingleChildScrollView(
          child: Text(
            '工具：${request.tool.wireName}\n'
            '范围：${WorkModePolicy.approvalSummary(request)}\n\n'
            '原因：${request.reason}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('拒绝'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('批准'),
          ),
        ],
      ),
    );
    return decision;
  }

  /// `skill_create` 工具的落地实现：把 LLM 给出的技能定义存为 [CharacterSkill]
  /// 并挂到该角色的 skillIds 上。
  ///
  /// 返回给 runtime 的 Map 即工具执行结果（`ok` / `error` 约定）。
  /// instructions 缺失时直接失败，因为没有步骤的技能没有意义。
  Future<Map<String, dynamic>> _saveGeneratedSkillFromArgs({
    required AICharacter character,
    required Map<String, dynamic> args,
  }) async {
    final instructionsRaw = args['instructions'];
    if (instructionsRaw is! List) {
      return {'ok': false, 'error': 'instructions_missing'};
    }
    // 兼容 LLM 可能用 permissions 或 requiredPermissions 两种键名。
    final permissionNames = (args['permissions'] is List
            ? args['permissions'] as List
            : args['requiredPermissions'] is List
                ? args['requiredPermissions'] as List
                : const [])
        .whereType<String>()
        .toSet();
    // 只保留枚举里真实存在的权限名，杜绝模型臆造出的权限被写入。
    final permissions = ToolPermission.values
        .where((permission) => permissionNames.contains(permission.name))
        .toList();
    final skill = CharacterSkill(
      characterId: character.id,
      name: args['name'] as String? ?? 'Generated Skill',
      domain: args['domain'] as String? ?? 'general',
      description: args['description'] as String? ?? '',
      instructions: instructionsRaw.whereType<String>().toList(),
      requiredPermissions: permissions,
    );
    await _db.characterSkillBox.put(skill.id, skill);
    if (!character.skillIds.contains(skill.id)) {
      character.skillIds = [...character.skillIds, skill.id];
      await _db.aiCharacterBox.put(character.id, character);
    }
    return {
      'ok': true,
      'skillId': skill.id,
      'name': skill.name,
      'permissions': permissions.map((p) => p.name).toList(),
    };
  }

  /// `skill_download` 工具的落地实现：从内置专家技能目录安装一个模板技能。
  ///
  /// templateId 缺省时按角色特征推荐一个。已安装过同名同领域技能则复用，
  /// 避免重复下载产生多份副本。
  Future<Map<String, dynamic>> _downloadExpertSkillFromArgs({
    required AICharacter character,
    required Map<String, dynamic> args,
  }) async {
    // 兼容 templateId / id 两种键名，都没有就按角色推荐。
    final templateId = args['templateId'] as String? ??
        args['id'] as String? ??
        _recommendedTemplateIdFor(character, args['domain'] as String?);
    if (templateId == null) {
      return {'ok': false, 'error': 'template_not_found'};
    }
    final template = ExpertSkillCatalog.findById(templateId);
    if (template == null) {
      return {
        'ok': false,
        'error': 'template_not_found',
        'templateId': templateId
      };
    }
    // 幂等：同名 + 同领域视为已安装，直接复用而不新建。
    final existing = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id &&
          skill.name == template.name &&
          skill.domain == template.domain,
    );
    final skill = existing.isNotEmpty
        ? existing.first
        : template.instantiateFor(character.id);
    if (existing.isEmpty) {
      await _db.characterSkillBox.put(skill.id, skill);
    }
    // 用 Set 合并，保证 skillIds 不出现重复项。
    final skillIds = <String>{...character.skillIds, skill.id};
    character.skillIds = skillIds.toList();
    await _db.aiCharacterBox.put(character.id, character);
    return {
      'ok': true,
      'skillId': skill.id,
      'templateId': template.id,
      'name': skill.name,
      'permissions': template.requiredPermissions.map((p) => p.name).toList(),
    };
  }

  /// 为角色推荐一个专家技能模板 id：优先匹配指定 [domain]，否则取推荐列表第一个。
  String? _recommendedTemplateIdFor(AICharacter character, String? domain) {
    final templates = SkillDownloadService.recommendedTemplatesFor(character);
    if (domain != null && domain.trim().isNotEmpty) {
      for (final template in templates) {
        if (template.domain == domain) return template.id;
      }
    }
    return templates.isEmpty ? null : templates.first.id;
  }

  /// 汇总本次 agentic 运行可用的技能：已安装技能 + 本次解析出的技能。
  ///
  /// 归属判断放宽为"skill.characterId 匹配 **或** 出现在 character.skillIds 里"，
  /// 兼容通过 skillIds 关联的共享技能。
  List<CharacterSkill> _agenticSkillsFor(
      AICharacter character, String userRequest,
      {CharacterSkillBundle? resolution}) {
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    return WorkModePolicy.resolveSkills(
      character: character,
      userRequest: userRequest,
      installedSkills: saved,
      resolvedSkills: resolution?.skills,
    );
  }

  /// 判断该角色已保存的技能中是否已有能覆盖本次请求的，
  /// 用于避免"每次都强制新建技能"。
  ///
  /// 匹配方式：技能描述包含整段请求，或技能名/领域拆出的关键词出现在请求里。
  /// `general` / `custom` 这类泛化词被排除，否则几乎任何请求都会误命中。
  bool _savedSkillMatchesRequest(
    AICharacter character,
    String userRequest,
  ) {
    final request = userRequest.toLowerCase().trim();
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    for (final skill in saved) {
      if (skill.description.toLowerCase().contains(request)) return true;
      final capability = '${skill.name} ${skill.domain}'.toLowerCase();
      // \u540c\u65f6\u5339\u914d\u82f1\u6587/\u6570\u5b57\u8bcd\uff08\u22652 \u5b57\u7b26\uff09\u4e0e\u4e2d\u6587\u8bcd\uff082~8 \u5b57\uff09\uff0c\u9002\u914d\u4e2d\u82f1\u6df7\u6392\u6280\u80fd\u540d\u3002
      final tokens = RegExp(r'[a-z0-9_+#.-]{2,}|[\u4e00-\u9fff]{2,8}')
          .allMatches(capability)
          .map((match) => match.group(0)!)
          .where((token) => token != 'general' && token != 'custom');
      if (tokens.any(request.contains)) return true;
    }
    return false;
  }

  /// 停止当前流式生成：取消订阅并保留已生成的（部分）内容落库。
  void _stopStreaming() {
    if (!_isStreaming) return;
    final runType = _conversationController.state.run?.type;
    // 先把最后一段增量刷进 UI，避免用户看到内容比实际生成的少。
    _flushStreamingUi();
    _conversationController.requestStop();
    unawaited(_streamingSession?.stop());
    // 若被停的是自动聊天回合，连调度器一起停，否则马上又会自动开口。
    if (runType == ConversationRunType.automatic) {
      _stopAutoChat();
    }
    if (_canTouchUi) {
      setState(() {
        _autoChatStatus = AutoChatStatus.paused;
      });
    }
  }

  /// 根据本次发言意图更新并落库角色关系状态（好感/亲密度等）。
  ///
  /// 目标对象取意图指定的 targetId；意图没指定但本轮由用户触发时视为对 `user`。
  /// 尊重记忆控制开关：全局关闭自动记忆、或该条关系被用户锁定时直接跳过。
  ///
  /// 不再直接写 per-group RelationshipState，改为通过全局事件 → 全局快照路径。
  /// [aiReplyMessage] 是 AI 实际回复的消息，用于关系事件的消息内容和事件溯源。
  Future<void> _persistRelationshipForIntent({
    required AICharacter character,
    required ReplyIntent intent,
    required Message aiReplyMessage,
    String? userMessage,
    UserMessageSentiment? userSentiment,
  }) async {
    final targetId = intent.targetId ?? (userMessage != null ? 'user' : null);
    if (targetId == null || targetId.isEmpty) return;
    final targetType = targetId == 'user'
        ? RelationshipTargetType.user
        : RelationshipTargetType.ai;
    if (!_memoryControls.automaticMemoryEnabled) return;

    await persistRelationshipEvents(
      service: _relationshipEventService,
      sourceCharacterId: character.id,
      targetId: targetId,
      targetType: targetType,
      message: aiReplyMessage,
      conversationId: widget.groupId,
      conversationNameSnapshot: _group?.name ?? '',
      allCharacters: _allGroupCharacters,
      visibleCharacterIds: _visibleCharacterIdsForMessage(),
      userSentiment: userSentiment,
    );
    _relationshipStates = _loader.stableGlobalRelationships();
  }

  /// 解析角色可用的 API 配置；未绑定或没有凭据时返回 null（视为不可回复）。
  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      final config = _db.apiConfigBox.get(character.apiConfigId);
      if (config?.hasCredential == true) return config;
    }
    return null;
  }

  /// 组装发给 LLM 的完整消息列表（群聊版；私聊转交 [_buildDirectApiMessages]）。
  ///
  /// system 消息按固定顺序层层叠加，顺序即优先级：
  /// 1. 群聊记忆摘要 → 2. 角色自我记忆 / 会话内压缩摘要 / 发言意图上下文
  /// → 3. 群聊场景与当前话题焦点 → 3.5 当前需回应的那条消息
  /// → 4. 自动聊天提示 → 5. 角色人设 → 6. 其他成员信息 → 历史对话。
  ///
  /// [supportsVision] 为 true 时图片附件会拼成多模态内容，否则退化为文字描述。
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
    return _buildApiMessages(
      character,
      context,
      userMessage,
      isAutoChat: isAutoChat,
      intent: intent,
      supportsVision: supportsVision,
      currentUserMessage: currentUserMessage,
      transientContextSummary: transientContextSummary,
    );
  }

  Future<List<Map<String, dynamic>>> _buildApiMessages(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false,
      ReplyIntent? intent,
      bool supportsVision = false,
      Message? currentUserMessage,
      String? transientContextSummary}) async {
    if (_isDirectChat) {
      return _buildDirectApiMessages(character, context, userMessage,
          supportsVision: supportsVision,
          currentUserMessage: currentUserMessage,
          transientContextSummary: transientContextSummary,
          isAutoChat: isAutoChat);
    }

    final msgs = <Map<String, dynamic>>[];

    // ── 1. 群聊记忆摘要 ───────────────────────────────────────────────
    final selectedGroupMemory = MemoryPromptSelector.groupSummary(_groupMemory);
    if (selectedGroupMemory.isNotEmpty) {
      msgs.add({'role': 'system', 'content': '【群聊记忆】$selectedGroupMemory'});
    }

    // ── 1.5 统一全局永久记忆（跨群/DM，按 observerCharacterId 读取） ──
    final permanentMemory = await _memoryContextSelector.select(
      observerCharacterId: character.id,
      participantCharacterIds: _characters.map((c) => c.id).toList(),
      currentTargetId: intent?.targetId,
      userMessage: userMessage,
    );
    if (permanentMemory.isNotEmpty) {
      msgs.add({'role': 'system', 'content': permanentMemory});
    }

    if (transientContextSummary?.isNotEmpty == true) {
      msgs.add({
        'role': 'system',
        'content': '【会话内压缩摘要】$transientContextSummary',
      });
    }

    if (intent != null) {
      msgs.add({
        'role': 'system',
        'content': HumanizedPromptBuilder.buildRelationContext(
          character: character,
          intent: intent,
          relationships: _relationshipStates,
          charactersById: {for (final c in _characters) c.id: c},
          ownerName: _ownerMentionName,
        ),
      });
    }

    // ── 3. 群聊场景 + 当前对话焦点 ─────────────────────────────────
    final groupName = _group?.name ?? '这个群';
    final groupTheme = _group?.theme ?? '日常聊天';
    final groupDescription = _group?.description ?? '';
    final announcement = _group?.announcement.trim() ?? '';
    final groupMemory = _groupMemory?.topicSummary ?? '';
    final isGroupAddressed = userMessage != null &&
        ChatActivityPolicy.isGroupAddressedMessage(userMessage);
    final scene = SceneBehavior.resolve(groupTheme);
    final scenarioPrompt = scene.scenarioPrompt;
    final recentContext = _extractRecentFocus(context);
    final nameById = {for (final c in _characters) c.id: c.name};
    final personaContext = ChatOrchestrator.buildPersonaGrowthContext(
      character: character,
      groupName: groupName,
      groupTheme: groupTheme,
      groupDescription: groupDescription,
      groupMemory: groupMemory,
    );
    msgs.add({
      'role': 'system',
      'content': '$personaContext\n\n'
          '你正在参加一个高活跃度群聊「$groupName」，主题是「$groupTheme」。'
          '${announcement.isEmpty ? '' : '群公告：$announcement。'}'
          '回复要像真实聊天群：自然接话、简短、有个人观点，可以顺手回应上一位成员或点名邀请别人，但不要每次都长篇总结。'
          '${HumanizedPromptBuilder.ownerMentionInstruction(_ownerMentionName)}'
          '当前真实时间：${DateTime.now().toLocal().toIso8601String()}。'
          '如果用户询问时间、日期、今天/明天/昨天，必须以这个真实时间为准。'
          '如果用户问到你不知道或可能过期的信息，必须明确说不确定，并建议或请求联网搜索；不要编造事实、价格、新闻、人物职位或链接。'
          '如果用户要求你贴图、发图或发送附件，可以在文字中自然说明“我附上了”，应用会把本轮产物作为图片或文件附件显示。'
          '如果正在执行协作任务，开发完成后要明确 @ 测试/验收角色，测试发现问题要 @ 开发角色并列出 BUG。'
          '重要：你的回复不要带自己的名字前缀（如「张三：」或「【张三】：」），直接说内容即可，头像和名字由界面自动显示。'
          '$scenarioPrompt'
          '$recentContext'
    });

    if (!scene.isGeneral) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      final candidates = otherCharacters.isEmpty
          ? '暂无其他 AI 角色'
          : otherCharacters
              .map((c) =>
                  '${c.name}，${c.age}岁，${c.role}，${c.personalityTags.join('/')} ')
              .join('；');
      final sceneContext = scene.roomContextPrompt(candidates);
      if (sceneContext.isNotEmpty) {
        msgs.add({'role': 'system', 'content': sceneContext});
      }
    }

    if (isGroupAddressed) {
      msgs.add({
        'role': 'system',
        'content': '【多人接力发言】用户这次是在问大家，不是只问你一个人。'
            '本轮会有多位群成员依次回应；你只代表自己说一小段，通常 1-2 句即可。'
            '如果你的角色没有特别新增观点，可以自然地短附和，比如“是的”“对”“+1”“我也这么想”，但尽量带一点你的角色语气。'
            '不要替其他人总结，也不要写成大段正式回答。'
      });
    }

    final collaborationPrompt = _collaborationPromptFor(
      userMessage: userMessage,
      currentCharacter: character,
    );
    if (collaborationPrompt.isNotEmpty) {
      msgs.add({'role': 'system', 'content': collaborationPrompt});
    }

    // ── 3.5 最后一条用户消息强调 ──────────────────────────────────
    if (context.isNotEmpty && !isAutoChat) {
      final lastUserMsg = context.lastWhere((m) => m.senderType == 'user',
          orElse: () => context.first);
      if (lastUserMsg.senderType == 'user') {
        final speakerName = nameById[lastUserMsg.senderId] ?? '一位群友';
        final truncated = lastUserMsg.content.length > 100
            ? '${lastUserMsg.content.substring(0, 100)}...'
            : lastUserMsg.content;
        msgs.add({
          'role': 'system',
          'content':
              '【当前任务】$speakerName 刚说："$truncated" —— 请作为 ${character.name} 针对这条消息做出自然回应。'
        });
      }
    } else if (context.isNotEmpty && isAutoChat) {
      final last = context.last;
      final speakerName = last.senderType == 'user'
          ? _ownerMentionName
          : nameById[last.senderId] ?? '一位群友';
      final truncated = last.content.length > 100
          ? '${last.content.substring(0, 100)}...'
          : last.content;
      msgs.add({
        'role': 'system',
        'content': '【当前任务】$speakerName 刚说："$truncated" —— '
            '请作为 ${character.name} 自然接住这条群聊，可以回应、追问、转给某位成员，或轻轻换个相关话题。'
      });
    }

    // ── 4. 自动聊天提示（仅 auto-chat 模式） ────────────────────────
    if (isAutoChat) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      if (otherCharacters.isNotEmpty) {
        final charInfo = otherCharacters
            .map((c) => '${c.name}(${c.role}, ${c.age}岁)')
            .join('、');
        msgs.add({
          'role': 'system',
          'content':
              '现在群聊中正在自动对话。在场的其他角色：$charInfo。请主动抛话题、接上一条发言，或把话题递给某位成员，让群显得有人气。'
        });
      }
    }

    // ── 5. 角色人设 ─────────────────────────────────────────────────
    msgs.add({'role': 'system', 'content': character.systemPrompt});

    // ── 6. 其他角色信息 ─────────────────────────────────────────────
    final otherCharacters2 =
        _characters.where((c) => c.id != character.id).toList();
    if (otherCharacters2.isNotEmpty) {
      final characterInfo = otherCharacters2
          .map((c) =>
              '${c.name}(${c.role}, ${c.age}岁, ${c.personalityTags.join('/')})')
          .join('；');
      msgs.add({'role': 'system', 'content': '群聊中的其他角色：$characterInfo'});
    }

    // ── 7. 聊天历史（最多 20 条） ──────────────────────────────────
    // 截断到最近 20 条：够维持话题连贯，又不会把 token 预算耗在远古历史上。
    final historyMessages = context.toList();
    final recentHistory = historyMessages.length > 20
        ? historyMessages.sublist(historyMessages.length - 20)
        : historyMessages;
    final documentContext = await _documentContextFor(
      userMessage,
      recentHistory,
      currentUserMessage,
    );
    if (documentContext.isNotEmpty) {
      msgs.add({'role': 'system', 'content': documentContext});
    }
    for (final m in recentHistory) {
      if (m.senderType == 'user') {
        // 真人用户消息 → user 角色；含媒体时按多模态策略生成 content。
        msgs.add({
          'role': 'user',
          'content': await prepareUserMessageContent(
            m,
            supportsVision: supportsVision,
            documentQuery: userMessage,
            includeDocumentContext: false,
          ),
        });
      } else if (m.senderId == character.id) {
        // 当前角色自己的消息 → assistant 角色（LLM 看到自己的历史发言）。
        msgs.add({'role': 'assistant', 'content': m.content});
      } else {
        // 其他 AI 角色的消息 → user 角色 + 发言者标注（LLM 知道这是别人说的话）。
        final speakerName = nameById[m.senderId] ?? '其他角色';
        final content = m.content.startsWith('【$speakerName】：')
            ? m.content
            : '【$speakerName】：${m.content}';
        msgs.add({'role': 'user', 'content': content});
      }
    }

    // ── 8. 当前用户消息（仅当历史为空时） ──────────────────────────
    if (userMessage != null && historyMessages.isEmpty) {
      // 历史为空时当前用户消息尚未进入 context，需直接基于其构建 content。
      dynamic content = userMessage;
      if (currentUserMessage != null) {
        content = await prepareUserMessageContent(
          currentUserMessage,
          supportsVision: supportsVision,
          documentQuery: userMessage,
          includeDocumentContext: false,
        );
      }
      msgs.add({'role': 'user', 'content': content});
    }

    return msgs;
  }

  /// 解析历史与当前消息里的文档附件，生成可注入 prompt 的文档上下文。
  ///
  /// 无查询词或无可解析附件时返回空串（不触发任何解析开销）。
  /// 解析过程可能较慢，通过 [DocumentProcessingToken] 支持用户中途取消，
  /// 并用 identical 校验确保只有"当前那次"解析才更新进度 UI。
  Future<String> _documentContextFor(
    String? query,
    List<Message> history,
    Message? current,
  ) {
    if (query == null || query.trim().isEmpty) return Future.value('');
    final messages = <Message>[...history];
    if (current != null && !messages.any((item) => item.id == current.id)) {
      messages.add(current);
    }
    final attachments = messages
        .expand((message) => message.media ?? const <MediaAttachment>[])
        .where(DocumentUnderstandingService.supports)
        .toList(growable: false);
    if (attachments.isEmpty) return Future.value('');
    final token = DocumentProcessingToken();
    _documentProcessingToken = token;
    _documentProcessingProgress = 0;
    if (_canTouchUi) setState(() {});
    return DocumentUnderstandingService.buildPromptContext(
      query: query,
      attachments: attachments,
      cancelToken: token,
      onProgress: (value) {
        if (_canTouchUi && identical(_documentProcessingToken, token)) {
          setState(() => _documentProcessingProgress = value);
        }
      },
    ).whenComplete(() {
      if (_canTouchUi && identical(_documentProcessingToken, token)) {
        setState(() => _documentProcessingToken = null);
      }
    });
  }

  /// 取消正在进行的文档解析。
  void _stopDocumentProcessing() {
    _documentProcessingToken?.cancel();
  }

  /// 当用户一次 @ 多位角色做项目类任务时，生成"开发/验收"分工的协作提示。
  ///
  /// 触发条件：@ 到 ≥2 个已知角色，且文本含项目类关键词（开发/测试/BUG/代码…）。
  /// 分工规则：名字/角色/标签里带测试、QA、验收、质量的角色任验收者
  /// （找不到则取最后一个被 @ 的），另一位任开发者；当前角色按身份拿到对应指令。
  /// 不满足条件时返回空串，表示不注入协作提示。
  String _collaborationPromptFor({
    required String? userMessage,
    required AICharacter currentCharacter,
  }) {
    if (userMessage == null || userMessage.trim().isEmpty) return '';
    final mentioned = parseMentionedCharacterIds(userMessage, _characters);
    // 少于两人不构成协作，无需分工。
    if (mentioned.length < 2) return '';
    final lower = userMessage.toLowerCase();
    final looksLikeProjectTask = lower.contains('开发') ||
        lower.contains('项目') ||
        lower.contains('测试') ||
        lower.contains('验收') ||
        lower.contains('bug') ||
        lower.contains('修复') ||
        lower.contains('代码') ||
        lower.contains('实现') ||
        lower.contains('build') ||
        lower.contains('test');
    if (!looksLikeProjectTask) return '';

    final mentionedCharacters = <AICharacter>[];
    for (final id in mentioned) {
      for (final character in _characters) {
        if (character.id == id) {
          mentionedCharacters.add(character);
          break;
        }
      }
    }
    if (mentionedCharacters.length < 2) return '';

    // 从被 @ 的人里挑测试/验收角色：名字、职位、性格标签任一命中关键词即可。
    AICharacter? verifier;
    for (final character in mentionedCharacters) {
      final text = '${character.name} ${character.role} '
              '${character.personalityTags.join(' ')}'
          .toLowerCase();
      if (text.contains('测试') ||
          text.contains('qa') ||
          text.contains('验收') ||
          text.contains('质量')) {
        verifier = character;
        break;
      }
    }
    // 没有明显的测试角色时，约定最后一个被 @ 的人做验收，其余第一个做开发。
    verifier ??= mentionedCharacters.last;
    final executor = mentionedCharacters
        .firstWhere((character) => character.id != verifier!.id);

    // 同一段协作提示会发给每个角色，但"你的职责"随当前角色而变。
    final currentRole = currentCharacter.id == executor.id
        ? '你是本次任务的开发/执行者。先给出实现计划或交付内容；完成后必须 @${verifier.name} 请他验收。'
        : currentCharacter.id == verifier.id
            ? '你是本次任务的测试/验收者。等待开发者交付后进行验收；发现问题要明确 @${executor.name} 并列出 BUG 和复现/修改建议。'
            : '你不是主责角色，只在被点名时补充，不要抢主责。';

    return '【AI 协作任务】用户一次 @ 了多位 AI 做一个项目/任务。'
        '分工：${executor.name}=开发/执行，${verifier.name}=测试/验收。'
        '$currentRole'
        '不要替对方完成职责；用 @ 推动下一棒。';
  }

  /// 组装私聊场景的 LLM 消息列表。
  ///
  /// 与群聊版的区别：没有群成员/场景/协作提示，改为注入私聊人格上下文，
  /// 且历史里只保留"用户消息 + 该角色自己的消息"（私聊本就只有两方）。
  Future<List<Map<String, dynamic>>> _buildDirectApiMessages(
    AICharacter character,
    List<Message> context,
    String? userMessage, {
    bool supportsVision = false,
    Message? currentUserMessage,
    String? transientContextSummary,
    bool isAutoChat = false,
  }) async {
    final msgs = <Map<String, dynamic>>[];
    // ── 1. 全局永久记忆（跨群/DM，按 observerCharacterId 读取） ─────────
    final permanentMemory = await _memoryContextSelector.select(
      observerCharacterId: character.id,
      participantCharacterIds: [character.id],
      currentTargetId: 'user',
      userMessage: userMessage,
    );
    if (permanentMemory.isNotEmpty) {
      msgs.add({'role': 'system', 'content': permanentMemory});
    }

    if (transientContextSummary?.isNotEmpty == true) {
      msgs.add({
        'role': 'system',
        'content': '【会话内压缩摘要】$transientContextSummary',
      });
    }

    // 私聊关系行为准则：由 MemoryContextSelector 注入关系数值，
    // 这里仅补充行为规则（冷漠/热情/拒绝），不重复输出亲近/信任/摩擦等。
    for (final r in _relationshipStates.where(
      (r) =>
          r.sourceCharacterId == character.id &&
          r.targetType == RelationshipTargetType.user,
    )) {
      if (r.affinity < -20 && r.friction > 60) {
        msgs.add({
          'role': 'system',
          'content': '行为准则：你和用户关系很差，你会不耐烦、懒得认真回应，语气带刺、想尽快结束对话。',
        });
        break;
      } else if (r.affinity < 0 || r.friction > 50) {
        msgs.add({
          'role': 'system',
          'content': '行为准则：你和用户关系一般，不用刻意讨好，保持自然距离。',
        });
        break;
      }
    }

    msgs.add({
      'role': 'system',
      'content': DirectChatSession.buildPromptContext(
        character: character,
        ownerName: _ownerMentionName,
      ),
    });
    msgs.add({
      'role': 'system',
      'content': '当前真实时间：${DateTime.now().toLocal().toIso8601String()}。'
          '涉及当前事实、新闻、价格、职位、规则或你不知道的内容时，不要编造；请说明不确定，并建议联网搜索或让用户授权搜索。'
          '如果用户要求你贴图、发图或发送附件，可以自然说明“我附上了”，应用会把本轮产物作为图片或文件附件显示。'
          '${isAutoChat ? '用户暂时没有回复你，你主动发一条消息找他聊天，可以问问他近况、分享一件事或开启新话题，但不要重复之前说过的话。' : '用户刚给你发了一条消息，请自然回应。'}'
          '私聊主动找用户时最多连续三条，之后等待用户回复。',
    });
    msgs.add({'role': 'system', 'content': character.systemPrompt});

    // 私聊同样只保留最近 20 条历史。
    final recentHistory =
        context.length > 20 ? context.sublist(context.length - 20) : context;
    final documentContext = await _documentContextFor(
      userMessage,
      recentHistory,
      currentUserMessage,
    );
    if (documentContext.isNotEmpty) {
      msgs.add({'role': 'system', 'content': documentContext});
    }
    for (final message in recentHistory) {
      if (message.senderType == 'user') {
        // 含媒体时按多模态策略生成 content。
        msgs.add({
          'role': 'user',
          'content': await prepareUserMessageContent(
            message,
            supportsVision: supportsVision,
            documentQuery: userMessage,
            includeDocumentContext: false,
          ),
        });
      } else if (message.senderId == character.id) {
        msgs.add({'role': 'assistant', 'content': message.content});
      }
      // 其余（例如系统消息 / 别的角色残留消息）在私聊语境下忽略。
    }

    if (userMessage != null && recentHistory.isEmpty) {
      // 历史为空时当前用户消息尚未进入 context，直接基于其构建 content。
      dynamic content = userMessage;
      if (currentUserMessage != null) {
        content = await prepareUserMessageContent(
          currentUserMessage,
          supportsVision: supportsVision,
          documentQuery: userMessage,
          includeDocumentContext: false,
        );
      }
      msgs.add({'role': 'user', 'content': content});
    }

    return msgs;
  }

  /// 从最近的消息中提取对话焦点，帮助 AI 理解"现在在聊什么"。
  /// 取最近 3 条消息的内容拼成一段焦点摘要，注入到 system prompt 中。
  String _extractRecentFocus(List<Message> messages) {
    return ChatOrchestrator.extractRecentFocus(messages);
  }

  /// 移除 LLM 回复中可能附带的名字前缀（如「张三：」「【张三】：」）。
  /// UI 已独立显示角色名，内容中不应重复。
  String _stripNamePrefix(String content, String characterName) {
    return ChatOrchestrator.stripNamePrefix(content, characterName);
  }

  /// 落库并追加一条消息到列表末尾，然后滚动到底部。
  ///
  /// AI 消息会顺带推进已读位置——用户正看着这条消息，没有理由算作未读。
  Future<void> _appendMessage(Message message) async {
    final visibleIds = _visibleCharacterIdsForMessage();
    if (message.visibleToCharacterIds.isEmpty) {
      message.visibleToCharacterIds = List<String>.from(visibleIds);
    }
    await _repository.persistNewMessage(message);
    if (message.senderType == 'ai') {
      await _markCurrentConversationRead(throughMessage: message);
    }
    // 本地记忆/遗忘/关系必须在返回前落库；只有 LLM 提炼后台执行。
    await _observationEntry.observeDeterministic(
      message: message,
      visibleCharacterIds: visibleIds,
      conversationId: widget.groupId,
      conversationNameSnapshot:
          _isDirectChat ? _directChatName() : (_group?.name ?? ''),
      allCharacters: _allGroupCharacters,
    );
    _relationshipStates = _loader.stableGlobalRelationships();
    unawaited(_observationEntry
        .distillMessage(
          message: message,
          conversationId: widget.groupId,
          conversationNameSnapshot:
              _isDirectChat ? _directChatName() : (_group?.name ?? ''),
          allCharacters: _allGroupCharacters,
          isGroupChat: !_isDirectChat,
          userProfile: _userProfile,
        )
        .catchError((_) {}));
    if (!_canTouchUi) return;
    final existingIndex =
        _messages.indexWhere((existing) => existing.id == message.id);
    setState(() {
      if (existingIndex < 0) {
        _messages = List.from(_messages)..add(message);
        _totalMessageCount++;
      } else {
        _messages = List.from(_messages)..[existingIndex] = message;
      }
    });
    _scrollToBottom();
  }

  /// 消息发送时在场/可见的 AI 角色 ID 列表。
  ///
  /// 群聊：所有活跃成员；私聊：只有目标角色。
  List<String> _visibleCharacterIdsForMessage() {
    if (_isDirectChat) {
      final charId = _directCharacterId;
      return charId != null && _characters.any((c) => c.id == charId)
          ? [charId]
          : _characters.map((c) => c.id).toList();
    }
    return _characters.map((c) => c.id).toList();
  }

  String _directChatName() {
    final charId = _directCharacterId;
    if (charId == null) return '私聊';
    for (final c in _allGroupCharacters) {
      if (c.id == charId) return c.name;
    }
    return '私聊';
  }

  /// 用户在群里被称呼时使用的名字：取人物卡显示名，为空则用"我"。
  String get _ownerMentionName {
    final profile = _userProfile;
    return profile?.displayName.trim().isNotEmpty ?? false
        ? profile!.displayName.trim()
        : '我';
  }

  /// 若这条 AI 消息 @ 到了用户，登记为"待查看的 @我"以显示提醒横幅。
  ///
  /// 用户正在看这个会话时不登记——他已经看到了，弹提醒只是噪音。
  void _registerUserMentionIfNeeded(Message message) {
    if (!_canTouchUi || message.senderType != 'ai') return;
    if (ConversationPresenceService.instance.isActive(widget.groupId)) return;
    if (!ChatActivityPolicy.contentMentionsUser(
      message.content,
      _ownerMentionName,
    )) {
      return;
    }
    if (_pendingUserMentionMessageIds.contains(message.id)) return;
    setState(() => _pendingUserMentionMessageIds.add(message.id));
  }

  /// 标记已读时清掉"@我"横幅（带 _canTouchUi 守卫，可在异步流程中调用）。
  void _clearActiveUserMentionBanner() {
    if (!_canTouchUi || _pendingUserMentionMessageIds.isEmpty) return;
    setState(() => _pendingUserMentionMessageIds.clear());
  }

  /// 用户手动点"忽略"时清空全部待查看的 @我 提醒。
  void _clearUserMentions() {
    if (_pendingUserMentionMessageIds.isEmpty) return;
    setState(() => _pendingUserMentionMessageIds.clear());
  }

  /// 跳转到下一条 @我 的消息并高亮。
  ///
  /// 逐个出队：若目标消息已不在当前分页窗口内（index < 0）则跳过继续找下一条，
  /// 全部找不到时也要 setState 一次，让横幅上的计数归零。
  void _jumpToNextUserMention() {
    while (_pendingUserMentionMessageIds.isNotEmpty) {
      final messageId = _pendingUserMentionMessageIds.removeAt(0);
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index < 0) continue;
      _highlightMessageTemporarily(messageId);
      _scrollToMessageIndex(index);
      return;
    }
    if (_canTouchUi) setState(() {});
  }

  /// 临时高亮某条消息 2 秒（跳转定位后帮助用户找到目标）。
  ///
  /// 定时器回调里比对 messageId，避免连续跳转时旧定时器误清新高亮。
  void _highlightMessageTemporarily(String messageId) {
    if (!_canTouchUi) return;
    setState(() => _highlightedMentionMessageId = messageId);
    _mentionHighlightTimer?.cancel();
    _mentionHighlightTimer = Timer(const Duration(seconds: 2), () {
      if (_canTouchUi && _highlightedMentionMessageId == messageId) {
        setState(() => _highlightedMentionMessageId = null);
      }
    });
  }

  /// 按策略条件（消息量、距上次摘要的间隔等）更新群周记忆摘要。
  ///
  /// 私聊没有群记忆，直接返回；用户手动锁定群记忆时也不自动覆盖。
  Future<void> _maybeUpdateMemory() async {
    if (_isDirectChat) return;
    if (!_memoryControls.canAutoUpdateGroup(_groupMemory)) return;
    final now = DateTime.now();
    if (!ChatOrchestrator.shouldUpdateGroupMemory(
      messageCount: _totalMessageCount,
      hasExistingSummary: _groupMemory?.topicSummary.trim().isNotEmpty ?? false,
      lastSummaryAt: _groupMemory?.lastSummaryAt,
      now: now,
    )) {
      return;
    }

    // Mark before async work to prevent concurrent summary generation.
    // 先占位写入 lastSummaryAt：后续 await 期间若又触发一轮，
    // shouldUpdateGroupMemory 会因间隔不足而拒绝，避免并发生成重复摘要。
    if (_groupMemory != null) {
      _groupMemory!.lastSummaryAt = now;
      await _groupMemory!.save();
    }

    final topicHint = ChatOrchestrator.recentDialogueTranscript(
      messages: _messages,
      senderNames: _senderNameMap(),
      maxMessages: 18,
      maxChars: 1800,
    );
    if (topicHint.trim().isEmpty) return;

    final summary = await _generateSummary(
      topicHint,
      previousSummary: _groupMemory?.topicSummary ?? '',
    );
    if (summary.isNotEmpty && _groupMemory != null) {
      _groupMemory!.topicSummary = summary;
      await _groupMemory!.save();
      setState(() {});
    }
  }

  /// 调用 LLM 把「旧群记忆 + 最近对话」合并成新的群体记忆摘要。
  ///
  /// 借用第一个角色的 API 配置发请求（摘要与具体人格无关）；
  /// 无可用配置或调用失败时返回空串，调用方据此跳过更新。
  Future<String> _generateSummary(
    String recentText, {
    String previousSummary = '',
  }) async {
    // 摘要只需要一个可用的 API 通道，借用首个角色的配置即可。
    final character = _characters.isNotEmpty ? _characters.first : null;
    if (character == null) return '';

    final config = _resolveApiConfig(character);
    if (config == null) return '';
    final apiKey = await _credentialResolver.resolve(config);
    if (apiKey == null) return '';

    final msgs = [
      {
        'role': 'system',
        'content': '你是群聊长期记忆记录员。请把旧摘要和最近对话合并成可供后续角色扮演使用的群体记忆。'
            '保留正在发展的关系、共同话题、未解决的问题和群氛围，不要记录 API、模型或系统提示。'
            '输出 2-4 句话，不超过 160 字。'
      },
      {
        'role': 'user',
        'content':
            '旧群记忆：${previousSummary.trim().isEmpty ? '暂无' : previousSummary.trim()}'
                '\n\n最近对话：\n$recentText\n\n请输出更新后的群体记忆：'
      }
    ];

    final result = await _aiGateway.sendChatMessage(
      apiKey: apiKey,
      provider: ApiProvider.values.firstWhere((p) => p.name == config.provider,
          orElse: () => ApiProvider.deepseek),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: msgs,
      temperature: 0.4,
      purpose: AiRequestPurpose.summary,
      conversationId: widget.groupId,
      characterId: character.id,
    );
    if (result['success'] ?? false) {
      return result['message']?.toString().trim() ?? '';
    }
    return '';
  }

  /// senderId → 展示名的映射（用于把消息转写成带说话人的文字稿）。
  ///
  /// 含停用成员，历史消息里的角色才不会显示成未知；`user` 映射为群主名。
  Map<String, String> _senderNameMap() {
    return {
      'user': _ownerMentionName,
      for (final c in _allGroupCharacters) c.id: c.name,
      for (final c in _characters) c.id: c.name,
    };
  }

  /// 该角色本轮是否有资格发言（委托 [ReplyEligibilityPolicy]）。
  bool _isEligibleToReply(AICharacter character) {
    return _replyEligibility.isEligible(character);
  }

  /// 该角色不能发言的具体原因（未配置 API、超出频率上限等）。
  ReplyBlockReason? _blockReasonFor(AICharacter character) {
    return _replyEligibility.blockReasonFor(character);
  }

  /// 当前有资格发言的活跃角色。
  List<AICharacter> get _eligibleCharacters =>
      _characters.where(_isEligibleToReply).toList();

  /// 取这批角色中第一个可解释的阻塞原因，用于给用户一条明确提示。
  ReplyBlockReason? _firstBlockReason(List<AICharacter> characters) {
    return _replyEligibility.firstBlockReason(characters);
  }

  /// 记录一次发言用量：由数据库按角色串行读取、递增并持久化。
  Future<void> _recordReplyUsage(AICharacter character) {
    return _db.recordCharacterReplyUsage(character.id);
  }

  /// 模拟"打字/思考"的发言间隔，让多角色接话有真实节奏。
  ///
  /// [fast] 用于被 @ 点名的场景——几乎立刻应答（180ms）；
  /// 否则按内容长度加随机抖动计算延迟。
  Future<void> _delay(String content, {bool fast = false}) async {
    if (fast) {
      await Future.delayed(const Duration(milliseconds: 180));
      return;
    }
    await Future.delayed(ChatActivityPolicy.replyDelayForContent(
      content,
      random: _random,
    ));
  }

  /// 移除 @ 成员弹窗并复位其全部相关状态。
  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _showMentionPopup = false;
    _filteredMentionMembers = [];
    _mentionSelectedIndex = 0;
    _mentionSearchController.clear();
  }

  /// 在输入框上方弹出 @ 成员选择浮层。
  ///
  /// 用输入框的 [RenderBox] 实时定位：水平居中于输入框并夹在屏幕内，
  /// 垂直放在输入框上方，高度受输入框上方剩余空间限制（120~260px）。
  void _showMentionOverlay(Offset globalPosition) {
    if (_showMentionPopup) return;
    _showMentionPopup = true;
    _mentionSelectedIndex = 0;

    _mentionOverlay = OverlayEntry(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        // 用 RenderBox 精确定位：找到输入框在屏幕上的位置，弹窗放在其上方。
        final renderBox =
            _inputFieldKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) return const SizedBox.shrink();
        final inputGlobalPos = renderBox.localToGlobal(Offset.zero);
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final inputTop = inputGlobalPos.dy;
        final inputLeft = inputGlobalPos.dx;
        final inputWidth = renderBox.size.width;

        // 弹窗宽度跟随输入框，但保持紧凑，避免遮住整页。
        final popupWidth = min(inputWidth, 280.0);
        // 水平居中于输入框。
        var left = inputLeft + (inputWidth - popupWidth) / 2;
        // 不超出屏幕左右边界。
        left = left.clamp(8.0, max(8.0, screenWidth - popupWidth - 8.0));
        final popupMaxHeight = min(max(inputTop - 16, 120.0), 260.0);

        final content = _buildMentionPopupContent(cs);
        return Positioned(
          left: left,
          // bottom 相对屏幕底部计算，使浮层贴在输入框上沿再留 8px 间隙。
          bottom: screenHeight - inputTop + 8,
          width: popupWidth,
          child: TapRegion(
            // 点击浮层外任意处即收起。
            onTapOutside: (_) => _hideMentionOverlay(),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: cs.surfaceContainerHighest,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: popupMaxHeight),
                child: content,
              ),
            ),
          ),
        );
      },
    );

    final overlay = Overlay.of(context);
    overlay.insert(_mentionOverlay!);
  }

  /// 构建 @ 弹窗内容：标题栏（含人数）+ 搜索框 + 成员列表。
  Widget _buildMentionPopupContent(ColorScheme cs) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280, maxHeight: 260),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(Icons.alternate_email_rounded,
                    size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('提到谁',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
                const Spacer(),
                Text('${_allGroupCharacters.length} 人',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: TextField(
              controller: _mentionSearchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: '搜索名称、角色或标签…',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 16, color: cs.onSurfaceVariant),
                isDense: true,
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.6)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.6)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: cs.primary.withValues(alpha: 0.6)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: _onMentionSearchChanged,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
          // 成员列表（Expanded 保证 ListView 有可滚动的空间）
          Expanded(
            child: _buildMentionList(cs),
          ),
        ],
      ),
    );
  }

  /// @ 弹窗内搜索框的过滤逻辑：匹配名称 / 角色 / 个性标签。
  void _onMentionSearchChanged(String query) {
    final q = query.trim();
    if (q.isEmpty) {
      _filteredMentionMembers = List.from(_allGroupCharacters);
    } else {
      _filteredMentionMembers = _allGroupCharacters
          .where((c) =>
              c.name.contains(q) ||
              c.role.contains(q) ||
              c.personalityTags.any((tag) => tag.contains(q)))
          .toList();
    }
    _mentionSelectedIndex = 0;
    _mentionOverlay?.markNeedsBuild();
  }

  /// 是否展示 `@all` 选项：搜索为空，或搜索词是 all/所有人/全部 的前缀。
  bool get _showMentionAllOption {
    final q = _mentionSearchController.text.trim().toLowerCase();
    return q.isEmpty ||
        'all'.contains(q) ||
        '所有人'.contains(q) ||
        '全部'.contains(q);
  }

  /// 构建 @ 候选列表；`@all` 占据首项，故成员下标需整体后移一位。
  Widget _buildMentionList(ColorScheme cs) {
    final showAll = _showMentionAllOption;
    if (_filteredMentionMembers.isEmpty && !showAll) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: Text('无匹配角色', style: TextStyle(fontSize: 14))),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _filteredMentionMembers.length + (showAll ? 1 : 0),
      itemBuilder: (ctx2, i) {
        if (showAll && i == 0) {
          return _buildMentionAllTile(cs, selected: _mentionSelectedIndex == 0);
        }
        final memberIndex = showAll ? i - 1 : i;
        final c = _filteredMentionMembers[memberIndex];
        final pColor = _senderColor(c);
        final selected = i == _mentionSelectedIndex;
        return InkWell(
          onTap: () => _insertMention(c),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pColor.withValues(alpha: 0.14),
                    border: Border.all(
                        color: pColor.withValues(alpha: 0.3), width: 1.2),
                  ),
                  child: Center(
                    child: Text(
                      c.avatar.isNotEmpty ? c.avatar : c.name[0],
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: pColor),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                          overflow: TextOverflow.ellipsis),
                      if (c.role.isNotEmpty)
                        Text(c.role,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建 `@all`（提到所有群成员）这一项。
  Widget _buildMentionAllTile(ColorScheme cs, {required bool selected}) {
    return InkWell(
      onTap: _insertMentionAll,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary.withValues(alpha: 0.14),
                border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Icon(Icons.groups_rounded, size: 18, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@all',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface),
                      overflow: TextOverflow.ellipsis),
                  Text('提到所有群成员',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// @ 弹窗打开时的键盘导航：↑↓ 选择、回车插入、Esc 关闭。
  KeyEventResult _handleMentionKeyEvent(KeyEvent event) {
    if (!_showMentionPopup) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    // @all 占一项，故总选项数 = 成员数 + (是否展示 @all)。
    final optionCount =
        _filteredMentionMembers.length + (_showMentionAllOption ? 1 : 0);
    if (optionCount <= 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex + 1).clamp(0, optionCount - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex - 1).clamp(0, optionCount - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // 回车确认当前高亮项：首项可能是 @all，其余按偏移取成员。
      if (_showMentionAllOption && _mentionSelectedIndex == 0) {
        _insertMentionAll();
      } else {
        final memberIndex = _showMentionAllOption
            ? _mentionSelectedIndex - 1
            : _mentionSelectedIndex;
        if (memberIndex >= 0 && memberIndex < _filteredMentionMembers.length) {
          _insertMention(_filteredMentionMembers[memberIndex]);
        }
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      _hideMentionOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 插入 `@all `（提到所有群成员）。
  void _insertMentionAll() {
    _insertMentionText('@all ');
  }

  /// 插入对某个角色的 @ 引用。
  void _insertMention(AICharacter character) {
    _insertMentionText('@${character.name} ');
  }

  /// 用 [mentionText] 替换掉光标前那段正在输入的 `@查询词`。
  ///
  /// 从光标前一位向左找最近的 `@` 作为替换起点（找不到就从头替换），
  /// 插入后把光标移到 @ 文本之后，并立刻把焦点还给输入框。
  void _insertMentionText(String mentionText) {
    final text = _textController.text;
    int cursorPos = _textController.selection.baseOffset;
    // baseOffset 为 -1 表示无选区（未聚焦），退化为在末尾插入。
    if (cursorPos < 0) cursorPos = text.length;

    final searchEnd = cursorPos > 0 ? cursorPos - 1 : 0;
    int atPos = text.lastIndexOf('@', searchEnd);
    if (atPos < 0) atPos = 0;

    final newText =
        '${text.substring(0, atPos)}$mentionText${text.substring(cursorPos)}';
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: atPos + mentionText.length),
    );

    // Overlay dismissal can steal focus; restore it immediately.
    _inputFocusNode.requestFocus();
    _hideMentionOverlay();
  }

  /// 判断光标是否处于「@后跟非空格字符」的输入状态（即应显示 @ 弹窗）。
  bool _isInMentionQuery(String text, int cursorPos) {
    if (cursorPos <= 0) return false;
    final textBeforeCursor = text.substring(0, cursorPos);
    final atIndex = textBeforeCursor.lastIndexOf('@');
    if (atIndex < 0) return false;
    final query = textBeforeCursor.substring(atIndex + 1);
    return !query.contains(' ');
  }

  /// 输入框文本变化时维护 @ 弹窗的显示与候选过滤。
  ///
  /// 私聊没有 @ 概念，直接返回。弹窗未开时检测是否刚进入 `@查询` 状态并弹出；
  /// 已开时按光标前的 `@查询词` 重新过滤，遇到空格或删掉 `@` 则收起。
  void _handleTextChanged(String text) {
    if (_isDirectChat) return;
    if (!_showMentionPopup) {
      final cursorPos = _textController.selection.baseOffset;
      if (_isInMentionQuery(text, cursorPos)) {
        _filteredMentionMembers = List.from(_allGroupCharacters);
        _mentionSelectedIndex = 0;
        _showMentionOverlay(Offset.zero);
        return;
      }
      return;
    }

    final cursorPos = _textController.selection.baseOffset;
    if (cursorPos <= 0) {
      _hideMentionOverlay();
      return;
    }
    final textBeforeCursor = text.substring(0, cursorPos);
    final atIndex = textBeforeCursor.lastIndexOf('@');

    if (atIndex < 0) {
      _hideMentionOverlay();
      return;
    }

    final query = textBeforeCursor.substring(atIndex + 1);
    // 出现空格说明这个 @ 已经输完（或只是普通文本里的 @），收起弹窗。
    if (query.contains(' ')) {
      _hideMentionOverlay();
      return;
    }

    // 空查询显示全部成员；否则按名称/角色/标签过滤。
    _filteredMentionMembers = query.isEmpty
        ? List.from(_allGroupCharacters)
        : _allGroupCharacters
            .where((c) =>
                c.name.contains(query) ||
                c.role.contains(query) ||
                c.personalityTags.any((tag) => tag.contains(query)))
            .toList();

    // 列表变化后，高亮索引重置到首项并夹取到合法范围
    if (_mentionSelectedIndex >= _filteredMentionMembers.length) {
      _mentionSelectedIndex = 0;
    }

    if (_mentionOverlay != null) {
      _mentionOverlay!.markNeedsBuild();
    }
  }

  /// 解析文本中 @ 到的角色 id 列表；私聊场景恒为空。
  List<String> _parseMentions(String content) {
    if (_isDirectChat) return const [];
    return parseMentionedCharacterIds(content, _characters);
  }

  /// 把发言意图列表映射为对应的角色对象。
  ///
  /// 用 [Iterable.whereType] 过滤掉找不到角色的意图（角色可能刚被删除/停用）。
  List<AICharacter> _charactersForIntents(List<ReplyIntent> intents) {
    final byId = {for (final c in _characters) c.id: c};
    return intents
        .map((intent) => byId[intent.speakerId])
        .whereType<AICharacter>()
        .toList();
  }

  /// 私聊本轮的回复者：固定为会话对方角色（前提是它有资格回复）。
  ///
  /// 私聊没有意图编排，故顺手清空 [_pendingReplyIntents]。
  List<AICharacter> _directReplyCharacters() {
    _pendingReplyIntents.clear();
    return DirectChatSession.selectReplyCharacters(
      characters: _allGroupCharacters,
      directCharacterId: _directCharacterId ?? '',
      isEligible: _isEligibleToReply,
    );
  }

  /// 为群聊本轮挑选发言者及其发言意图，并缓存到 [_pendingReplyIntents]。
  ///
  /// 若本轮没有被 @ 的人，则尽量排除上一条的发言者，避免同一角色连说两轮；
  /// 但过滤后为空时保留原结果（宁可连说，也不要整轮没人回应）。
  List<ReplyIntent> _selectGroupReplyIntents({
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    UserMessageSentiment? userSentiment,
  }) {
    var replyIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _recentMessagesForContext(),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: userMessage,
      mentionedIds: mentionedIds ?? const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _random,
      isAutoChat: isAutoChat,
      userSentiment: userSentiment,
    );
    final lastAiSenderId = _lastAiSenderId;
    // 被 @ 点名时必须让被点的人回答，此时不做"避免连说"的过滤。
    if (lastAiSenderId != null &&
        (mentionedIds == null || mentionedIds.isEmpty)) {
      final filtered = replyIntents
          .where((intent) => intent.speakerId != lastAiSenderId)
          .toList();
      // 过滤后为空则保留原列表，宁可连说也不要本轮无人回应。
      if (filtered.isNotEmpty) replyIntents = filtered;
    }
    _pendingReplyIntents
      ..clear()
      ..addEntries(
          replyIntents.map((intent) => MapEntry(intent.speakerId, intent)));
    return replyIntents;
  }

  /// 取最近 20 条消息作为 LLM 上下文（够连贯，又不过度消耗 token）。
  List<Message> _recentMessagesForContext() {
    return _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages.toList();
  }

  /// 上下文超出模型窗口时做压缩，返回压缩后的消息与摘要。
  ///
  /// 压缩摘要只写入 [_transientContextCompression]（仅本次会话有效）。
  ///
  /// 关闭自动记忆时直接返回原始上下文，不做任何压缩调用。
  Future<({List<Message> messages, String? summary})> _compactContextIfNeeded({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Message> fallbackContext,
  }) async {
    final transient = _transientContextCompression[character.id];
    if (!_memoryControls.automaticMemoryEnabled) {
      return (messages: fallbackContext, summary: transient?.summary);
    }
    final pending = _messages;
    final apiHistory = <Map<String, dynamic>>[
      if (transient != null)
        {
          'role': 'system',
          'content': '已有压缩摘要：${transient.summary}',
        },
      ...pending.map((message) => <String, dynamic>{
            'role': message.senderType == 'user' ? 'user' : 'assistant',
            'content': message.content,
          }),
    ];
    final manager = ContextWindowManager(
      maxRetries: 0,
      complete: (messages) async {
        final apiKey = await _credentialResolver.resolve(config);
        if (apiKey == null) {
          return const {'success': false, 'message': 'API 凭据不可用'};
        }
        return _aiGateway.sendChatMessage(
          apiKey: apiKey,
          provider: provider,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: messages,
          temperature: 0.3,
          maxTokens: 2048,
          purpose: AiRequestPurpose.summary,
          conversationId: widget.groupId,
          characterId: character.id,
        );
      },
      thresholdTokens:
          (_aiGateway.capability(provider, config.modelName).contextWindow -
                  2048)
              .clamp(4096, kContextCompressThresholdTokens)
              .toInt(),
    );
    // 没超过阈值就不压缩，省下一次 LLM 调用。
    if (!manager.shouldSummarize(apiHistory)) {
      return (messages: fallbackContext, summary: transient?.summary);
    }

    try {
      final summary = await manager.summarize(
        apiHistory,
        isDirectChat: _isDirectChat,
      );
      // ponytail: transient-only compression, restore durable summaries if
      // cross-session context compression becomes a measured bottleneck.
      _transientContextCompression[character.id] = (
        checkpoint:
            pending.isEmpty ? (transient?.checkpoint ?? '') : pending.last.id,
        summary: summary.summary,
      );
      return (
        messages: _lastUserOnly(fallbackContext),
        summary: summary.summary,
      );
    } catch (_) {
      // 压缩失败就退回完整上下文：宁可多花 token，也不能丢上下文。
      return (messages: fallbackContext, summary: transient?.summary);
    }
  }

  /// 压缩后仅保留最后一条用户消息作为上下文。
  ///
  /// 历史已由摘要代表，这里只需保留"当前要回应的那句话"。
  List<Message> _lastUserOnly(List<Message> messages) {
    for (final message in messages.reversed) {
      if (message.senderType == 'user') return [message];
    }
    return const [];
  }

  /// 把最近的对话记录转换成 LLM 消息格式，供 AgentRuntime 调用时携带上下文，
  /// 修复“追问时 AI 失忆”的问题。
  ///
  /// - 取最近 12 条，排除当前请求对应的用户消息（已在 userRequest 中，避免重复）。
  /// - user 消息 → role 'user'，ai 消息 → role 'assistant'。
  /// - 附件会保留文件名、跨平台本地路径；安全的小型文本文件还会内联内容。
  Future<List<Map<String, dynamic>>> _agenticHistory(
    String userMessage, {
    List<Message>? messages,
  }) {
    return AgentAttachmentContext.buildHistory(
      messages: messages ?? _recentMessagesForContext(),
      currentUserRequest: userMessage,
    );
  }

  /// 上一条 AI 消息的发送者 id（用于避免同一角色连续发言）。
  ///
  /// 从后往前扫，遇到用户消息就返回 null——用户已经开口，
  /// 此时"上一个 AI 发言者"这个约束不再适用。
  String? get _lastAiSenderId {
    for (final message in _messages.reversed) {
      if (message.senderType == 'ai') return message.senderId;
      if (message.senderType == 'user') return null;
    }
    return null;
  }

  /// 统计自用户最后一次发言以来，AI 已连续说了多少条。
  ///
  /// 私聊用它做刷屏保护：连说 3 条还没等到用户回复就暂停主动发言。
  int _directAiMessagesSinceLastUser() {
    var count = 0;
    for (final message in _messages.reversed) {
      if (message.senderType == 'user') break;
      if (message.senderType == 'ai') count++;
    }
    return count;
  }

  /// 把"无人可回复"的原因翻译成用户可读的提示文案。
  String _replyBlockText(ReplyBlockReason? reason) {
    switch (reason) {
      case ReplyBlockReason.noApiConfig:
        return '角色未配置 API Key，AI 无法回复。请到「设置」配置 API';
      case ReplyBlockReason.inactive:
        return _isDirectChat ? '该角色已停用，无法回复' : '当前群聊没有启用中的角色';
      case ReplyBlockReason.hourlyLimit:
        return '角色已达到本小时回复上限，稍后再试';
      case ReplyBlockReason.alreadyGenerating:
        return 'AI 正在生成中，请稍后再发';
      case ReplyBlockReason.networkError:
        return '网络请求失败，请检查 API 配置';
      case null:
        return '暂时没有可以回复的角色';
    }
  }

  /// 流式输出期间刷新 UI，并按需跟随滚动。
  ///
  /// 只有用户本来就在底部附近时才自动跟随——否则会把正在翻看历史的用户
  /// 强行拽回底部。[forceScroll] 用于必须回到底部的场景。
  void _flushStreamingUi({bool forceScroll = false}) {
    if (!_canTouchUi) return;
    final shouldScroll = forceScroll || _isNearBottom();
    setState(() {});
    if (shouldScroll) {
      // 流式跟随用 jumpTo（animated: false），避免每个 token 都触发一次动画。
      _scrollToBottom(animated: false);
    }
  }

  /// 当前是否滚动在底部附近（默认 160px 容差）。
  ///
  /// 尚未附着滚动视图时返回 true，视作"在底部"，让首帧内容正常跟随。
  bool _isNearBottom({double threshold = 160}) {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= threshold;
  }

  /// 滚动到列表底部。
  ///
  /// 放在 post-frame 回调里执行，确保新消息已完成布局、maxScrollExtent 已更新。
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final target = _scrollController.position.maxScrollExtent;
        if (animated) {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(target);
        }
      }
    });
  }

  /// 为角色分配一个稳定的气泡/头像配色。
  ///
  /// 按角色 id 的字符码之和取模选色，保证同一角色每次进入都是同一个颜色。
  Color _senderColor(AICharacter sender) {
    const palette = [
      Color(0xFF576B95),
      Color(0xFF2F7D65),
      Color(0xFF9A5B31),
      Color(0xFF7A5C99),
      Color(0xFF3F6F8F),
      Color(0xFF8B5D6B),
      Color(0xFF5F7548),
    ];
    final hash = sender.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
    return palette[hash % palette.length];
  }

  /// 自动发言状态条的展示文案。
  ///
  /// 工作模式与总开关的优先级高于具体运行状态——它们是"为什么不发言"的根因。
  String get _autoChatStatusText {
    if (_workModeEnabled) return '工作模式中，自动发言已暂停';
    if (!_isAutoChatEnabled) return '自动发言已关闭';
    switch (_autoChatStatus) {
      case AutoChatStatus.idle:
        return '自动发言空闲';
      case AutoChatStatus.waiting:
        return '自动发言等待中';
      case AutoChatStatus.generating:
        return '自动发言生成中';
      case AutoChatStatus.paused:
        return _textController.text.trim().isNotEmpty
            ? '你正在输入，自动发言暂停'
            : '自动发言已暂停';
      case AutoChatStatus.unavailable:
        return _replyBlockText(_lastReplyBlockReason);
      case AutoChatStatus.error:
        return '自动发言异常，已暂停';
    }
  }

  /// 切换空闲自动发言开关（仅本次会话内存态，不改全局治理设置）。
  void _toggleAutoChat(bool enabled) {
    if (!_canTouchUi) return;
    setState(() {
      _isAutoChatEnabled = enabled;
      _autoChatStatus =
          enabled ? AutoChatStatus.waiting : AutoChatStatus.paused;
    });
    if (enabled && !_workModeEnabled) {
      _startAutoChat();
    } else {
      _autoChatScheduler.stop();
    }
  }

  /// 切换工作模式（持久化到本会话配置）。
  ///
  /// 开启：中断进行中的自动发言流式输出并停掉调度器，再检查可恢复的任务。
  /// 关闭：停掉本地 agent 桥接进程、取消尚未审批的工具调用，恢复自动发言。
  Future<void> _toggleWorkMode(bool enabled) async {
    await WorkModeConfigService(db: _db).setWorkMode(widget.groupId, enabled);
    _workModeSession.setEnabled(enabled);
    if (enabled) {
      // 正在自动发言的话先丢弃当前这条流式输出，避免它写进工作模式会话。
      if (_autoChatScheduler.isRunning) {
        _discardCurrentStream = true;
        _stopStreaming();
      }
      _stopAutoChat();
    } else {
      await LocalAgentBridgeLauncher().stop();
      final pending = _workModeSession.takePendingApproval();
      if (pending != null) {
        await _cancelAgentTask(
          pending.task,
          reason: '工作模式已关闭，待审批任务已取消。',
        );
      }
      _conversationController.complete();
    }
    if (_canTouchUi) {
      setState(() {});
    }
    if (enabled) {
      _scheduleAgentTaskRecovery();
    } else if (_isAutoChatEnabled) {
      _startAutoChat();
    }
  }

  /// 构建 AppBar 下方的会话控件（自动发言 / 工作模式两个开关）。
  ///
  /// 私聊不展示自动发言开关（私聊的主动联系由前台守护服务统一管控）。
  Widget _buildConversationControls(ColorScheme cs) {
    return CompactConversationControls(
      showAutoChat: !_isDirectChat,
      autoChatEnabled: _isAutoChatEnabled && _hasAnyApiConfig,
      workModeEnabled: _workModeEnabled,
      autoChatAvailable: _hasAnyApiConfig,
      autoChatTooltip: _autoChatStatusText,
      workModeTooltip: _workModeEnabled ? '工作模式已开启 · 敏感操作需确认' : '工作模式已关闭',
      onAutoChatChanged: _toggleAutoChat,
      onWorkModeChanged: _toggleWorkMode,
    );
  }

  /// 进入消息搜索模式（AppBar 切换为搜索框）。
  void _enterSearch() {
    setState(() => _isSearching = true);
    _searchResults = [];
    _searchFocusIndex = null;
  }

  /// 退出搜索模式并清理关键词、结果与定位状态。
  void _exitSearch() {
    _searchDebounceTimer?.cancel();
    setState(() {
      _isSearching = false;
      _searchController.clear();
      _searchResults = [];
      _searchFocusIndex = null;
    });
  }

  /// 搜索输入的防抖入口：停止输入 250ms 后才真正查库。
  void _performSearch(String query) {
    if (query.trim().isEmpty) {
      _searchDebounceTimer?.cancel();
      setState(() => _searchResults = []);
      return;
    }
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(_searchDebounceDuration, () {
      unawaited(_applySearch(query));
    });
  }

  /// 执行搜索并定位到第一条命中。
  ///
  /// 查库返回后再比对一次输入框内容：若用户已改了关键词，丢弃这次过期结果。
  Future<void> _applySearch(String query) async {
    if (!_canTouchUi) return;
    final q = query.toLowerCase();
    final results = await _repository.search(q);
    if (!_canTouchUi || _searchController.text.trim().toLowerCase() != q) {
      return;
    }
    setState(() {
      _searchResults = results;
      _searchFocusIndex = _searchResults.isEmpty ? null : 0;
    });
    if (_searchResults.isNotEmpty) {
      await _focusSearchResult(_searchResults[0]);
    }
  }

  /// 滚动定位到某条搜索结果。
  ///
  /// 目标消息不在当前分页窗口时，先加载它所在的窗口并与现有消息按 id 去重合并、
  /// 按时间（时间相同则按 id）重排，保证列表顺序稳定后再定位。
  Future<void> _focusSearchResult(Message message) async {
    if (!_messages.any((loaded) => loaded.id == message.id)) {
      final page = await _repository.loadAround(message.id);
      if (!_canTouchUi) return;
      final byId = <String, Message>{
        for (final loaded in _messages) loaded.id: loaded,
        for (final loaded in page.messages) loaded.id: loaded,
      };
      final merged = byId.values.toList()
        ..sort((a, b) {
          final byTime = a.timestamp.compareTo(b.timestamp);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
      setState(() => _messages = merged);
    }
    _scrollToMessageIndex(
      _messages.indexWhere((loaded) => loaded.id == message.id),
    );
  }

  /// 把第 [index] 条消息滚动到可见区域（对齐到视口 20% 高度处）。
  ///
  /// 该项已渲染时直接用 [Scrollable.ensureVisible]；尚未渲染时先按每条约 80px
  /// 估算跳到附近，等下一帧该项挂载后再精确对齐。
  void _scrollToMessageIndex(int index) {
    if (index < 0 || index >= _messages.length) return;
    if (!_scrollController.hasClients) return;
    final keyContext = _messageListController.contextFor(_messages[index].id);
    if (keyContext != null) {
      Scrollable.ensureVisible(
        keyContext,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.2,
      );
      return;
    }
    // Item not rendered yet: jump close, then refine once item is built.
    final estimatedOffset = index * 80.0;
    _scrollController.jumpTo(
      estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _messageListController.contextFor(_messages[index].id);
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );
      }
    });
  }

  /// 跳到上一条搜索结果（到头则环回末条）。
  void _searchPrev() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    setState(() {
      // 先加长度再取模，避免下标为 0 时出现负数。
      _searchFocusIndex = ((_searchFocusIndex! - 1 + _searchResults.length) %
          _searchResults.length);
    });
    final msg = _searchResults[_searchFocusIndex!];
    unawaited(_focusSearchResult(msg));
  }

  /// 跳到下一条搜索结果（到尾则环回首条）。
  void _searchNext() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    setState(() {
      _searchFocusIndex = ((_searchFocusIndex! + 1) % _searchResults.length);
    });
    final msg = _searchResults[_searchFocusIndex!];
    unawaited(_focusSearchResult(msg));
  }

  /// 搜索计数标签：有定位时显示"第 N / 共 M"，否则只显示总数。
  String get _searchResultLabel {
    if (_searchResults.isEmpty) return '';
    if (_searchFocusIndex == null) return '${_searchResults.length} 条结果';
    return '${_searchFocusIndex! + 1} / ${_searchResults.length}';
  }

  // —— 语音播放 ——
  /// 当前是否正在朗读。
  bool _isSpeaking = false;

  /// 正在被朗读的消息 id（用于把按钮切成"停止朗读"）。
  String? _speakingMessageId;

  /// TTS 总开关（存于 Hive app_settings，由设置页控制）。
  bool get _isTtsEnabled => _db.isTtsEnabled;

  /// TTS 状态回调：同步朗读状态，并把引擎错误以 Toast 形式提示用户。
  void _handleSpeechState(SpeechPlaybackState state) {
    if (!_canTouchUi) return;
    setState(() {
      _isSpeaking = state.isSpeaking;
      _speakingMessageId = state.messageId;
    });
    final error = state.error;
    if (error != null && error.isNotEmpty) {
      AppToast.show(
        context,
        error,
        icon: Icons.volume_off_rounded,
      );
    }
  }

  /// 朗读一条消息；若正在朗读别的内容会先停下（同一时刻只播一条）。
  Future<void> _ttsSpeak(Message message) async {
    if (_isSpeaking) {
      await _speech.stop();
    }
    final text = message.content;
    if (text.trim().isEmpty) return;
    await _speech.speak(messageId: message.id, text: text);
  }

  /// 停止朗读。
  Future<void> _ttsStop() => _speech.stop();

  /// 长按消息弹出的操作面板。
  ///
  /// 仅 AI 消息（[sender] 非空）提供重新生成 / 引用回复 / @ 该角色；
  /// 朗读项受 TTS 总开关控制；推送到企业微信对所有消息可用。
  void _showMessageActionSheet(Message message, AICharacter? sender) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(
              sender != null ? '${sender.name} 的消息' : '消息',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            if (sender != null) ...[
              SheetButton(ctx, cs, Icons.refresh_rounded, '重新生成', () {
                Navigator.pop(ctx);
                _regenerateAiReply(message, sender);
              }),
              const SizedBox(height: 8),
              SheetButton(ctx, cs, Icons.format_quote_rounded, '引用回复', () {
                Navigator.pop(ctx);
                _quoteMessage(message);
              }),
              const SizedBox(height: 8),
              SheetButton(
                  ctx, cs, Icons.alternate_email_rounded, '@${sender.name}',
                  () {
                Navigator.pop(ctx);
                _insertMention(sender);
              }),
              const SizedBox(height: 8),
            ],
            if (_isTtsEnabled) ...[
              SheetButton(
                  ctx,
                  cs,
                  _isSpeaking && _speakingMessageId == message.id
                      ? Icons.stop_circle_rounded
                      : Icons.volume_up_rounded,
                  _isSpeaking && _speakingMessageId == message.id
                      ? '停止朗读'
                      : '朗读', () {
                Navigator.pop(ctx);
                if (_isSpeaking && _speakingMessageId == message.id) {
                  _ttsStop();
                } else {
                  _ttsSpeak(message);
                }
              }),
              const SizedBox(height: 8),
            ],
            SheetButton(ctx, cs, Icons.send_to_mobile_rounded, '推送到企业微信', () {
              Navigator.pop(ctx);
              _showWeComPushDialog(message.content);
            }),
          ],
        ),
      ),
    );
  }

  /// 弹出"推送到企业微信"对话框（可选发给同事 UserID 或群 Webhook）。
  void _showWeComPushDialog(String defaultContent) {
    final service = WeComPushService();
    var targetType = 'user';
    final userIdCtl = TextEditingController();
    final webhookCtl = TextEditingController();
    final contentCtl = TextEditingController(text: defaultContent);
    var sending = false;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('推送到企业微信'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'user', label: Text('同事')),
                    ButtonSegment(value: 'group', label: Text('群')),
                  ],
                  selected: {targetType},
                  onSelectionChanged: (sel) =>
                      setSt(() => targetType = sel.first),
                ),
                const SizedBox(height: 12),
                if (targetType == 'user')
                  TextField(
                    controller: userIdCtl,
                    decoration: const InputDecoration(
                      labelText: '同事 UserID',
                      hintText: '如 zhangsan',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  )
                else
                  TextField(
                    controller: webhookCtl,
                    decoration: const InputDecoration(
                      labelText: '群机器人 Webhook Key',
                      hintText: '粘贴群机器人的 key',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '内容',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: sending
                  ? null
                  : () async {
                      setSt(() => sending = true);
                      final content = contentCtl.text.trim();
                      final WeComPushResult res;
                      if (targetType == 'user') {
                        final uid = userIdCtl.text.trim();
                        if (uid.isEmpty) {
                          AppToast.show(context, '请填写同事 UserID');
                          setSt(() => sending = false);
                          return;
                        }
                        res = await service.sendToUser(uid, content);
                      } else {
                        final key = webhookCtl.text.trim();
                        if (key.isEmpty) {
                          AppToast.show(context, '请填写群 Webhook Key');
                          setSt(() => sending = false);
                          return;
                        }
                        res = await service.sendToGroup(key, content);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        AppToast.show(
                          context,
                          res.ok ? '已推送到企业微信' : res.detail,
                          icon: res.ok ? Icons.check : Icons.error_outline,
                        );
                      }
                    },
              child: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('发送'),
            ),
          ],
        ),
      ),
    );
  }

  /// 重新生成某条 AI 回复：用"排除该条之后"的上下文重新请求，替换原消息。
  ///
  /// 新消息通过 replyToMessageId 指向被重新生成的原消息，保留可追溯关系。
  /// 流程与 [_generateAiReply] 类似（流式 → 失败重试 → 空内容兜底 → 落库），
  /// 但不参与意图/关系态更新——这是用户手动动作，不代表角色的自主行为。
  Future<void> _regenerateAiReply(
      Message original, AICharacter character) async {
    if (_isRegenerating || _isAiReplying) return;
    if (_conversationController.beginNormal() == null) return;
    setState(() {
      _isRegenerating = true;
      _regenerateMessageId = original.id;
    });

    final config = _resolveApiConfig(character);
    final apiKey =
        config == null ? null : await _credentialResolver.resolve(config);
    if (config == null || apiKey == null) {
      _conversationController.complete();
      if (_canTouchUi) setState(() => _isRegenerating = false);
      return;
    }

    // 上下文里剔除原消息本身，否则模型会看到"自己上次的答案"而倾向复读。
    final msgsBefore = _messages.where((m) => m.id != original.id).toList();
    _regenerateContext = msgsBefore.length > 20
        ? msgsBefore.sublist(msgsBefore.length - 20)
        : msgsBefore;

    final provider = ApiProvider.values.firstWhere(
        (p) => p.name == config.provider,
        orElse: () => ApiProvider.deepseek);
    final apiMessages = await _buildApiMessages(
        character, _regenerateContext, null,
        supportsVision:
            _aiGateway.capability(provider, config.modelName).supportsVision);

    final temp = Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: '');
    setState(() {
      _streamingMessage = temp;
      // 保留原消息在列表中，视觉上用流式占位覆盖；成功后移除原消息。
      _messages = List.from(_messages)..add(temp);
    });
    _scrollToBottom();

    final session = StreamingReplySession();
    _streamingSession = session;
    if (_canTouchUi) setState(() {});
    final result = await session.run(
      _aiGateway.streamChatMessage(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: apiMessages,
        purpose: AiRequestPurpose.reply,
        conversationId: widget.groupId,
        characterId: character.id,
        userInitiated: true,
      ),
      onDraft: (draft) {
        temp.content = draft;
        _conversationController.updateStreamingDraft(draft);
        _flushStreamingUi();
      },
    );
    if (_disposed) return;
    if (identical(_streamingSession, session)) _streamingSession = null;
    var fullContent = result.content;
    var failed = result.failed;
    if (failed) {
      fullContent = '[${character.name} 重新生成失败: ${result.error}]';
      temp.content = fullContent;
      _flushStreamingUi();
    }
    if (_canTouchUi) setState(() {});

    if (failed && !AiRequestGateway.isBlockedMessage(result.error)) {
      final retryContent = await _retryFailedReply(
        character: character,
        config: config,
        provider: provider,
        apiMessages: apiMessages,
        userInitiated: true,
      );
      if (retryContent != null && retryContent.trim().isNotEmpty) {
        failed = false;
        fullContent = retryContent.trim();
        temp.content = fullContent;
        if (_canTouchUi) _flushStreamingUi();
      }
    }

    if (!failed && fullContent.trim().isEmpty) {
      fullContent = ChatActivityPolicy.emptyReplyFallback(
          characterName: character.name,
          role: character.role,
          groupTheme: _group?.theme ?? '',
          userMessage: null,
          isAutoChat: false,
          random: _random);
      temp.content = fullContent;
      _flushStreamingUi();
    }

    final mentionedIds = _isDirectChat
        ? const <String>[]
        : parseMentionedCharacterIds(fullContent, _characters);
    fullContent = _stripNamePrefix(fullContent, character.name);
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    // 指回原消息，保留"这条是对哪条的重写"的可追溯关系。
    temp.replyToMessageId = original.id;
    if (!failed) await _appendMessage(temp);
    await _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    if (!failed && fullContent.trim().isNotEmpty) {
      await _maybeUpdateMemory();
    }

    if (_canTouchUi) {
      _conversationController.complete();
      setState(() {
        _streamingMessage = null;
        _isRegenerating = false;
        _regenerateMessageId = '';
        _regenerateContext = [];
        if (failed) {
          // 重生成失败：移除占位消息，保留原消息。
          _messages = _messages.where((m) => m.id != temp.id).toList();
        } else {
          // 成功：移除原消息，保留新消息。
          _messages = _messages.where((m) => m.id != original.id).toList();
        }
      });
    }
  }

  /// 进入引用回复：记录被引用消息并聚焦输入框。
  void _quoteMessage(Message message) {
    setState(() => _quotedMessage = message);
    _inputFocusNode.requestFocus();
  }

  /// 取消引用回复。
  void _cancelQuote() {
    setState(() => _quotedMessage = null);
  }

  /// 按 senderId 取展示名；`user` 返回群主名，找不到角色时返回占位名。
  String _senderNameById(String id) {
    if (id == 'user') return _ownerMentionName;
    final c = _allGroupCharacters.firstWhere((c) => c.id == id,
        orElse: () => _unknownCharacter());
    return c.name;
  }

  /// 角色已被删除时的占位对象，避免历史消息渲染时空指针。
  AICharacter _unknownCharacter() {
    return AICharacter(
      name: '已删除角色',
      avatar: '?',
      age: 0,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: '',
    );
  }

  /// 页面主体。
  ///
  /// 结构：AppBar（标题/搜索/导出/记忆/联网开关）+ 若干条件横幅
  /// （无 API Key、群公告、联网状态、@我 提醒）+ 会话开关 + 消息列表 + 输入区。
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 首屏加载中：只渲染标题栏 + loading，避免读到未初始化的 _group 等字段。
    if (_isLoading) {
      return Scaffold(
        backgroundColor: WeComChatTokens.chatBackground(context),
        appBar: AppBar(
          backgroundColor: WeComChatTokens.chatBackground(context),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(_group?.name ?? '加载中...',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: cs.onSurface)),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 私聊需要知道哪些用户消息已被对方"读过"，以渲染已读标记。
    final readUserMessageIds =
        _isDirectChat ? directReadUserMessageIds(_messages) : const <String>{};
    // #5 性能：消息/角色索引 Map 在父页预计算一次，避免在子组件每次 build 重建。
    final messageIndex = {for (final message in _messages) message.id: message};
    // 被引用的消息可能已滑出当前分页窗口，按需回库补齐，否则引用条显示不出来。
    for (final message in _messages) {
      final quotedId = message.replyToMessageId;
      if (quotedId == null || messageIndex.containsKey(quotedId)) continue;
      final quoted = _db.messageBox.get(quotedId);
      if (quoted != null) messageIndex[quotedId] = quoted;
    }
    final characterIndex = {
      for (final character in _allGroupCharacters) character.id: character,
    };
    return Scaffold(
      backgroundColor: WeComChatTokens.chatBackground(context),
      appBar: ChatRoomAppBar(
        title: _group?.name ?? '群聊',
        subtitle:
            !_isDirectChat && (_groupMemory?.topicSummary.isNotEmpty ?? false)
                ? _groupMemory!.topicSummary
                : null,
        isSearching: _isSearching,
        searchController: _searchController,
        hasSearchResults: _searchResults.isNotEmpty,
        searchResultLabel: _searchResultLabel,
        showGroupActions: !_isDirectChat,
        memberChip: GestureDetector(
          onTap: _showMembersSheet,
          child: MemberStackChip(
            characters: _characters,
            senderColor: _senderColor,
          ),
        ),
        onSearchChanged: _performSearch,
        onEnterSearch: _enterSearch,
        onPreviousResult: _searchPrev,
        onNextResult: _searchNext,
        onExitSearch: _exitSearch,
        onExport: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ExportPage(initialGroupId: widget.groupId),
        )),
        onOpenMemory: _openMemoryManagement,
        webSearchIcon: _webSearchPolicyIcon,
        webSearchTooltip: '联网搜索：${_effectiveWebSearchPolicy.label}',
        onConfigureWebSearch: _configureWebSearchPolicy,
        onClearConversation:
            _isDirectChat ? _showClearConversationDialog : null,
      ),
      body: Column(
        children: [
          // 未配置 API Key 时给出醒目提示，避免「发了消息 AI 不回复」的困惑
          if (!_hasAnyApiConfig)
            ApiWarningBanner(
              message: _isDirectChat
                  ? _replyBlockText(_lastReplyBlockReason)
                  : '尚未配置 API Key，AI 不会回复或自动聊天',
              onConfigure: () => Navigator.pushNamed(context, '/settings'),
            ),
          if (!_isDirectChat &&
              (_group?.announcement.trim().isNotEmpty ?? false))
            AnnouncementBanner(
              announcement: _group!.announcement.trim(),
              onEdit: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChatGroupFormPage(group: _group),
              )),
            ),
          if (_webSearchState.status != SearchRunStatus.idle)
            SearchStatusBanner(
              message: _webSearchStatusText,
              busy: _webSearchState.status == SearchRunStatus.searching ||
                  _webSearchState.status == SearchRunStatus.awaitingConsent,
              onTap: _webSearchState.snapshot == null
                  ? null
                  : _showWebSearchSources,
            ),
          _buildConversationControls(cs),
          if (_pendingUserMentionMessageIds.isNotEmpty &&
              !ConversationPresenceService.instance.isActive(widget.groupId))
            UserMentionBanner(
              count: _pendingUserMentionMessageIds.length,
              onTap: _jumpToNextUserMention,
              onClear: _clearUserMentions,
            ),
          if (_isLoadingOlder) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(cs)
                : ChatMessageList(
                    messages: _messages,
                    characters: _allGroupCharacters,
                    progressStartTimes: _progressStartTimes,
                    messageIndex: messageIndex,
                    characterIndex: characterIndex,
                    scrollController: _scrollController,
                    controller: _messageListController,
                    streamingMessageId: _streamingMessage?.id,
                    regeneratingMessageId:
                        _isRegenerating ? _regenerateMessageId : null,
                    highlightedMentionMessageId: _highlightedMentionMessageId,
                    isDirectChat: _isDirectChat,
                    readUserMessageIds: readUserMessageIds,
                    ownerName: _ownerMentionName,
                    unknownCharacter: _unknownCharacter(),
                    senderColor: _senderColor,
                    senderNameById: _senderNameById,
                    onLongPress: _showMessageActionSheet,
                    onSenderTap: _openCharacterSettings,
                    onMentionSender: _insertMention,
                    onQuotedTap: (message) =>
                        unawaited(_focusSearchResult(message)),
                  ),
          ),
          // 底部状态区：文档解析进度优先于"AI 正在回复"提示（前者更需要可取消）。
          if (_documentProcessingToken != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _documentProcessingProgress,
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _stopDocumentProcessing,
                    icon: const Icon(Icons.stop_rounded, size: 16),
                    label: const Text('取消文档解析'),
                  ),
                ],
              ),
            )
          else if (_isAiReplying)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Text(
                    _isStreaming ? 'AI 正在生成...' : 'AI 正在回复...',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  if (_isStreaming) ...[
                    const SizedBox(width: 10),
                    // 「停止生成」按钮：取消当前流订阅
                    TextButton.icon(
                      onPressed: _stopStreaming,
                      icon: const Icon(Icons.stop_rounded, size: 16),
                      label: const Text('停止生成'),
                      style: TextButton.styleFrom(
                        foregroundColor: cs.error,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          _buildInputArea(),
        ],
      ),
    );
  }

  /// 空会话时的引导页：图标 + 标题 + 用法说明 + 提示 chip（群聊/私聊文案不同）。
  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppTheme.primaryGradient,
              ),
              child: Icon(
                  _isDirectChat
                      ? Icons.chat_bubble_rounded
                      : Icons.groups_rounded,
                  size: 44,
                  color: Colors.white),
            ),
            const SizedBox(height: 24),
            Text(
                _isDirectChat
                    ? (_group?.name ?? '私聊')
                    : '欢迎来到 ${_group?.name ?? '群聊'}',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              _isDirectChat
                  ? '发条消息，和这个角色单独聊聊。\n对话会保存在本地。'
                  : '这是一个 AI 群聊模拟器。\n发条消息，AI 角色会自动回复；\n用 @ 可以指定某个角色回应。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, height: 1.6, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                HintChip(text: '说句「你好」试试', cs: cs),
                if (!_isDirectChat) HintChip(text: '@角色名 提到谁', cs: cs),
                if (!_isDirectChat && _characters.isNotEmpty)
                  HintChip(text: '${_characters.length} 位 AI 在线', cs: cs),
                if (_isDirectChat && _allGroupCharacters.isNotEmpty)
                  HintChip(text: _allGroupCharacters.first.role, cs: cs),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出群成员列表面板（可查看状态、进角色设置、发起私聊）。
  void _showMembersSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => MemberSheet(
        characters: _characters,
        ownerName: _ownerMentionName,
        senderColor: _senderColor,
        statusText: _memberStatusText,
        onOpenSettings: _openCharacterSettings,
        onDirectChat: (character) {
          if (mounted) Navigator.of(context).pushNamed('/dm/${character.id}');
        },
      ),
    );
  }

  /// 清空当前私聊的对话消息（保留角色记忆和关系状态）。
  Future<void> _showClearConversationDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined, color: Colors.orange),
        title: const Text('清空对话'),
        content: const Text('将删除本对话的所有聊天记录，但保留角色记忆和亲密度等关系数据。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _repository.deleteAllMessages();
    if (!_canTouchUi) return;
    setState(() {
      _messages = const <Message>[];
      _streamingMessage = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('对话已清空，角色记忆和关系数据已保留')),
      );
    }
  }

  /// 打开记忆管理页；返回后重新加载记忆/关系/成员，让页面反映用户的编辑结果。
  Future<void> _openMemoryManagement() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MemoryManagementPage(
        conversationId: widget.groupId,
      ),
    ));
    if (!_canTouchUi) return;
    final loaded = await _loader.load(widget.groupId);
    if (!_canTouchUi) return;
    setState(() {
      _groupMemory = loaded.groupMemory;
      _characterMemories = loaded.characterMemories;
      _relationshipStates = loaded.relationships;
      _characters = loaded.activeCharacters;
      _allGroupCharacters = loaded.allCharacters;
    });
  }

  /// 成员面板里的单行状态文案：「职位 · 年龄 · 可回复状态 · 本小时用量」。
  String _memberStatusText(AICharacter c) {
    final blockReason = _blockReasonFor(c);
    final base = '${c.role} · ${c.age}岁';
    final usage = '${c.hourlyReplyCount}/${c.hourlyReplyLimit} 次/小时';
    final status = switch (blockReason) {
      null => '可回复',
      ReplyBlockReason.noApiConfig => '未配置 API',
      ReplyBlockReason.inactive => '已停用',
      ReplyBlockReason.hourlyLimit => '达到上限',
      ReplyBlockReason.alreadyGenerating => '生成中',
      ReplyBlockReason.networkError => '网络异常',
    };
    return '$base · $status · $usage';
  }

  /// 跳转到角色编辑页。
  void _openCharacterSettings(AICharacter character) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => AICharacterFormPage(character: character)),
    );
  }

  /// 是否运行在桌面端（决定回车发送、拖放文件等交互）。
  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// 输入区键盘事件：@ 弹窗打开时走导航；桌面端回车发送、Shift+回车换行。
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    // 单独放行 Shift 抬起/按下，否则会干扰 Shift+Enter 的组合判断。
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
            event.logicalKey == LogicalKeyboardKey.shiftRight)) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // @ 弹窗键盘导航优先（↑↓ 选择、回车插入、Esc 关闭）
    if (_showMentionPopup) return _handleMentionKeyEvent(event);
    final key = event.logicalKey;
    // Ctrl/Cmd+V：自行处理剪贴板（可能含图片），不走 TextField 默认粘贴。
    if (key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      unawaited(_pasteClipboardAttachments(showEmptyHint: false));
      // 阻止 Flutter 默认粘贴行为，避免手动插入与 TextField 原生粘贴重复。
      return KeyEventResult.handled;
    }
    // 桌面端：Enter 发送、Shift+Enter 换行
    if (_isDesktop) {
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
        if (!isShiftPressed) {
          if (_canSend) {
            _sendMessage();
          }
          return KeyEventResult.handled; // 阻止插入换行
        }
        // Shift+Enter：放行，让 TextField 插入换行
      }
    }
    return KeyEventResult.ignored;
  }

  /// 构建底部输入区（引用条、附件预览、拖放区、表情、发送/停止按钮）。
  ///
  /// 具体 UI 在 [ChatRoomComposer]，此处只做状态与回调的接线。
  Widget _buildInputArea() {
    return ChatRoomComposer(
      textController: _textController,
      focusNode: _inputFocusNode,
      inputFieldKey: _inputFieldKey,
      quotedMessage: _quotedMessage,
      quotedSenderName: _quotedMessage == null
          ? ''
          : _senderNameById(_quotedMessage!.senderId),
      attachments: _pendingAttachments,
      isDraggingFiles: _isDraggingFiles,
      isStreaming: _isStreaming,
      canSend: _canSend,
      isDirectChat: _isDirectChat,
      isDesktop: _isDesktop,
      onKeyEvent: _handleKeyEvent,
      onTextChanged: _handleTextChanged,
      onDragStateChanged: (dragging) {
        if (_canTouchUi) setState(() => _isDraggingFiles = dragging);
      },
      onDroppedPaths: (paths) => unawaited(_handleDroppedFiles(paths)),
      onShowAttachmentMenu: _showAttachmentMenu,
      onPasteAttachments: () => _pasteClipboardAttachments(showEmptyHint: true),
      onShowEmojiPanel: _showEmojiPanel,
      onCancelQuote: _cancelQuote,
      onRemoveAttachment: _removeAttachment,
      onStopStreaming: _stopStreaming,
      onSend: _sendMessage,
    );
  }

  /// 弹出附件选择底部菜单：图片（多选）/ 视频（单选）/ 文件（多选）。
  void _showAttachmentMenu() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('发送附件',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            SheetButton(ctx, cs, Icons.image_rounded, '图片（可多选）', () {
              Navigator.pop(ctx);
              _pickImages();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.videocam_rounded, '视频（单选）', () {
              Navigator.pop(ctx);
              _pickVideo();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.insert_drive_file_rounded, '文件（可多选）',
                () {
              Navigator.pop(ctx);
              _pickFiles();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.content_paste_rounded, '粘贴截图或文件', () {
              Navigator.pop(ctx);
              _pasteClipboardAttachments(showEmptyHint: true);
            }),
          ],
        ),
      ),
    );
  }

  /// 弹出常用表情面板，点选后在光标处内联插入。
  void _showEmojiPanel() {
    const emojis = [
      '😀',
      '😂',
      '🥹',
      '😍',
      '😎',
      '🤔',
      '👍',
      '👏',
      '🙏',
      '🔥',
      '✨',
      '🎉',
      '💡',
      '✅',
      '🧪',
      '🚀',
    ];
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: emojis.map((emoji) {
            return InkWell(
              onTap: () {
                Navigator.pop(ctx);
                _insertTextAtCursor(emoji, inline: true);
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.5)),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// 从相册多选图片，复制到媒体目录并加入待发送列表。
  ///
  /// 受 [defaultMaxVisionImages]（4 张）约束：多选超出时截断并提示，
  /// 单张超过体积上限则跳过该张而不中断其余图片。
  /// Web 端只能拿到字节流，原生端直接按路径复制文件。
  Future<void> _pickImages() async {
    try {
      final currentImageCount =
          _pendingAttachments.where((att) => att.type == 'image').length;
      final remainingSlots = defaultMaxVisionImages - currentImageCount;
      if (remainingSlots <= 0) {
        if (mounted) {
          AppToast.show(context, '一次最多发送 4 张图片',
              icon: Icons.info_outline_rounded);
        }
        return;
      }

      final files = await _imagePicker.pickMultiImage(
        // 压缩到 1600px / 85% 质量：足够视觉模型识别，又能显著降低上传体积。
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (files.isEmpty) return;
      final selectedFiles = files.take(remainingSlots).toList();
      if (files.length > selectedFiles.length && mounted) {
        AppToast.show(context, '已限制为一次最多 4 张图片',
            icon: Icons.info_outline_rounded);
      }
      for (final file in selectedFiles) {
        final size = await file.length();
        if (!_canAddAttachment(size)) {
          _showAttachmentLimit(file.name);
          continue;
        }
        late final MediaAttachment att;
        if (kIsWeb) {
          final bytes = await file.readAsBytes();
          att = await _db.copyBytesToMedia(
            bytes,
            'image',
            fileName: file.name,
            mimeType: file.mimeType,
          );
        } else {
          att = await _db.copyToMedia(
            File(file.path),
            'image',
            fileName: file.name,
          );
        }
        if (mounted) setState(() => _pendingAttachments.add(att));
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '选择图片失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 从相册选择单个视频，复制到媒体目录并加入待发送列表。
  ///
  /// 视频体积大，仅支持单选。
  Future<void> _pickVideo() async {
    try {
      final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      if (!_canAddAttachment(await file.length())) {
        _showAttachmentLimit(file.name);
        return;
      }
      late final MediaAttachment att;
      if (kIsWeb) {
        final bytes = await file.readAsBytes();
        att = await _db.copyBytesToMedia(
          bytes,
          'video',
          fileName: file.name,
          mimeType: file.mimeType,
        );
      } else {
        att = await _db.copyToMedia(
          File(file.path),
          'video',
          fileName: file.name,
        );
      }
      if (mounted) setState(() => _pendingAttachments.add(att));
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '选择视频失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 选择任意类型文件（可多选）作为附件。
  ///
  /// 不同平台拿到的载荷不同（Web 为字节、原生为路径），
  /// 由 [resolvePickedAttachmentPayload] 归一后再分支处理。
  /// 一个都没成功时提示"没有可读取的文件"。
  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final picked in result.files) {
        final payload = resolvePickedAttachmentPayload(picked, isWeb: kIsWeb);
        if (payload == null) continue;
        late final MediaAttachment att;
        if (payload is PickedAttachmentBytes) {
          if (!_canAddAttachment(payload.bytes.lengthInBytes)) {
            _showAttachmentLimit(payload.fileName);
            continue;
          }
          att = await _db.copyBytesToMedia(
            payload.bytes,
            _attachmentTypeForPath(payload.fileName),
            fileName: payload.fileName,
          );
        } else if (payload is PickedAttachmentPath) {
          final source = File(payload.path);
          if (!await source.exists()) continue;
          if (!_canAddAttachment(await source.length())) {
            _showAttachmentLimit(payload.fileName);
            continue;
          }
          att = await _db.copyToMedia(
            source,
            _attachmentTypeForPath(payload.path),
            fileName: payload.fileName,
          );
        } else {
          continue;
        }
        if (mounted) setState(() => _pendingAttachments.add(att));
        added++;
      }
      if (mounted && added == 0) {
        AppToast.show(context, '没有可读取的文件', icon: Icons.info_outline_rounded);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '选择文件失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 处理桌面端拖放进来的路径。
  ///
  /// 文件按附件处理；文件夹无法作为附件，改为把绝对路径插入输入框
  /// （便于让 agentic 工具去读该目录）。
  Future<void> _handleDroppedFiles(Iterable<String> paths) async {
    if (paths.isEmpty) return;
    var addedFiles = 0;
    final droppedDirectories = <String>[];
    try {
      for (final droppedPath in paths) {
        final path = droppedPath.trim();
        if (path.isEmpty) continue;
        final directory = Directory(path);
        if (await directory.exists()) {
          droppedDirectories.add(directory.absolute.path);
          continue;
        }
        final source = File(path);
        if (!await source.exists()) continue;
        if (!_canAddAttachment(await source.length())) {
          _showAttachmentLimit(fileNameFromPath(path));
          continue;
        }
        final att = await _db.copyToMedia(
          source,
          _attachmentTypeForPath(path),
          fileName: fileNameFromPath(path),
        );
        addedFiles++;
        if (_canTouchUi) {
          setState(() => _pendingAttachments.add(att));
        }
      }

      if (droppedDirectories.isNotEmpty) {
        _insertTextAtCursor(droppedDirectories.join('\n'));
      }
      if (!mounted) return;
      if (!_canTouchUi) return;
      final parts = <String>[
        if (addedFiles > 0) '$addedFiles 个文件',
        if (droppedDirectories.isNotEmpty)
          '${droppedDirectories.length} 个文件夹路径',
      ];
      if (parts.isNotEmpty) {
        AppToast.show(context, '已添加 ${parts.join('、')}',
            icon: Icons.attach_file_rounded);
      }
    } catch (e) {
      if (_canTouchUi && mounted) {
        AppToast.show(context, '拖放失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 在光标处插入文本（替换当前选区）。
  ///
  /// [inline] 为 true 时紧贴插入（表情、粘贴文本）；否则在已有内容后另起一行
  /// （拖入的文件夹路径等，独占一行更清晰）。
  void _insertTextAtCursor(String text, {bool inline = false}) {
    if (text.trim().isEmpty) return;
    final current = _textController.text;
    final selection = _textController.selection;
    final insertion = inline || current.trim().isEmpty ? text : '\n$text';
    // 选区偏移为 -1 表示未聚焦，退化为在末尾插入。
    final start = selection.start < 0 ? current.length : selection.start;
    final end = selection.end < 0 ? current.length : selection.end;
    final next = current.replaceRange(start, end, insertion);
    final cursor = start + insertion.length;
    _textController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  /// 把剪贴板内容转成附件或文本插入输入框。
  ///
  /// 按优先级依次尝试：文件路径 → 图片位图 → 纯文本。
  /// 每种尝试都各自 try/catch：某个平台不支持某种剪贴板类型是常态，
  /// 不应因此中断后续回退路径。[_isPastingAttachments] 防止重复触发。
  Future<void> _pasteClipboardAttachments({bool showEmptyHint = false}) async {
    if (_isPastingAttachments) return;
    _isPastingAttachments = true;
    try {
      final attachments = <MediaAttachment>[];

      // 优先级 1：剪贴板中的文件路径。Android 的 content:// URI 无法直接读，跳过。
      try {
        final files = await Pasteboard.files();
        for (final path in files) {
          if (path.trim().isEmpty || path.startsWith('content://')) continue;
          final source = File(path);
          if (!await source.exists()) continue;
          if (!_canAddAttachment(await source.length())) {
            _showAttachmentLimit(fileNameFromPath(path));
            continue;
          }
          attachments.add(await _db.copyToMedia(
            source,
            _attachmentTypeForPath(path),
          ));
        }
      } catch (_) {}

      if (attachments.isEmpty) {
        // 优先级 2：剪贴板位图（如系统截图），落盘成带时间戳的 png。
        try {
          final image = await Pasteboard.image;
          if (image != null && image.isNotEmpty) {
            if (!_canAddAttachment(image.length)) {
              _showAttachmentLimit('剪贴板图片');
              return;
            }
            attachments.add(await _db.copyBytesToMedia(
              Uint8List.fromList(image),
              'image',
              fileName:
                  'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
              mimeType: 'image/png',
            ));
          }
        } catch (_) {}
      }

      if (attachments.isEmpty) {
        // 优先级 3：纯文本，直接插入输入框。
        String? clipboardText;
        try {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          clipboardText = clipboardTextFallback(data?.text);
        } catch (_) {}

        if (clipboardText != null) {
          if (!mounted || !_canTouchUi) return;
          setState(() {
            _insertTextAtCursor(clipboardText!, inline: true);
          });
          _handleTextChanged(_textController.text);
          _inputFocusNode.requestFocus();
          if (showEmptyHint) {
            AppToast.show(context, '已粘贴剪贴板文本',
                icon: Icons.content_paste_rounded);
          }
          return;
        }
      }

      if (!mounted) return;
      if (attachments.isEmpty) {
        if (showEmptyHint) {
          AppToast.show(context, '剪贴板里没有可粘贴的文本、文件或截图',
              icon: Icons.info_outline_rounded);
        }
        return;
      }
      setState(() => _pendingAttachments.addAll(attachments));
      AppToast.show(context, '已粘贴 ${attachments.length} 个附件',
          icon: Icons.content_paste_rounded);
    } catch (e) {
      if (mounted && showEmptyHint) {
        AppToast.show(context, '粘贴失败：$e', icon: Icons.error_outline_rounded);
      }
    } finally {
      _isPastingAttachments = false;
    }
  }

  /// 根据文件扩展名判定附件类型：`image` / `video` / 其余归为 `file`。
  String _attachmentTypeForPath(String path) {
    final ext = extensionOfPath(path);
    const imageExts = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'bmp',
    };
    const videoExts = {
      'mp4',
      'mov',
      'avi',
      'mkv',
      'webm',
      'm4v',
    };
    if (imageExts.contains(ext)) return 'image';
    if (videoExts.contains(ext)) return 'video';
    return 'file';
  }

  /// 判断再加一个 [newBytes] 字节的附件是否仍在体积限制内。
  ///
  /// 限制同时作用于单文件与单条消息总量（各 10 MB）。
  bool _canAddAttachment(int newBytes) {
    final existingBytes = _pendingAttachments.fold<int>(
      0,
      (sum, attachment) => sum + (attachment.fileSize ?? 0),
    );
    return canAddAttachment(
      existingBytes: existingBytes,
      newBytes: newBytes,
    );
  }

  /// 提示某个文件因超过体积限制而被跳过。
  void _showAttachmentLimit(String fileName) {
    if (!mounted) return;
    AppToast.show(
      context,
      '$fileName 超过单文件或单条消息 10 MB 限制',
      icon: Icons.info_outline_rounded,
    );
  }

  /// 从待发送列表移除某附件。
  void _removeAttachment(MediaAttachment att) {
    if (!mounted) return;
    final removed = _pendingAttachments
        .where((a) => a.id == att.id)
        .toList(growable: false);
    setState(() => _pendingAttachments.removeWhere((a) => a.id == att.id));
    if (removed.isNotEmpty) unawaited(_cleanupMediaPaths(removed));
  }

  /// 删除这些附件在媒体目录里的副本文件。
  ///
  /// 附件被移除或页面关闭时调用，避免未发送的临时文件长期堆积。
  Future<void> _cleanupMediaPaths(Iterable<MediaAttachment> attachments) async {
    await DataLifecycleService(db: _db).cleanupMediaPaths(
      attachments.map((attachment) => attachment.localPath),
    );
  }
}
