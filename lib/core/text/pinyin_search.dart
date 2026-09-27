import 'package:lpinyin/lpinyin.dart';

/// 拼音匹配的宽松程度。
///
/// - [name]：用于角色名、成员名等短名称。单个字母即可触发拼音匹配。
/// - [content]：用于消息正文、审计日志等长文本。少于 2 个字母的查询不触发
///   拼音匹配，否则 `l` 会命中所有拼音以 l 开头的字，噪音不可接受。
enum PinyinMatchMode { name, content }

/// 一段文本预计算出的匹配指纹。
///
/// 只保存原文小写用于字面匹配；拼音部分等到真正需要时才逐字查词典。消息正文
/// 动辄几百字，逐字查词典是搜索里最贵的一步，而绝大多数查询（中文原词、
/// `.md`、英文单词）在第一道字面判断里就命中了。
///
/// 逐字保存全部读音（多音字给多个候选），使每次按键匹配时无需重复查询拼音词典。
/// 只参与匹配的字符才会进入读音序列，因此标点、空白、emoji 会被跳过，
/// 「林·黛玉」的首字母串仍然是 `ldy`。
class PinyinDigest {
  PinyinDigest._(this.lowerText, this._source);

  /// 原文小写，用于字面匹配。
  final String lowerText;

  final String _source;

  _PinyinUnits? _pinyin;

  /// 参与拼音匹配的字符数。
  ///
  /// 这个答案是拼音部分的属性，因此首次读取会把它构建出来。
  int get unitCount => _ensurePinyin().readings.length;

  /// 立即构建拼音部分。
  ///
  /// 指纹默认惰性构建，字面命中因此不必付词典查询的代价；但调用方明确要在
  /// 数据变化时预计算（全库索引在后台分批重建，那里让出事件循环）时，提前
  /// 构建比把代价留到查询里更合适。
  void warmUp() => _ensurePinyin();

  /// 首次需要拼音时才构建逐字读音。
  _PinyinUnits _ensurePinyin() {
    final cached = _pinyin;
    if (cached != null) return cached;

    final readings = <List<String>>[];
    final initials = <List<String>>[];
    final starts = <int>[];
    final ends = <int>[];

    var index = 0;
    while (index < _source.length) {
      final length = PinyinSearch._charLengthAt(_source, index);
      if (length == 1) {
        final candidates = PinyinSearch._readingsOf(_source[index]);
        if (candidates != null) {
          readings.add(candidates);
          initials.add(PinyinSearch._initialsOf(candidates));
          starts.add(index);
          ends.add(index + 1);
        }
      }
      index += length;
    }

    return _pinyin = _PinyinUnits(
      readings: readings,
      initials: initials,
      starts: starts,
      ends: ends,
    );
  }
}

/// 一段文本逐字查词典的结果，只在第一次需要拼音时构建。
class _PinyinUnits {
  const _PinyinUnits({
    required this.readings,
    required this.initials,
    required this.starts,
    required this.ends,
  });

  final List<List<String>> readings;
  final List<List<String>> initials;
  final List<int> starts;
  final List<int> ends;
}

/// 一个字面命中或拼音命中的字符区间，`end` 为开区间。
typedef PinyinSpan = ({int start, int end});

/// 一个待匹配字段及其匹配模式，供 [PinyinSearch.matchesFieldModes] 使用。
typedef PinyinField = ({String text, PinyinMatchMode mode});

/// 完成指纹预计算的字段，供 [PinyinSearch.matchesFieldDigests] 使用。
typedef PinyinFieldDigest = ({PinyinDigest digest, PinyinMatchMode mode});

class PinyinSearch {
  PinyinSearch._();

  static final RegExp _whitespace = RegExp(r'\s+');

  /// 正文类匹配的拼音门槛：少于这个字母数的查询不触发拼音，
  /// 否则 `l` 会命中所有拼音以 l 开头的字。
  static const int contentMinPinyinLength = 2;

