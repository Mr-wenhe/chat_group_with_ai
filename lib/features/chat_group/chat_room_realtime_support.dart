part of 'chat_room_page.dart';

/// 多人实时群聊在聊天页里的接入层。
///
/// 分工：`RealtimeClient` 只管连接与重连，本扩展只管「把远端消息变成一次
/// 正常的本地落库」。远端消息刻意复用 [_appendMessage]，从而自动获得与本人
/// 发言完全一致的待遇——进 `_messages`、写 Hive、进 AI 上下文、参与记忆提炼。
/// 这也是主人端 AI 能"看见"客人说了什么的原因。
extension _ChatRoomRealtimeSupport on _ChatRoomPageState {
  /// 群已共享时建立长连接。纯本机的群直接返回，不产生任何网络行为。
  Future<void> _startRealtimeIfNeeded() async {
    final group = _group;
    if (group == null || !_isRealtimeShared) return;
    _seedRosterFromGroup(group);
    if (_realtimeClient != null) return;

    if (kIsWeb) {
      _setRealtimeNotice('多人实时群聊暂不支持 Web 端');
      return;
    }

    final RealtimeSettings settings;
    try {
      settings = await ref.read(realtimeSettingsProvider.future);
    } on Object {
      _setRealtimeNotice('读取多人联机配置失败，请到设置里重新填写');
      return;
    }
    if (_disposed) return;
    if (!settings.isConfigured) {
      _setRealtimeNotice('尚未配置多人联机：请在「设置 - 多人联机」填写服务地址');
      return;
    }

    final client = RealtimeClient(
      uri: settings.websocketUri,
      roomId: group.roomId!,
      userId: _realtimeUserId,
      displayName: _db.ownerNameFromProfile(fallback: group.ownerName),
    );
    _realtimeClient = client;
    client.state.addListener(_handleRealtimeStateChanged);
    _realtimeEvents =
        client.events.listen((event) => unawaited(_handleRealtimeEvent(event)));
    _setRealtimeNotice(null);
    await client.connect();
  }

