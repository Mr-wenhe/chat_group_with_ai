import 'dart:convert';

import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// 群固定共同设定（共同背景 / 群公告与约定）的备份往返。
///
/// 这两个字段是既有 Hive 字段，本任务只是换了提示词注入位置，所以这里钉的是
/// 回归边界：导出必须带上它们、导入必须读回它们、旧备份缺字段时必须回落默认值
/// 而不是报错或丢群。
void main() {
  ChatGroup make() => ChatGroup(
        id: 'g1',
        name: '夜谈会',
        theme: '情绪支持',
        description: '甲是乙的姐姐；大家都叫群主“老大”',
        announcement: '工作日 20:00 后聊轻松话题',
        aiCharacterIds: const ['c1', 'c2'],
        replyIntervalSeconds: 20,
      );

  test('往返保留共同背景与群公告', () {
    final decoded =
        BackupEntityCodec.decodeGroup(BackupEntityCodec.group(make()));

    expect(decoded.description, '甲是乙的姐姐；大家都叫群主“老大”');
    expect(decoded.announcement, '工作日 20:00 后聊轻松话题');
    expect(decoded.name, '夜谈会');
  });

  test('序列化结果可被 JSON 编码', () {
    final json = BackupEntityCodec.group(make());

    expect(json['description'], isA<String>());
    expect(json['announcement'], isA<String>());
    expect(() => jsonEncode(json), returnsNormally);

    final decoded = BackupEntityCodec.decodeGroup(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
    expect(decoded.announcement, '工作日 20:00 后聊轻松话题');
  });

  test('旧备份缺 announcement 时回落空串，群的其余字段不受影响', () {
    final json = BackupEntityCodec.group(make())..remove('announcement');

    final decoded = BackupEntityCodec.decodeGroup(json);

    expect(decoded.announcement, '');
    expect(decoded.description, '甲是乙的姐姐；大家都叫群主“老大”');
    expect(decoded.aiCharacterIds, ['c1', 'c2']);
  });

  test('共同设定为空时往返仍是空串，不产生占位文本', () {
    final cleared = ChatGroup(
      id: 'g1',
      name: '夜谈会',
      theme: '情绪支持',
      description: '',
      announcement: '',
      aiCharacterIds: const ['c1'],
    );

    final decoded =
        BackupEntityCodec.decodeGroup(BackupEntityCodec.group(cleared));

    expect(decoded.description, isEmpty);
    expect(decoded.announcement, isEmpty);
  });
}
