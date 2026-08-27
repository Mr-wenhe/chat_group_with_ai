import 'package:chat_group/services/wecom_push_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WeComPushService pure helpers', () {
    test('buildUserBody 包含 touser / agentid / text', () {
      final body = WeComPushService.buildUserBody('zhangsan', '你好', 1000002);
      expect(body['touser'], 'zhangsan');
      expect(body['agentid'], 1000002);
      expect(body['msgtype'], 'text');
      expect((body['text'] as Map)['content'], '你好');
    });

    test('buildUserBody 支持多人 userId', () {
      final body = WeComPushService.buildUserBody('a|b|c', 'hi', 1);
      expect(body['touser'], 'a|b|c');
    });

    test('buildGroupBody 使用 markdown 通道', () {
      final body = WeComPushService.buildGroupBody('hello');
      expect(body['msgtype'], 'markdown');
      expect((body['markdown'] as Map)['content'], 'hello');
    });

    test('parseResult 在 errcode==0 时成功', () {
      final r = WeComPushService.parseResult({'errcode': 0, 'errmsg': 'ok'});
      expect(r.ok, isTrue);
      expect(r.detail, '已发送');
    });

    test('parseResult 在 errcode!=0 时失败并保留错误码', () {
      final r = WeComPushService.parseResult(
          {'errcode': 40014, 'errmsg': 'invalid credential'});
      expect(r.ok, isFalse);
      expect(r.errcode, 40014);
      expect(r.detail, contains('40014'));
      expect(r.detail, contains('invalid credential'));
    });

    test('parseResult 处理非 Map 响应', () {
      final r = WeComPushService.parseResult('garbage');
      expect(r.ok, isFalse);
    });
  });
}
