part of 'work_collaboration_state.dart';

Map<String, dynamic> _freezeMap(Map<String, dynamic> source) {
  dynamic freeze(dynamic value) => value is Map
      ? Map<String, dynamic>.unmodifiable(
          value.map((key, item) => MapEntry(key as String, freeze(item))))
      : value is List
          ? List.unmodifiable(value.map(freeze))
          : value;
  return freeze(source) as Map<String, dynamic>;
}
