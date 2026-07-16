import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import '../../../providers/providers.dart';

final chatGroupsProvider =
    StateNotifierProvider<ChatGroupsNotifier, List<ChatGroup>>((ref) {
  return ChatGroupsNotifier(ref.read(databaseServiceProvider));
});

class ChatGroupsNotifier extends StateNotifier<List<ChatGroup>> {
  final DatabaseService _db;

  ChatGroupsNotifier(this._db) : super([]) {
    _loadGroups();
  }

  void _loadGroups() {
    state = _db.chatGroupBox.values.toList();
  }

  Future<void> addGroup(ChatGroup group) async {
    await _db.chatGroupBox.put(group.id, group);
    _loadGroups();
  }

  Future<void> updateGroup(ChatGroup group) async {
    await _db.chatGroupBox.put(group.id, group);
    _loadGroups();
  }

  Future<DataLifecycleResult> deleteGroup(String id) async {
    final result = await DataLifecycleService(db: _db).deleteGroup(id);
    _loadGroups();
    return result;
  }

  ChatGroup? getGroupById(String id) {
    try {
      return _db.chatGroupBox.get(id);
    } catch (e) {
      return null;
    }
  }
}
