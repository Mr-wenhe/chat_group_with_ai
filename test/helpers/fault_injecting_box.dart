import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:hive/hive.dart';

class FaultInjectingBox implements Box<dynamic> {
  final Box<dynamic> delegate;
  final bool failStateDelete;
  int? failStatePutAt;
  int _statePutCount = 0;

  FaultInjectingBox(
    this.delegate, {
    this.failStateDelete = false,
    this.failStatePutAt,
  });

  @override
  String get name => delegate.name;
  @override
  bool get isOpen => delegate.isOpen;
  @override
  String? get path => delegate.path;
  @override
  bool get lazy => delegate.lazy;
  @override
  Iterable<dynamic> get keys => delegate.keys;
  @override
  int get length => delegate.length;
  @override
  bool get isEmpty => delegate.isEmpty;
  @override
  bool get isNotEmpty => delegate.isNotEmpty;
  @override
  dynamic keyAt(int index) => delegate.keyAt(index);
  @override
  Stream<BoxEvent> watch({dynamic key}) => delegate.watch(key: key);
  @override
  bool containsKey(dynamic key) => delegate.containsKey(key);

  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (key == CharacterGenderMigrator.stateKey) {
      _statePutCount++;
      if (failStatePutAt == _statePutCount) {
        failStatePutAt = null;
        throw StateError('simulated progress write failure');
      }
    }
    await delegate.put(key, value);
  }

  @override
  Future<void> putAt(int index, dynamic value) => delegate.putAt(index, value);
  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) =>
      delegate.putAll(entries);
  @override
  Future<int> add(dynamic value) => delegate.add(value);
  @override
  Future<Iterable<int>> addAll(Iterable<dynamic> values) =>
      delegate.addAll(values);

  @override
  Future<void> delete(dynamic key) async {
    if (failStateDelete && key == CharacterGenderMigrator.stateKey) {
      throw StateError('simulated completion cleanup failure');
    }
    await delegate.delete(key);
  }

  @override
  Future<void> deleteAt(int index) => delegate.deleteAt(index);
  @override
  Future<void> deleteAll(Iterable<dynamic> keys) => delegate.deleteAll(keys);
  @override
  Future<void> compact() => delegate.compact();
  @override
  Future<int> clear() => delegate.clear();
  @override
  Future<void> close() => delegate.close();
  @override
  Future<void> deleteFromDisk() => delegate.deleteFromDisk();
  @override
  Future<void> flush() => delegate.flush();
  @override
  Iterable<dynamic> get values => delegate.values;
  @override
  Iterable<dynamic> valuesBetween({dynamic startKey, dynamic endKey}) =>
      delegate.valuesBetween(startKey: startKey, endKey: endKey);
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  dynamic getAt(int index) => delegate.getAt(index);
  @override
  Map<dynamic, dynamic> toMap() => delegate.toMap();
}

class TestDatabaseService extends DatabaseService {
  final Box<dynamic> _appSettings;

  TestDatabaseService(this._appSettings);

  @override
  Box<dynamic> get appSettingsBox => _appSettings;
}
