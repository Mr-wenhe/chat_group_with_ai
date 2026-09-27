import 'dart:convert';

import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime(2026, 9, 23, 9, 30);

  RelationshipState make({DateTime? moodAt}) => RelationshipState(
        groupId: 'global',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        recentMood: RelationshipMood.warm,
        recentMoodAt: moodAt,
      );

  test('往返保留 recentMoodAt', () {
    final decoded = BackupEntityCodec.decodeRelationship(
      BackupEntityCodec.relationship(make(moodAt: at)),
    );

    expect(decoded.recentMood, RelationshipMood.warm);
    // 编解码把日期归一化为 UTC，契约是「同一时刻」而非同一 DateTime 对象。
    expect(decoded.recentMoodAt!.isAtSameMomentAs(at), isTrue);
  });

  test('序列化结果可被 JSON 编码（日期必须是字符串而非 DateTime）', () {
    // 备份包最终要走 jsonEncode；若字段里留了 DateTime 对象，导出会整体失败。
    final json = BackupEntityCodec.relationship(make(moodAt: at));

    expect(json['recentMoodAt'], isA<String>());
    expect(() => jsonEncode(json), returnsNormally);

    final decoded =
        BackupEntityCodec.decodeRelationship(jsonDecode(jsonEncode(json))
            as Map<String, dynamic>);
    expect(decoded.recentMoodAt!.isAtSameMomentAs(at), isTrue);
  });

  test('缺少 recentMoodAt 的旧格式仍可解码，且按已过期处理', () {
    final json = BackupEntityCodec.relationship(make(moodAt: at))
      ..remove('recentMoodAt');

    final decoded = BackupEntityCodec.decodeRelationship(json);

    expect(decoded.recentMood, RelationshipMood.warm);
    expect(decoded.recentMoodAt, isNull);
    expect(decoded.effectiveMood(), RelationshipMood.neutral);
  });
}