  /// 构建 [text] 的匹配指纹；拼音部分惰性构建，字典查询留到真正需要时。
  ///
  /// 长文本会被反复查询，请用 [digestCached] 而不是每次按键重建。
  static PinyinDigest digest(String text) =>
      PinyinDigest._(text.toLowerCase(), text);

  /// 指纹缓存上限，同时缓存的消息条数。
  ///
  /// 一条中文指纹按每字几十字节计，几百条就是几 MB 量级，因此上限按“一次会话
  /// 里连续输入会反复命中的那批消息”定，而不是按整个消息库定：缓存装不下时
  /// 逐条淘汰最旧的，剩下的至少不会在每次查询里被整体丢弃。
  static const int digestCacheLimit = 256;

  static final Map<String, PinyinDigest> _digestCache = <String, PinyinDigest>{};

  /// [digest] 的带缓存版本，供长文本的重复查询使用。
  ///
  /// 缓存以原文为键，内容变了键就变，不需要失效逻辑；命中字面匹配的查询本来
  /// 就不会触发拼音构建，这里省下的是拼音查询在连续输入中重复付出的代价。
  static PinyinDigest digestCached(String text) {
    final cached = _digestCache[text];
    if (cached != null) return cached;
    final digest = PinyinDigest._(text.toLowerCase(), text);
    if (_digestCache.length >= digestCacheLimit) {
      _digestCache.remove(_digestCache.keys.first);
    }
    _digestCache[text] = digest;
    return digest;
  }

  /// [query] 按空白拆成多个词，所有词都必须命中。
  static bool matches(
    PinyinDigest haystack,
    String query, {
    required PinyinMatchMode mode,
  }) {
    final terms = splitTerms(query);
    if (terms.isEmpty) return false;
    for (final term in terms) {
      if (!_matchesTerm(haystack, term, mode)) return false;
    }
    return true;
  }

  /// 不缓存指纹的便捷入口，适合列表很短、按键频率不高的场景。
  static bool matchesText(
    String text,
    String query, {
    required PinyinMatchMode mode,
  }) =>
      matches(digest(text), query, mode: mode);

  /// 多字段查询：每个词只要命中任一字段即可，所有词必须分别命中。
  ///
  /// 逐字段匹配而不是先拼成一串——首字母串只能从某一串的开头匹配，拼接后
  /// 「薛宝钗」的 `xbc` 会被前面的名字挡掉。
  static bool matchesFields(
    List<String> fields,
    String query, {
    required PinyinMatchMode mode,
  }) =>
      matchesFieldModes([
        for (final field in fields) (text: field, mode: mode),
      ], query);

  /// [matchesFields] 的通用形式：每个字段可以有自己的匹配模式。
  ///
  /// 一个搜索框常常同时覆盖名称和正文（如「搜索目标、职业、情绪或备注」），
  /// 名称该宽松、正文该保守，因此模式按字段而不是按搜索框决定。
  static bool matchesFieldModes(List<PinyinField> fields, String query) =>
      matchesFieldDigests(digestFields(fields), query);

  /// 预计算字段指纹。长列表（如全库消息）应在数据变化时算一次并缓存，
  /// 而不是每次按键重建。
  ///
  /// 这里连同拼音部分一起算完：调用方是全库索引，它在后台分批重建并周期性
  /// 让出事件循环，而查询不让出。
  static List<PinyinFieldDigest> digestFields(List<PinyinField> fields) => [
        for (final field in fields)
          (digest: digest(field.text)..warmUp(), mode: field.mode),
      ];

  /// 与 [matchesFieldModes] 相同，但接收预计算好的指纹。
  static bool matchesFieldDigests(List<PinyinFieldDigest> fields, String query) {
    final terms = splitTerms(query);
    if (terms.isEmpty) return false;
    for (final term in terms) {
      var hit = false;
      for (final field in fields) {
        if (_matchesTerm(field.digest, term, field.mode)) {
          hit = true;
          break;
        }
      }
      if (!hit) return false;
    }
    return true;
  }

