import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/search/message_search_index.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class GlobalSearchPage extends ConsumerStatefulWidget {
  const GlobalSearchPage({super.key});

  @override
  ConsumerState<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends ConsumerState<GlobalSearchPage> {
  final _queryController = TextEditingController();
  late final DatabaseService _db;
  late final MessageSearchIndex _index;
  List<MessageSearchResult> _results = [];
  String? _conversationId;
  String? _senderId;
  String? _attachmentType;
  DateTime? _from;
  DateTime? _to;
  bool _mentionsOnly = false;
  bool _building = true;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _index = MessageSearchIndex(_db);
    unawaited(_rebuild());
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _index.status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('全局搜索'),
        actions: [
          IconButton(
            tooltip: '重建索引',
            onPressed: _building ? null : _rebuild,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '清除索引',
            onPressed: _building ? null : _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_building) LinearProgressIndicator(value: _progress),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                TextField(
                  controller: _queryController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '搜索消息、角色名或附件文件名',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: IconButton(
                      onPressed: _building ? null : _search,
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        status.lastBuiltAt == null
                            ? '索引已清除'
                            : '已索引 ${status.indexedMessages} 条消息 · '
                                '${DateFormat('MM-dd HH:mm').format(status.lastBuiltAt!.toLocal())}',
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _showFilters,
                      icon: const Icon(Icons.tune_rounded),
                      label: Text(_hasFilters ? '筛选已启用' : '筛选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('输入关键词搜索本地聊天记录'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) => _resultTile(_results[index]),
                  ),
          ),
        ],
      ),
    );
  }

  bool get _hasFilters =>
      _conversationId != null ||
      _senderId != null ||
      _attachmentType != null ||
      _from != null ||
      _to != null ||
      _mentionsOnly;

  Widget _resultTile(MessageSearchResult result) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      title: _highlight(result.snippet),
      subtitle: Text('${result.conversationName} · ${result.senderName} · '
          '${DateFormat('yyyy-MM-dd HH:mm').format(result.timestamp.toLocal())}'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatRoomPage(
          groupId: result.conversationId,
          initialMessageId: result.messageId,
        ),
      )),
    );
  }

  Widget _highlight(String snippet) {
    final terms = _queryController.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty);
    final lower = snippet.toLowerCase();
    final query = terms.cast<String?>().firstWhere(
          (term) => lower.contains(term!.toLowerCase()),
          orElse: () => null,
        );
    if (query == null) return Text(snippet);
    final index = lower.indexOf(query.toLowerCase());
    if (index < 0) return Text(snippet);
    return Text.rich(TextSpan(children: [
      TextSpan(text: snippet.substring(0, index)),
      TextSpan(
        text: snippet.substring(index, index + query.length),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      TextSpan(text: snippet.substring(index + query.length)),
    ]));
  }

  Future<void> _rebuild() async {
    setState(() {
      _building = true;
      _progress = 0;
    });
    await _index.rebuild(onProgress: (value) {
      if (mounted) setState(() => _progress = value);
    });
    if (mounted) setState(() => _building = false);
  }

  Future<void> _clear() async {
    await _index.clear();
    if (mounted) setState(() => _results = []);
  }

  Future<void> _search() async {
    final results = await _index.query(
      _queryController.text,
      filters: MessageSearchFilters(
        conversationId: _conversationId,
        senderId: _senderId,
        from: _from,
        to: _to == null
            ? null
            : DateTime(_to!.year, _to!.month, _to!.day, 23, 59, 59, 999),
        mentionsOnly: _mentionsOnly,
        attachmentType: _attachmentType,
      ),
    );
    if (mounted) setState(() => _results = results);
  }

  Future<void> _showFilters() async {
    var conversationId = _conversationId;
    var senderId = _senderId;
    var attachmentType = _attachmentType;
    var from = _from;
    var to = _to;
    var mentionsOnly = _mentionsOnly;
    final conversations = <String, String>{
      for (final group in _db.chatGroupBox.values) group.id: group.name,
      for (final record in _db.conversationSummaries().values)
        if (DirectChatSession.isDirectConversationId(record.conversationId))
          record.conversationId: _directName(record.conversationId),
    };
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String?>(
                  value: conversationId,
                  decoration: const InputDecoration(labelText: '会话'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部会话')),
                    ...conversations.entries.map((entry) => DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        )),
                  ],
                  onChanged: (value) =>
                      setSheetState(() => conversationId = value),
                ),
                DropdownButtonFormField<String?>(
                  value: senderId,
                  decoration: const InputDecoration(labelText: '发送者'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部发送者')),
                    const DropdownMenuItem(value: 'user', child: Text('我')),
                    ..._db.aiCharacterBox.values
                        .map((character) => DropdownMenuItem(
                              value: character.id,
                              child: Text(character.name),
                            )),
                  ],
                  onChanged: (value) => setSheetState(() => senderId = value),
                ),
                DropdownButtonFormField<String?>(
                  value: attachmentType,
                  decoration: const InputDecoration(labelText: '附件类型'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('全部类型')),
                    DropdownMenuItem(value: 'image', child: Text('图片')),
                    DropdownMenuItem(value: 'video', child: Text('视频')),
                    DropdownMenuItem(value: 'file', child: Text('文件')),
                  ],
                  onChanged: (value) =>
                      setSheetState(() => attachmentType = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('只看 @ 提及'),
                  value: mentionsOnly,
                  onChanged: (value) =>
                      setSheetState(() => mentionsOnly = value),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () async {
                          final value = await _pickDate(from);
                          if (value != null) setSheetState(() => from = value);
                        },
                        child: Text(from == null
                            ? '开始日期'
                            : DateFormat('yyyy-MM-dd').format(from!)),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: () async {
                          final value = await _pickDate(to);
                          if (value != null) setSheetState(() => to = value);
                        },
                        child: Text(to == null
                            ? '结束日期'
                            : DateFormat('yyyy-MM-dd').format(to!)),
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        setSheetState(() {
                          conversationId = null;
                          senderId = null;
                          attachmentType = null;
                          from = null;
                          to = null;
                          mentionsOnly = false;
                        });
                      },
                      child: const Text('重置'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, true),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied == true) {
      setState(() {
        _conversationId = conversationId;
        _senderId = senderId;
        _attachmentType = attachmentType;
        _from = from;
        _to = to;
        _mentionsOnly = mentionsOnly;
      });
      await _search();
    }
  }

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime.now().add(const Duration(days: 1)),
        initialDate: initial ?? DateTime.now(),
      );

  String _directName(String conversationId) {
    final id = DirectChatSession.characterIdFrom(conversationId);
    return '与 ${id == null ? '角色' : _db.aiCharacterBox.get(id)?.name ?? '已删除角色'} 私聊';
  }
}