  /// 主人点「邀请客人」：打开邀请面板，必要时先把群注册到服务端。
  Future<void> _inviteGuests() async {
    final group = _group;
    if (group == null || _isDirectChat) return;
    // 菜单项对客人本来就不显示，这里是第二道闸：邀请码等于入群通行证，
    // 不能让客人拿着它继续拉人。
    if (!group.isHost(_realtimeUserId)) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => InviteGuestsSheet(
        groupName: group.name,
        online: _realtimeState == RealtimeConnectionState.connected,
        onEnsureInviteCode: _ensureInviteCode,
      ),
    );
  }

  /// 保证群在服务端有一个房间，返回邀请码。
  ///
  /// 已经共享过的群带上自己的 roomId 再注册一次：服务端据此知道这是「同一个
  /// 房间」而不是要新建，于是原样返回原来的邀请码。每次点开都无脑新建的话，
  /// 同一个群会在服务端堆出一串房间，而客人扫到旧码就进了一个不会有人的空房间。
  ///
  /// 这一趟同时兼作失效检查。服务端是纯内存的，重启后注册表清空，旧邀请码对
  /// 谁都解析不了；只有拿同一个 roomId 重新注册才能补出一个新码，而客人手里
  /// 的 roomId 不受影响（重连时房间会被重新建出来）。
  Future<String> _ensureInviteCode() async {
    final group = _group;
    if (group == null) {
      throw const RealtimeGroupException('群聊尚未加载完成，请稍后重试');
    }

    final settings = await ref.read(realtimeSettingsProvider.future);
    if (!settings.isConfigured) {
      throw const RealtimeGroupException(
          '尚未配置多人联机服务：请在「设置 - 多人联机」填写服务地址');
    }

    final previousCode = group.inviteCode;
    final requestedRoomId = group.roomId;
    final RealtimeGroupRegistration registration;
    try {
      registration = await ref.read(realtimeGroupServiceProvider).registerGroup(
            settings: settings,
            name: group.name,
            hostUserId: _realtimeUserId,
            hostDisplayName: _db.ownerNameFromProfile(fallback: group.ownerName),
            roomId: requestedRoomId,
          );
    } on RealtimeGroupException catch (error) {
      // 断网时主人多半只是想再念一遍邀请码，不该被一个错误页挡住。只有网络层
      // 失败才退回本地已有的码；令牌错误、地址填错这类必须让主人知道，
      // 否则 TA 会拿着一个根本连不上的群的码继续发。
      final canFallBack =
          error.isTransportFailure && previousCode != null && previousCode.isNotEmpty;
      if (!canFallBack) rethrow;
      return previousCode;
    }

    // 服务端返回的房间号必须就是我们请求的那个。旧版服务端不认识 roomId 字段，
    // 会把它当成一次普通的新建，另分配一个房间——照单全收就会把本地群指向一个
    // 没有人的新房间，已经在群里的客人全部被甩掉，而主人只看到一个正常的邀请码。
    // 宁可什么都不改。
    if (requestedRoomId != null &&
        requestedRoomId.isNotEmpty &&
        registration.roomId != requestedRoomId) {
      throw const RealtimeGroupException(
          '实时服务版本过旧，无法为这个群刷新邀请码，请先把服务端更新到最新版本');
    }

    // 先落库再连服务端：中途失败时至少本地已经记住了房间号，
    // 重新打开页面还能连上，不会变成一个连接不上又没法重新注册的孤儿群。
    group
      ..hostUserId = registration.hostUserId
      ..roomId = registration.roomId
      ..inviteCode = registration.inviteCode;
    await _db.chatGroupBox.put(group.id, group);
    _reportInviteCodeRotated(previousCode, registration.inviteCode);
    if (_disposed) return registration.inviteCode;

    // 这次调用同时负责"首次共享"的连接建立：此前群还是纯本机的，
    // _startRealtimeIfNeeded 之前直接返回过，现在条件才满足。
    await _startRealtimeIfNeeded();
    if (_canTouchUi) _setUiState(() {});
    return registration.inviteCode;
  }

  /// 邀请码被服务端换掉时告诉主人。
  ///
  /// 房间号没变，已经在群里的客人完全不受影响；但主人可能已经把旧码发出去
  /// 了，不提醒的话 TA 会继续念一个永远解析不了的码。邀请面板会显示新码，
  /// 这条提示补的是"为什么变了"。
  void _reportInviteCodeRotated(String? previousCode, String currentCode) {
    if (previousCode == null || previousCode.isEmpty) return;
    if (previousCode == currentCode) return;
    if (!mounted) return;
    AppToast.show(context, '旧邀请码已失效，已更换为 $currentCode',
        icon: Icons.autorenew_rounded);
  }

  /// 断开并释放连接。离开页面、销毁页面时都要调用。
  Future<void> _stopRealtime() async {
    final client = _realtimeClient;
    final events = _realtimeEvents;
    _realtimeClient = null;
    _realtimeEvents = null;
    await events?.cancel();
    if (client == null) return;
    client.state.removeListener(_handleRealtimeStateChanged);
    await client.dispose();
  }

  /// 这条消息是否需要广播给房间里的其他真人。
  ///
  /// 三种不广播的情况：
  /// - 真人成员的消息：那是别人说的，原样发回去会形成回声循环；
  /// - 工作模式的进度气泡：那是主人本机跑工具的过程，和服务端无关；
  /// - 内容为空：附件消息和流式占位都会走到这里，广播出去对方只看到空气泡，
  ///   而且服务端会直接以"text must not be empty"拒收整帧。
  bool _shouldRelayToRoom(Message message) {
    if (message.senderType == Message.senderTypeMember) return false;
    if (WorkModeTaskLifecycle.isProgressMessageId(message.id)) return false;
    return message.content.trim().isNotEmpty;
  }

  /// 替 AI 角色发言时，要告诉服务端这句话其实是谁说的。
  ///
  /// 本人手打的消息返回 null——说话的本来就是本账号。工作模式里的 `system`
  /// 提示没有对应角色，同样按本人发言处理，否则客人端会冒出一个叫
  /// "system" 的群成员。
  RealtimeSpeaker? _relaySpeakerFor(Message message) {
    if (message.senderType != Message.senderTypeAi) return null;
    final character = _displayCharacterById(message.senderId);
    if (character == null) return null;
    return RealtimeSpeaker(id: character.id, name: character.name);
  }

  /// 把本机产生的消息广播给其他真人。
  ///
  /// 这是主人端 AI 回复能到达客人端的唯一出口：AI 回复本身也走
  /// [_appendMessage]，所以在那里统一转发，而不是每个生成流程各发一次。
  ///
  /// 发送失败不回滚本地消息——它已经落库了。但要明确告诉用户对方收不到，
  /// 否则会以为对方"已读不回"。AI 回复不弹这个提示：它是后台产生的，
  /// 掉一句弹一次会把页面刷满，顶部状态条已经说明了当前离线。
  void _relayToRoomIfNeeded(Message message) {
    final client = _realtimeClient;
    if (client == null) return;
    if (!_shouldRelayToRoom(message)) return;

    final speaker = _relaySpeakerFor(message);
    // 服务端对超出上限的帧一律整帧拒收，这里先截断，宁可少说一句，
    // 也不要让客人端收到一条"协议不一致"的告警。
    var text = message.content.trim();
    if (text.length > maxRealtimeTextLength) {
      text = text.substring(0, maxRealtimeTextLength);
    }

    if (client.say(text, speaker: speaker)) return;
    if (speaker != null || !mounted) return;
    AppToast.show(context, '当前离线，这条消息只存在本机',
        icon: Icons.cloud_off_rounded);
  }

  Future<void> _handleRealtimeEvent(RealtimeServerEvent event) async {
    switch (event) {
      case RealtimeJoined():
        _applyRealtimeRoster(event.members);
        // 重连后服务端会重放它内存里最近的那一批，用来补齐断线期间的空档。
        await _replayRecentMessages(event.recent);
      case RealtimePresence():
        _applyRealtimeRoster(event.members);
      case RealtimeIncomingMessage():
        await _persistRemoteMessage(event.message);
      case RealtimeErrorEvent():
        _setRealtimeNotice(_describeRealtimeError(event));
    }
  }

  /// 补齐断线期间错过的消息，已经存过的不重复存。
  ///
  /// 判重查的是"这个会话已经落库的全部 seq"，而不是 [_messages]：后者只装了
  /// 当前这一页（[ChatRoomRepository.loadLatest] 80 条），而被搜索定位或深链
  /// 打开时它甚至是一段围绕目标消息的窗口，压根不含最新的那些。服务端的重放
  /// 窗口又是它自己的配置（默认 50 条）。两边一旦对不上，已经存过的消息就会
  /// 再存一遍，客人的本地历史里冒出重复的发言。
  ///
  /// remoteSeq 只在同一个房间里有意义，所以必须按会话过滤——不同群都从 1 开始编号。
  Future<void> _replayRecentMessages(List<RealtimeChatMessage> recent) async {
    if (recent.isEmpty) return;
    final known = _db.messageBox.values
        .where((m) => m.groupId == widget.groupId && m.remoteSeq != null)
        .map((m) => m.remoteSeq!)
        .toSet();
    for (final message in recent) {
      if (!known.add(message.seq)) continue;
      await _persistRemoteMessage(message);
    }
  }

  /// 把一条远端消息落库并显示。
  Future<void> _persistRemoteMessage(RealtimeChatMessage incoming) async {
    // 服务端会把我们自己的发言原样回显（用来回传分配的 seq）。本机在发送时
    // 就已经存过了，这里必须跳过，否则自己每说一句都会重复一遍。
    // 主人端替 AI 角色广播的回复同样带的是主人的 userId，也一并跳过。
    if (incoming.userId == _realtimeUserId) return;

    // 按 seq 精确去重，而不是拿"同一人+同一时刻+同一内容"去猜。
    // 这一层只覆盖当前页面已经显示出来的消息（实时那条路径不可能重复）；
    // 重连重放的完整判重见 [_replayRecentMessages]。
    if (_messages.any((m) => m.remoteSeq == incoming.seq)) return;

    final message = Message(
      groupId: widget.groupId,
      // 主人端替角色发言时 speaker.id 是那个角色在主人本机的 id。对客人而言
      // 只是个不透明的稳定字符串——客人本机并没有这个角色，所以整条消息
      // 仍然按"真人成员"渲染：名字用快照，头像用昵称首字，也不会被当成
      // 角色接上"点进角色详情页"的交互（那个页面在客人这边是打不开的）。
      senderId: incoming.speaker?.id ?? incoming.userId,
      senderType: Message.senderTypeMember,
      senderName: incoming.authorName,
      remoteSeq: incoming.seq,
      content: incoming.text,
      // 用本机接收时间而不是服务端的 sentAt：本机历史里还混着本地产生的
      // 消息，只有单调递增的本地时间才能保证新消息永远排在最后。
      // 真正的顺序依据是 remoteSeq。
      timestamp: DateTime.now(),
    );
    await _appendMessage(message);
  }

  /// 用落库的花名册预热成员表。
  ///
  /// 服务端连不上时（断网、还没配联机）成员表会一直是空的，历史消息里那些
  /// 没有昵称快照的真人就会退化成"群成员"。预热带不来实时性，但至少能
  /// 显示成具体的人。连上之后 [_applyRealtimeRoster] 会用服务端列表整体覆盖。
  void _seedRosterFromGroup(ChatGroup group) {
    if (_realtimeMemberNames.isNotEmpty) return;
    for (final entry in group.humanMemberNames.entries) {
      if (entry.key == _realtimeUserId) continue;
      if (entry.value.trim().isEmpty) continue;
      _realtimeMemberNames[entry.key] = entry.value;
    }
  }

  /// 用服务端给的完整成员列表刷新花名册，并落库到群上以便离线时也能显示。
  void _applyRealtimeRoster(List<RealtimeMember> members) {
    var changed = false;
    final live = <String>{};
    for (final member in members) {
      if (member.userId == _realtimeUserId) continue;
      live.add(member.userId);
      if (_realtimeMemberNames[member.userId] != member.displayName) {
        _realtimeMemberNames[member.userId] = member.displayName;
        changed = true;
      }
    }
    for (final known in _realtimeMemberNames.keys.toList()) {
      if (live.contains(known)) continue;
      _realtimeMemberNames.remove(known);
      changed = true;
    }
    if (!changed) return;

    unawaited(_persistRealtimeRoster());
    if (_canTouchUi) _setUiState(() {});
  }

  Future<void> _persistRealtimeRoster() async {
    final group = _group;
    if (group == null || _group?.isShared != true) return;
    try {
      group.humanMemberNames = Map<String, String>.from(_realtimeMemberNames);
      await _db.chatGroupBox.put(group.id, group);
    } on Object {
      // 花名册只是展示用的缓存，写不进去不影响收发消息。
    }
  }

  void _handleRealtimeStateChanged() {
    final client = _realtimeClient;
    if (client == null || _disposed) return;
    final next = client.state.value;
    if (next == _realtimeState) return;
    if (!_canTouchUi) {
      _realtimeState = next;
      return;
    }
    _setUiState(() => _realtimeState = next);
  }

  void _setRealtimeNotice(String? notice) {
    if (_realtimeNotice == notice) return;
    if (!_canTouchUi) {
      _realtimeNotice = notice;
      return;
    }
    _setUiState(() => _realtimeNotice = notice);
  }

  String _describeRealtimeError(RealtimeErrorEvent event) {
    switch (event.code) {
      case 'ROOM_FULL':
        return '群里人太多，暂时进不去';
      case 'JOIN_TIMEOUT':
        return '连接超时，未能进入群聊';
      case 'ALREADY_JOINED':
        return '连接状态异常，请退出后重新进群';
      case 'NOT_JOINED':
        return '尚未进群，这条消息没能发出去';
      case 'BAD_REQUEST':
        return '客户端与服务端协议不一致（${event.message}）';
      default:
        return '实时服务返回错误：${event.code}';
    }
  }

  /// 连接状态的中文描述，供顶部提示条使用。
  String get _realtimeStatusLabel {
    switch (_realtimeState) {
      case RealtimeConnectionState.idle:
        return '未连接';
      case RealtimeConnectionState.connecting:
        return '连接中…';
      case RealtimeConnectionState.connected:
        return '已连接（${_realtimeMemberNames.length + 1} 人在线）';
      case RealtimeConnectionState.reconnecting:
        return '连接断开，正在重连…';
      case RealtimeConnectionState.closed:
        return '已断开';
    }
  }
}
