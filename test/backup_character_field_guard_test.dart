import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// IP 形象相关的字段清单，往返 / 明文守卫 / 源码守卫三处共用同一份。
///
/// 新增 IP 形象字段时只改这里 —— 三处断言各自漏掉一个键，就会重现
/// 「导出写了、导入没读」那类单边遗漏。
const _kIpImageKeys = ['ipImageRelPath', 'avatarFromIpImage', 'ipImageStyle', 'voiceId'];

AICharacter _character({
  String voiceId = 'voice-1',
  String ipImageRelPath = '角色_c1/1_ip.png',
  bool avatarFromIpImage = true,
  String ipImageStyle = 'watercolor',
}) =>
    AICharacter(
      id: 'c1',
      name: '小美',
      avatar: '美',
      age: 25,
      role: '游戏主播',
      personalityTags: const ['活泼', '开朗'],
      systemPrompt: '热情陪伴用户。',
      apiKey: '',
      apiProvider: 'custom',
      modelName: 'demo',
      customBaseUrl: 'https://example.invalid',
      apiConfigId: 'config-1',
      voiceId: voiceId,
      ipImageRelPath: ipImageRelPath,
      avatarFromIpImage: avatarFromIpImage,
      ipImageStyle: ipImageStyle,
    );

void main() {
  group('角色字段备份往返', () {
    test('character / decodeCharacter 保留 IP 形象与 voiceId', () {
      final source = _character();

      final decoded = BackupEntityCodec.decodeCharacter(
        BackupEntityCodec.character(source),
      );

      expect(decoded.ipImageRelPath, '角色_c1/1_ip.png');
      expect(decoded.avatarFromIpImage, isTrue);
      expect(decoded.ipImageStyle, 'watercolor');
      expect(decoded.voiceId, 'voice-1');
    });

    test('旧备份缺新键时回落到默认值', () {
      final legacy = BackupEntityCodec.character(_character())
        ..remove('ipImageRelPath')
        ..remove('avatarFromIpImage')
        ..remove('ipImageStyle')
        ..remove('voiceId');

      final decoded = BackupEntityCodec.decodeCharacter(legacy);

      expect(decoded.ipImageRelPath, '');
      expect(decoded.avatarFromIpImage, isFalse);
      expect(decoded.ipImageStyle, '');
      expect(decoded.voiceId, '');
    });

    test('characterForBackup 不写出明文 Key，也不给新字段安凭据语义', () {
      final value = BackupEntityCodec.characterForBackup(
        _character(),
        includeMemorySummary: true,
      );

      // .cgbak 会带 apiProvider / apiConfigId（还原后需重新绑定 Key），
      // 但绝不写 apiKey 明文 —— decode 侧固定回填 ''。
      expect(value.containsKey('apiKey'), isFalse);
      // IP 形象是相对文件路径、布尔开关与画风 id，不得混入凭据字段名。
      for (final key in _kIpImageKeys) {
        expect(value.containsKey(key), isTrue);
        expect(key, isNot(contains('api')));
      }
    });
  });

  group('codec 源码字段守卫', () {
    // 同 api_config_connection_test_guard_test 的做法：直接 grep 源码，
    // 防止「只改导出漏改导入」这类单边遗漏（voiceId 正是这么漏掉的）。
    late String source;

    setUpAll(() async {
      source = await File(
        'lib/features/backup/backup_entity_codec_records.dart',
      ).readAsString();
    });

    test('character() 写出的键覆盖 IP 形象与 voiceId', () {
      final encoderBody = _functionBody(source, 'static Map<String, dynamic> character(');
      for (final key in _kIpImageKeys) {
        expect(
          encoderBody,
          contains("'$key':"),
          reason: 'character() 必须写出 $key，否则备份丢失该字段',
        );
      }
    });

    test('decodeCharacter() 读取同名键', () {
      final decoderBody = _functionBody(source, 'static AICharacter decodeCharacter(');
      for (final key in _kIpImageKeys) {
        expect(
          decoderBody,
          contains("json['$key']"),
          reason: 'decodeCharacter() 必须读取 $key，否则还原后字段被清空',
        );
      }
    });
  });
}

/// 截取 [signature] 起、到下一个 `static ` 之前的方法体，用于逐方法断言。
String _functionBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
  final rest = source.substring(start + signature.length);
  final end = rest.indexOf('static ');
  return end < 0 ? rest : rest.substring(0, end);
}
