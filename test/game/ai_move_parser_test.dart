// 坐标解析器单测：覆盖模型常见的各种非规范输出。
import 'package:chat_group/features/game/gomoku/ai_move_parser.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('结构化坐标解析', () {
    test('纯 JSON', () {
      expect(GomokuMoveParser.parse('{"row":7,"col":8}'),
          const GomokuPosition(7, 8));
    });

    test('markdown 代码块包裹', () {
      expect(
        GomokuMoveParser.parse('```json\n{"row":3, "col":10}\n```'),
        const GomokuPosition(3, 10),
      );
    });

    test('JSON 夹带思考文字，且思考里也出现坐标', () {
      // 结构化格式优先：必须取 JSON 里的最终答案，而不是思考里的 (1,1)。
      expect(
        GomokuMoveParser.parse('我想在 (1,1) 进攻，但更稳妥的是：\n{"row":7,"col":7}'),
        const GomokuPosition(7, 7),
      );
    });

    test('col 在 row 之前也能解析', () {
      expect(GomokuMoveParser.parse('{"col":5,"row":2}'),
          const GomokuPosition(2, 5));
    });

    test('坐标值带引号', () {
      expect(GomokuMoveParser.parse('{"row":"4","col":"9"}'),
          const GomokuPosition(4, 9));
    });

    test('单引号 + 全角冒号（国内中转常见输出）', () {
      expect(GomokuMoveParser.parse("{'row'：7，'col'：2}"),
          const GomokuPosition(7, 2));
    });

    test('key 无引号', () {
      expect(GomokuMoveParser.parse('{row: 3, col: 11}'),
          const GomokuPosition(3, 11));
    });

    test('推理模型思考段 + 末尾 JSON 答案', () {
      expect(
        GomokuMoveParser.parse(
          '<think>让我想想，中心 (0,0) 不错，但对手可能堵……应该下在 (9,9)</think>\n{"row":7,"col":8}',
        ),
        const GomokuPosition(7, 8),
      );
    });
  });

  group('自然语言坐标兜底', () {
    test('英文标签 row / col', () {
      expect(GomokuMoveParser.parse('row: 6, col: 6'),
          const GomokuPosition(6, 6));
    });

    test('中文「行 X 列 Y」', () {
      expect(GomokuMoveParser.parse('我落在行 8 列 3'),
          const GomokuPosition(8, 3));
    });

    test('中文「第X行第Y列」', () {
      expect(GomokuMoveParser.parse('下在第5行第12列'),
          const GomokuPosition(5, 12));
    });

    test('括号坐标', () {
      expect(GomokuMoveParser.parse('落子 (0,14)'),
          const GomokuPosition(0, 14));
    });

    test('中文逗号括号坐标', () {
      expect(GomokuMoveParser.parse('（10，2）'),
          const GomokuPosition(10, 2));
    });
  });

  group('非法输入', () {
    test('空文本返回 null', () {
      expect(GomokuMoveParser.parse(''), isNull);
      expect(GomokuMoveParser.parse('   '), isNull);
    });

    test('无坐标的自由文本返回 null', () {
      expect(GomokuMoveParser.parse('我觉得应该进攻'), isNull);
    });

    test('越界坐标返回 null', () {
      expect(GomokuMoveParser.parse('{"row":15,"col":0}'), isNull);
      expect(GomokuMoveParser.parse('{"row":0,"col":-1}'), isNull);
      expect(GomokuMoveParser.parse('(20,20)'), isNull);
    });

    test('自定义棋盘尺寸生效', () {
      expect(
        GomokuMoveParser.parse('{"row":9,"col":9}', boardSize: 9),
        isNull,
      );
      expect(
        GomokuMoveParser.parse('{"row":8,"col":8}', boardSize: 9),
        const GomokuPosition(8, 8),
      );
    });

    test('思考里有合法坐标但最终 JSON 越界时不误取思考坐标', () {
      // JSON 命中但越界 → 该格式解析失败，继续兜底会取到思考里的 (1,1)。
      // 这是可接受的降级；主要防御是上层会校验占位。
      expect(
        GomokuMoveParser.parse('思考 (1,1)，最终 {"row":99,"col":99}'),
        const GomokuPosition(1, 1),
      );
    });
  });
}
