import 'package:chat_group/features/work_mode/work_artifact_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('requestsSingleArtifact', () {
    test('用户只点名一个交付文件时成立（2026-10-10 现场原话）', () {
      expect(
        requestsSingleArtifact(
            '在\n/Users/fengye/Desktop/chat_group_out 这个文件家中 创建一个目录，'
            '目录中的内容生成一份 飞行棋游戏的HTML，第一版只需要和AI对战即可'),
        isTrue,
      );
    });

    test('句中的「和」不构成并列时仍算单产物', () {
      // 「和AI对战」里的「和」是连词但后面不是产物名词，不能据此否决。
      expect(requestsSingleArtifact('生成一份 飞行棋游戏的HTML，第一版只需要和AI对战即可'),
          isTrue);
    });

    test('分开点名两个产物就不算单产物', () {
      expect(requestsSingleArtifact('生成一份 飞行棋游戏的HTML 和一份说明文档'), isFalse);
      expect(requestsSingleArtifact('生成一份报告以及一个网站'), isFalse);
      expect(requestsSingleArtifact('写一份文档、一个脚本'), isFalse);
      expect(requestsSingleArtifact('做一个网页和它的样式'), isFalse);
    });

    test('用逗号、「并」「然后」「再」并列的两个产物也不算单产物', () {
      // 这些连接方式没被逐个枚举成连词，判据要落在"两处量词 + 产物名词"上。
      expect(requestsSingleArtifact('生成一份报告，一份说明'), isFalse);
      expect(requestsSingleArtifact('生成一份报告并生成一份说明'), isFalse);
      expect(requestsSingleArtifact('先做一份文档，再做一份网页'), isFalse);
      expect(requestsSingleArtifact('生成一份报告，同时生成一份说明文档'), isFalse);
      expect(requestsSingleArtifact('写一份文档及一个脚本'), isFalse);
      expect(
        requestsSingleArtifact('create one html file and one readme'),
        isFalse,
      );
    });

    test('量词落在非交付物上时不算数', () {
      // 现场原话里的「创建一个目录」是路径，不是交付物；只有后面那份 HTML 算数。
      expect(
        requestsSingleArtifact('创建一个目录，目录中的内容生成一份 飞行棋游戏的HTML'),
        isTrue,
      );
    });

    test('复数量词直接否决', () {
      expect(requestsSingleArtifact('生成多个文件'), isFalse);
      expect(requestsSingleArtifact('帮我做三份文档'), isFalse);
      expect(requestsSingleArtifact('create several files'), isFalse);
    });

    test('没有单数量词时不成立', () {
      expect(requestsSingleArtifact('生成飞行棋游戏的HTML'), isFalse);
      expect(requestsSingleArtifact('开发一个登录模块'), isFalse);
    });

    test('单数量词与产物名词跨句时不成立', () {
      expect(requestsSingleArtifact('生成一份。然后做网页'), isFalse);
    });

    test('空串与纯空白不成立', () {
      expect(requestsSingleArtifact(''), isFalse);
      expect(requestsSingleArtifact('   '), isFalse);
    });

    test('单产物请求的常见写法都成立', () {
      expect(requestsSingleArtifact('写一份报告'), isTrue);
      expect(requestsSingleArtifact('生成一个 HTML'), isTrue);
      expect(requestsSingleArtifact('做一张图表'), isFalse);
      expect(requestsSingleArtifact('create one html file'), isTrue);
    });
  });
}
