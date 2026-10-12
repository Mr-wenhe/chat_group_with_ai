import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/work_mode/work_detail_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const taskId = 'c5b9cb7a-651f-45c5-ac81-eae78e8aca4c';
  const digest = '86f37541e97fa4cdd9484fcf';
  const eventsDir = '/Users/u/Library/Application Support/app'
      '/work_mode_agent/events';

  MediaAttachment file(String path, {String? name, String type = 'file'}) =>
      MediaAttachment(
        type: type,
        localPath: path,
        fileName: name,
        fileSize: 3269,
        mimeType: 'application/json',
      );

  group('识别内部详情附件', () {
    test('讨论详情按落盘形状命中', () {
      expect(
        isWorkModeDetailAttachment(file(
          '$eventsDir/$taskId.detail.$digest.json',
          name: '方案与验收详情.json',
        )),
        isTrue,
      );
    });

    test('同一落盘形状的其它详情也命中', () {
      // 调查来源与结果、完整公开正文、工作项交接都写同一个目录，
      // 只是文件名参数不同，所以判据取路径形状而不是文件名清单。
      for (final name in ['调查来源与结果.json', '完整公开正文.json', '工作项交接.json']) {
        expect(
          isWorkModeDetailAttachment(
            file('$eventsDir/$taskId.detail.$digest.json', name: name),
          ),
          isTrue,
          reason: name,
        );
      }
    });

    test('用户上传的同名文件不命中', () {
      expect(
        isWorkModeDetailAttachment(file(
          '/Users/u/Library/Application Support/app/data/media/方案与验收详情.json',
          name: '方案与验收详情.json',
        )),
        isFalse,
      );
    });

    test('事件目录外即使文件名形状相同也不命中', () {
      expect(
        isWorkModeDetailAttachment(file('/tmp/$taskId.detail.$digest.json')),
        isFalse,
      );
    });

    test('摘要不是 24 位十六进制时不命中', () {
      expect(
        isWorkModeDetailAttachment(file('$eventsDir/$taskId.detail.abc.json')),
        isFalse,
      );
      expect(
        isWorkModeDetailAttachment(file('$eventsDir/$taskId.jsonl')),
        isFalse,
      );
      expect(
        isWorkModeDetailAttachment(
            file('$eventsDir/$taskId.detail.$digest.JSON')),
        isFalse,
      );
    });

    test('任务标识不合法时不命中', () {
      // taskId 只允许 [A-Za-z0-9_-]{1,128}，含点的名字不可能是本应用写的。
      expect(
        isWorkModeDetailAttachment(file('$eventsDir/x.y.detail.$digest.json')),
        isFalse,
      );
    });

    test('非文件类型不进入详情渲染', () {
      expect(
        isWorkModeDetailAttachment(file(
          '$eventsDir/$taskId.detail.$digest.json',
          type: 'image',
        )),
        isFalse,
      );
    });
  });
}