  /// 返回每个查询词命中的字符区间，按位置排序并合并重叠部分。
  /// 拼音命中时返回的是**对应汉字**的区间，供高亮使用。
  static List<PinyinSpan> highlightSpans(
    PinyinDigest haystack,
    String query, {
    required PinyinMatchMode mode,
  }) {
    final spans = <PinyinSpan>[];
    for (final term in splitTerms(query)) {
      final span = _spanFor(haystack, term, mode);
      if (span != null) spans.add(span);
    }
    return _merge(spans);
  }

  /// 查询按空白拆词并小写化，空词丢弃。
  static List<String> splitTerms(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    return trimmed
        .toLowerCase()
        .split(_whitespace)
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  /// 查询是否在任一字段中**字面**命中（不含拼音）。
  ///
  /// 用于把精确命中排到纯拼音命中之前：同样是搜 `lin`，字段里真的写着 `lin`
  /// 的那一条通常比拼音命中的「林黛玉」更贴用户想要的。
  static bool matchesLiterally(List<String> fields, String query) {
    final terms = splitTerms(query);
    if (terms.isEmpty) return false;
    for (final term in terms) {
      var hit = false;
      for (final field in fields) {
        if (field.toLowerCase().contains(term)) {
          hit = true;
          break;
        }
      }
      if (!hit) return false;
    }
    return true;
  }

  /// 稳定排序：把 [isExact] 为真的元素排到前面，其余保持原有相对顺序。
  ///
  /// Dart 的 `List.sort` 不稳定，所以显式拿原始下标做决胜键，避免同一批
  /// 结果在两次搜索之间自己换位置。
  static List<T> exactFirst<T>(List<T> items, bool Function(T item) isExact) {
    final indexed = [
      for (var index = 0; index < items.length; index++)
        (item: items[index], index: index, exact: isExact(items[index])),
    ];
    indexed.sort((a, b) {
      if (a.exact != b.exact) return a.exact ? -1 : 1;
      return a.index.compareTo(b.index);
    });
    return [for (final entry in indexed) entry.item];
  }

  static bool _matchesTerm(
    PinyinDigest haystack,
    String term,
    PinyinMatchMode mode,
  ) {
    if (haystack.lowerText.contains(term)) return true;
    if (term.isEmpty) return false;
    if (mode == PinyinMatchMode.content &&
        term.length < contentMinPinyinLength) {
      return false;
    }
    if (haystack.unitCount == 0) return false;
    return _syllableUnitSpan(haystack, term) != null ||
        _initialUnitSpan(haystack, term) != null;
  }

  static PinyinSpan? _spanFor(
    PinyinDigest haystack,
    String term,
    PinyinMatchMode mode,
  ) {
    if (term.isEmpty) return null;

    final literal = haystack.lowerText.indexOf(term);
    final literalSpan = literal < 0
        ? null
        : (start: literal, end: literal + term.length);

    if (mode == PinyinMatchMode.content &&
        term.length < contentMinPinyinLength) {
      return literalSpan;
    }
    if (haystack.unitCount == 0) return literalSpan;

    final pinyinSpan = _syllableUnitSpan(haystack, term) ??
        _initialUnitSpan(haystack, term);
    if (pinyinSpan == null) return literalSpan;
    if (literalSpan == null) return pinyinSpan;

    // 字面命中更精确，优先高亮字面区间。
    return literalSpan;
  }

  /// 字级全拼匹配：从某个字的音节边界开始，按字连续推进，
  /// 只有首段和末段允许是半个音节。这样 `lin`、`dai`、`lindai`、`daiyu`
  /// 都能命中「林黛玉」，而 `in`、`aiy` 这类跨越音节内部的串不会命中。
  static PinyinSpan? _syllableUnitSpan(PinyinDigest haystack, String term) {
    final units = haystack._ensurePinyin();
    // canMatch(i, j) 只依赖 (i, j)，跨起始位置共享，整体降为 O(单元数 × 词长)。
    final memo = <int, int?>{};
    for (var start = 0; start < units.readings.length; start++) {
      final end = _matchFrom(units, start, 0, term, memo);
      if (end != null) return _toCharSpan(units, start, end);
    }
    return null;
  }

  /// 返回以 [unitIndex] 为起点、消耗完 [term] 之后的结束单元下标（开区间）。
  static int? _matchFrom(
    _PinyinUnits units,
    int unitIndex,
    int consumed,
    String term,
    Map<int, int?> memo,
  ) {
    if (consumed == term.length) return unitIndex;
    if (unitIndex >= units.readings.length) return null;

    final key = unitIndex * (term.length + 1) + consumed;
    if (memo.containsKey(key)) return memo[key];

    int? result;
    for (final reading in units.readings[unitIndex]) {
      if (reading.isEmpty) continue;

      if (_matchesAt(term, consumed, reading)) {
        result = _matchFrom(
            units, unitIndex + 1, consumed + reading.length, term, memo);
        if (result != null) break;
      }

      // 末段允许只命读音的前几个字母。
      final remaining = term.length - consumed;
      if (remaining > 0 &&
          remaining < reading.length &&
          _matchesAt(reading, 0, term.substring(consumed))) {
        result = unitIndex + 1;
        break;
      }
    }

    memo[key] = result;
    return result;
  }

  /// 首字母串匹配：查询必须是每个字首字母按顺序拼成的前缀。
  /// 「林黛玉」→ `ldy`，`ld` 命中而 `dy` 不命中。
  static PinyinSpan? _initialUnitSpan(PinyinDigest haystack, String term) {
    final units = haystack._ensurePinyin();
    var consumed = 0;
    for (var index = 0;
        index < units.initials.length && consumed < term.length;
        index++) {
      if (units.initials[index].contains(term[consumed])) {
        consumed++;
      } else {
        break;
      }
    }
    if (consumed != term.length) return null;
    return _toCharSpan(units, 0, consumed);
  }

  static PinyinSpan _toCharSpan(
    _PinyinUnits units,
    int startUnit,
    int endUnit,
  ) =>
      (
        start: units.starts[startUnit],
        end: units.ends[endUnit - 1],
      );

  /// [pattern] 是否为 [source] 从 [from] 开始的子串（不分配新字符串）。
  static bool _matchesAt(String source, int from, String pattern) {
    if (from + pattern.length > source.length) return false;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (source.codeUnitAt(from + offset) != pattern.codeUnitAt(offset)) {
        return false;
      }
    }
    return true;
  }

