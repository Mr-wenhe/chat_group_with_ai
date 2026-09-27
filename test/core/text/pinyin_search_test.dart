import 'package:chat_group/core/text/pinyin_search.dart';
import 'package:flutter_test/flutter_test.dart';

/// 便捷包装：把要匹配的文本包成 digest，避免每个用例重复写。
PinyinDigest d(String text) => PinyinSearch.digest(text);

bool nameHit(String text, String query) =>
    PinyinSearch.matches(d(text), query, mode: PinyinMatchMode.name);

bool contentHit(String text, String query) =>
    PinyinSearch.matches(d(text), query, mode: PinyinMatchMode.content);

void main() {
  group('字面匹配完全保留', () {
    test('中文子串照旧命中', () {
      expect(nameHit('林黛玉', '林'), isTrue);
      expect(nameHit('林黛玉', '黛玉'), isTrue);
      expect(nameHit('林黛玉', '贾'), isFalse);
    });

    test('英文大小写不敏感', () {
      expect(nameHit('Alice', 'alice'), isTrue);
      expect(nameHit('Alice', 'ALI'), isTrue);
    });

    test('空白查询不命中', () {
      expect(nameHit('林黛玉', ''), isFalse);
      expect(nameHit('林黛玉', '   '), isFalse);
    });
  });

  group('名称类：字级全拼前缀', () {
    test('首字全拼的前缀都能命中', () {
      expect(nameHit('林黛玉', 'l'), isTrue);
      expect(nameHit('林黛玉', 'li'), isTrue);
      expect(nameHit('林黛玉', 'lin'), isTrue);
    });

    test('非首字也能命中', () {
      expect(nameHit('林黛玉', 'd'), isTrue);
      expect(nameHit('林黛玉', 'dai'), isTrue);
      expect(nameHit('林黛玉', 'y'), isTrue);
      expect(nameHit('林黛玉', 'yu'), isTrue);
    });

    test('首字母串前缀能命中', () {
      expect(nameHit('林黛玉', 'ldy'), isTrue);
      expect(nameHit('林黛玉', 'ld'), isTrue);
    });

    test('跨字连续拼音能命中', () {
      expect(nameHit('林黛玉', 'lindai'), isTrue);
      expect(nameHit('林黛玉', 'daiyu'), isTrue);
      expect(nameHit('林黛玉', 'lindaiyu'), isTrue);
    });

    test('音节边界内部不命中', () {
      expect(nameHit('林黛玉', 'in'), isFalse);
      expect(nameHit('林黛玉', 'aiy'), isFalse);
      expect(nameHit('林黛玉', 'daiyu2'), isFalse);
      expect(nameHit('林黛玉', 'xz'), isFalse);
    });

    test('英文名支持前缀匹配', () {
      expect(nameHit('Alice', 'a'), isTrue);
      expect(nameHit('Alice', 'ali'), isTrue);
    });
  });

  group('名称类：多音字全部读音', () {
    test('姓氏「单」的三个读音都能命中', () {
      expect(nameHit('单雄信', 'dan'), isTrue);
      expect(nameHit('单雄信', 'shan'), isTrue);
      expect(nameHit('单雄信', 'chan'), isTrue);
    });

    test('姓氏「解」的两个读音都能命中', () {
      expect(nameHit('解维', 'jie'), isTrue);
      expect(nameHit('解维', 'xie'), isTrue);
    });

    test('首字母串也按多音字展开', () {
      expect(nameHit('单雄信', 'sxx'), isTrue);
      expect(nameHit('单雄信', 'dxx'), isTrue);
      expect(nameHit('单雄信', 'cxx'), isTrue);
    });
  });

  group('名称类：繁体归一化', () {
    test('繁体名能用简体拼音搜到', () {
      expect(nameHit('張三', 'zhang'), isTrue);
      expect(nameHit('張三', 'zs'), isTrue);
      expect(nameHit('張三', '張'), isTrue);
    });
  });

  group('正文类：≥2 个字母才启用拼音', () {
    test('两个字母以上的拼音前缀命中', () {
      expect(contentHit('今天天气不错', 'jint'), isTrue);
      expect(contentHit('今天天气不错', 'jtt'), isTrue);
    });

    test('单个字母不触发拼音', () {
      expect(contentHit('今天天气不错', 't'), isFalse);
      expect(contentHit('今天天气不错', 'j'), isFalse);
    });

    test('单个中文字仍然命中', () {
      expect(contentHit('今天天气不错', '天'), isTrue);
    });

    test('名称类不受该门槛限制', () {
      expect(nameHit('林黛玉', 'l'), isTrue);
    });
  });

  group('多词查询按 AND 组合', () {
    test('两个词都命中才算命中', () {
      expect(contentHit('红楼梦 林黛玉', 'hong lin'), isTrue);
      expect(contentHit('红楼梦 林黛玉', 'hong wang'), isFalse);
    });
  });

  group('高亮区间', () {
    test('中文字面命中返回该字区间', () {
      expect(
        PinyinSearch.highlightSpans(d('林黛玉'), '林',
            mode: PinyinMatchMode.name),
        [(start: 0, end: 1)],
      );
    });

    test('拼音命中返回对应汉字区间', () {
      expect(
        PinyinSearch.highlightSpans(d('林黛玉'), 'dai',
            mode: PinyinMatchMode.name),
        [(start: 1, end: 2)],
      );
    });

    test('首字母串命中覆盖整个名字', () {
      expect(
        PinyinSearch.highlightSpans(d('林黛玉'), 'ldy',
            mode: PinyinMatchMode.name),
        [(start: 0, end: 3)],
      );
    });

    test('英文前缀命中返回对应字母区间', () {
      expect(
        PinyinSearch.highlightSpans(d('Alice'), 'ali',
            mode: PinyinMatchMode.name),
        [(start: 0, end: 3)],
      );
    });
  });

  group('多字段查询', () {
    test('每个词只要命中任一字段即可', () {
      final fields = ['林黛玉', '医生', '爱哭'];
      expect(
        PinyinSearch.matchesFields(fields, 'lin',
            mode: PinyinMatchMode.name),
        isTrue,
      );
      expect(
        PinyinSearch.matchesFields(fields, 'ys',
            mode: PinyinMatchMode.name),
        isTrue,
      );
      expect(
        PinyinSearch.matchesFields(fields, 'ak',
            mode: PinyinMatchMode.name),
        isTrue,
      );
    });

    test('不命中任何字段则失败', () {
      expect(
        PinyinSearch.matchesFields(['林黛玉', '医生'], 'wang',
            mode: PinyinMatchMode.name),
        isFalse,
      );
    });

    test('多个词必须分别命中', () {
      expect(
        PinyinSearch.matchesFields(['林黛玉', '医生'], 'lin ys',
            mode: PinyinMatchMode.name),
        isTrue,
      );
      expect(
        PinyinSearch.matchesFields(['林黛玉', '医生'], 'lin wang',
            mode: PinyinMatchMode.name),
        isFalse,
      );
    });

    test('空查询不命中', () {
      expect(
        PinyinSearch.matchesFields(['林黛玉'], '  ',
            mode: PinyinMatchMode.name),
        isFalse,
      );
    });
  });

  group('多字段混合模式', () {
    test('每个字段可以用各自的匹配模式', () {
      final fields = [
        (text: '今天喝咖啡', mode: PinyinMatchMode.content),
        (text: '林黛玉', mode: PinyinMatchMode.name),
      ];
      // 正文走保守模式：两个字母起才触发拼音。
      expect(PinyinSearch.matchesFieldModes(fields, 'jint'), isTrue);
      expect(PinyinSearch.matchesFieldModes(fields, 'j'), isFalse);
      // 名称走宽松模式：单个字母即可。
      expect(PinyinSearch.matchesFieldModes(fields, 'l'), isTrue);
      // 跨字拼音在两种模式下都成立。
      expect(PinyinSearch.matchesFieldModes(fields, 'kafei'), isTrue);
      expect(PinyinSearch.matchesFieldModes(fields, 'wang'), isFalse);
    });

    test('多个词必须分别命中', () {
      final fields = [
        (text: '今天喝咖啡', mode: PinyinMatchMode.content),
        (text: '林黛玉', mode: PinyinMatchMode.name),
      ];
      expect(PinyinSearch.matchesFieldModes(fields, 'jint lin'), isTrue);
      expect(PinyinSearch.matchesFieldModes(fields, 'jint wang'), isFalse);
    });

    test('空查询与空字段列表都不命中', () {
      expect(
        PinyinSearch.matchesFieldModes(
          [(text: '林黛玉', mode: PinyinMatchMode.name)],
          '  ',
        ),
        isFalse,
      );
      expect(
        PinyinSearch.matchesFieldModes(const [], 'lin'),
        isFalse,
      );
    });
  });

  group('预计算字段指纹', () {
    test('digestFields 的结果与 matchesFieldModes 等价', () {
      final fields = [
        (text: '今天喝咖啡', mode: PinyinMatchMode.content),
        (text: '林黛玉', mode: PinyinMatchMode.name),
      ];
      final digests = PinyinSearch.digestFields(fields);

      for (final query in ['jint', 'lin', 'l', 'j', 'wang', '  ']) {
        expect(
          PinyinSearch.matchesFieldDigests(digests, query),
          PinyinSearch.matchesFieldModes(fields, query),
          reason: 'cached and fresh matching must agree for: $query',
        );
      }
    });
  });

  group('精确命中判定与排序', () {
    test('字面命中为真，纯拼音命中为假', () {
      expect(PinyinSearch.matchesLiterally(['林黛玉'], '林'), isTrue);
      expect(PinyinSearch.matchesLiterally(['林黛玉'], '黛玉'), isTrue);
      expect(PinyinSearch.matchesLiterally(['林黛玉'], 'lin'), isFalse);
      expect(PinyinSearch.matchesLiterally(['Alice'], 'alice'), isTrue);
      expect(PinyinSearch.matchesLiterally(['Alice'], 'Alicia'), isFalse);
    });

    test('要求每个词都字面命中', () {
      expect(PinyinSearch.matchesLiterally(['林黛玉', '医生'], '林 医生'), isTrue);
      expect(PinyinSearch.matchesLiterally(['林黛玉', '医生'], '林 ys'), isFalse);
    });

    test('空查询不算字面命中', () {
      expect(PinyinSearch.matchesLiterally(['林黛玉'], '  '), isFalse);
    });

    test('精确命中排到前面，其余保持原有相对顺序', () {
      final ranked = PinyinSearch.exactFirst<String>(
        ['拼音甲', '精确乙', '拼音丙', '精确丁'],
        (item) => item.startsWith('精确'),
      );
      expect(ranked, ['精确乙', '精确丁', '拼音甲', '拼音丙']);
    });

    test('全部同类时保持原有顺序', () {
      expect(
        PinyinSearch.exactFirst<String>(['甲', '乙', '丙'], (_) => false),
        ['甲', '乙', '丙'],
      );
      expect(
        PinyinSearch.exactFirst<String>(['甲', '乙', '丙'], (_) => true),
        ['甲', '乙', '丙'],
      );
    });
  });

  group('健壮性', () {
    test('含 emoji 与标点的文本不崩溃', () {
      expect(nameHit('林黛玉 🎋', 'lin'), isTrue);
      expect(nameHit('林·黛玉', 'ldy'), isTrue);
    });

    test('查询首尾空白被忽略', () {
      expect(nameHit('林黛玉', '  lin  '), isTrue);
    });
  });

  group('指纹缓存', () {
    test('同一文本复用同一个指纹，内容变了则重建', () {
      final first = PinyinSearch.digestCached('林黛玉');
      expect(identical(PinyinSearch.digestCached('林黛玉'), first), isTrue);
      expect(identical(PinyinSearch.digestCached('薛宝钗'), first), isFalse);
    });

    test('缓存有上限，最旧的指纹会被淘汰', () {
      final oldest = PinyinSearch.digestCached('缓存的第 0 条正文');
      for (var index = 0; index < PinyinSearch.digestCacheLimit; index++) {
        PinyinSearch.digestCached('缓存的第 ${index + 1} 条正文');
      }

      expect(
        identical(PinyinSearch.digestCached('缓存的第 0 条正文'), oldest),
        isFalse,
        reason: '超出上限后最旧的条目应被淘汰，缓存不能无限增长',
      );
      final recent = PinyinSearch.digestCached('缓存的第 1 条正文');
      expect(
        identical(PinyinSearch.digestCached('缓存的第 1 条正文'), recent),
        isTrue,
      );
    });
  });
}