  /// 返回该字符的读音候选；不参与拼音匹配的字符返回 null。
  static List<String>? _readingsOf(String char) {
    final code = char.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isLetter =
        (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
    if (isDigit || isLetter) return [char.toLowerCase()];
    if (!ChineseHelper.isChinese(char)) return null;

    // 繁体与异体字先归一化到简体，保证「張三」能用 zhang 搜到。
    final simplified = ChineseHelper.convertToSimplifiedChinese(char);
    final source = simplified.length == 1 ? simplified : char;
    final readings =
        PinyinHelper.convertToPinyinArray(source, PinyinFormat.WITHOUT_TONE);
    if (readings.isEmpty) return null;
    return readings
        .where((value) => value.isNotEmpty)
        .map((value) => value.toLowerCase())
        .toList(growable: false);
  }

  static List<String> _initialsOf(List<String> readings) {
    final seen = <String>{};
    for (final reading in readings) {
      if (reading.isNotEmpty) seen.add(reading[0]);
    }
    return seen.toList(growable: false);
  }

  static int _charLengthAt(String text, int index) {
    final code = text.codeUnitAt(index);
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) {
      final next = text.codeUnitAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) return 2;
    }
    return 1;
  }

  static List<PinyinSpan> _merge(List<PinyinSpan> spans) {
    if (spans.length < 2) return spans;
    final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <PinyinSpan>[sorted.first];
    for (final span in sorted.skip(1)) {
      final last = merged.last;
      if (span.start <= last.end) {
        if (span.end > last.end) {
          merged[merged.length - 1] = (start: last.start, end: span.end);
        }
      } else {
        merged.add(span);
      }
    }
    return merged;
  }
}
