import '../models/search_models.dart';
import '../security/search_query_sanitizer.dart';

/// The origin of the message that could cause a search.
enum SearchMessageOrigin {
  user,
  ai,
  proactive,
  autoChat,
  regeneration,
}

class SearchIntentDecision {
  final bool shouldSearch;
  final bool explicitlyRequested;
  final SearchCategory category;
  final SearchFreshness freshness;
  final String reasonCode;
  final bool mayContainSensitiveData;
  final List<String> localQueryCandidates;
  final SearchMessageOrigin origin;

  const SearchIntentDecision({
    required this.shouldSearch,
    required this.explicitlyRequested,
    required this.category,
    required this.freshness,
    required this.reasonCode,
    required this.mayContainSensitiveData,
    required this.localQueryCandidates,
    this.origin = SearchMessageOrigin.user,
  });
}

/// Local-only, deterministic search intent detection.
class SearchIntentDetector {
  final SearchQuerySanitizer sanitizer;

  const SearchIntentDetector({this.sanitizer = const SearchQuerySanitizer()});

  SearchIntentDecision detect(
    String? message, {
    SearchMessageOrigin origin = SearchMessageOrigin.user,
    DateTime? now,
  }) {
    final value = message?.trim() ?? '';
    final sanitized = sanitizer.sanitize(value);
    final lower = value.toLowerCase();
    final sensitive = sanitized.containsSensitiveData;

    if (value.isEmpty) {
      return _decision(
        origin: origin,
        reasonCode: 'empty',
        category: SearchCategory.general,
        freshness: SearchFreshness.any,
        sensitive: false,
      );
    }

    // A user can explicitly request search, but generated/proactive content
    // cannot grant permission to send a third-party request by itself.
    if (origin != SearchMessageOrigin.user) {
      return _decision(
        origin: origin,
        reasonCode: origin == SearchMessageOrigin.regeneration
            ? 'regeneration_reuse_snapshot'
            : '${origin.name}_suppressed',
        category: _categoryFor(value, lower),
        freshness: _freshnessFor(value, lower, now),
        sensitive: sensitive,
      );
    }

    final explicitlyRequested = _containsAny(value, lower, _explicitTerms);
    final category = _categoryFor(value, lower);
    final freshness = _freshnessFor(value, lower, now);
    final timeSensitive = _containsAny(value, lower, _timeSensitiveTerms);
    final shouldSearch = explicitlyRequested || timeSensitive;
    final reasonCode = sensitive
        ? 'unsafe_query'
        : explicitlyRequested
            ? 'explicit_request'
            : timeSensitive
                ? _reasonFor(value, lower, category)
                : 'stable_knowledge';

    final candidates = <String>[
      if (sanitized.text.isNotEmpty) sanitized.text,
      if (sanitized.text.isNotEmpty)
        sanitizer.deterministicFallback(sanitized.text),
    ].where((candidate) => candidate.trim().isNotEmpty).toSet().toList();

    return SearchIntentDecision(
      shouldSearch: shouldSearch,
      explicitlyRequested: explicitlyRequested,
      category: category,
      freshness: freshness,
      reasonCode: reasonCode,
      mayContainSensitiveData: sensitive,
      localQueryCandidates: List.unmodifiable(candidates),
      origin: origin,
    );
  }

  bool shouldSearch(
    String? message, {
    SearchMessageOrigin origin = SearchMessageOrigin.user,
    DateTime? now,
  }) =>
      detect(message, origin: origin, now: now).shouldSearch;

  SearchIntentDecision _decision({
    required SearchMessageOrigin origin,
    required String reasonCode,
    required SearchCategory category,
    required SearchFreshness freshness,
    required bool sensitive,
  }) {
    return SearchIntentDecision(
      shouldSearch: false,
      explicitlyRequested: false,
      category: category,
      freshness: freshness,
      reasonCode: reasonCode,
      mayContainSensitiveData: sensitive,
      localQueryCandidates: const [],
      origin: origin,
    );
  }

  static SearchCategory _categoryFor(String value, String lower) {
    if (_containsAny(value, lower, const ['天气', '气温', 'weather', 'forecast'])) {
      return SearchCategory.weather;
    }
    if (_containsAny(
      value,
      lower,
      const ['价格', '股价', '汇率', '金融', 'price', 'stock', 'exchange rate'],
    )) {
      return SearchCategory.finance;
    }
    if (_containsAny(
      value,
      lower,
      const ['新闻', 'headline', 'breaking news'],
    )) {
      return SearchCategory.news;
    }
    if (_containsAny(
      value,
      lower,
      const [
        '政策',
        '法规',
        '法律',
        'regulation',
        'policy',
        'law',
      ],
    )) {
      return SearchCategory.policy;
    }
    if (_containsAny(
      value,
      lower,
      const [
        'flutter',
        'dart',
        '版本',
        'release',
        'changelog',
        'documentation',
        'sdk',
      ],
    )) {
      return SearchCategory.software;
    }
    if (_containsAny(value, lower, const ['论文', '学术', 'paper', 'academic'])) {
      return SearchCategory.academic;
    }
    if (_containsAny(value, lower, const ['附近', '本地', 'near me', 'local'])) {
      return SearchCategory.local;
    }
    return SearchCategory.general;
  }

  static SearchFreshness _freshnessFor(
    String value,
    String lower,
    DateTime? now,
  ) {
    // [now] is accepted so callers can make time-sensitive tests deterministic;
    // these relative terms do not need to send the clock value to a Provider.
    if (_containsAny(
      value,
      lower,
      const ['今天', '今日', '现在', 'today', 'now'],
    )) {
      return SearchFreshness.day;
    }
    if (_containsAny(value, lower, const ['本周', '这周', 'this week'])) {
      return SearchFreshness.week;
    }
    if (_containsAny(value, lower, const ['本月', '这个月', 'this month'])) {
      return SearchFreshness.month;
    }
    if (_containsAny(value, lower, const ['今年', 'this year'])) {
      return SearchFreshness.year;
    }
    if (_containsAny(
        value, lower, const ['最新', '当前', '最近', 'latest', 'current'])) {
      return SearchFreshness.month;
    }
    return SearchFreshness.any;
  }

  static String _reasonFor(
    String value,
    String lower,
    SearchCategory category,
  ) {
    if (_containsAny(
      value,
      lower,
      const ['职位', '现任', 'ceo', 'president', 'who is the current'],
    )) {
      return 'current_person_or_role';
    }
    return _reasonForCategory(category);
  }

  static String _reasonForCategory(SearchCategory category) =>
      switch (category) {
        SearchCategory.news => 'news',
        SearchCategory.weather => 'weather',
        SearchCategory.finance => 'price_or_market',
        SearchCategory.policy => 'law_or_policy',
        SearchCategory.software => 'software_release',
        _ => 'time_sensitive',
      };

  static bool _containsAny(
    String original,
    String lower,
    Iterable<String> terms,
  ) {
    for (final term in terms) {
      final normalized = term.toLowerCase();
      if (normalized.contains(RegExp(r'[a-z]'))) {
        final pattern = RegExp(
          r'(?<![a-z0-9])' + RegExp.escape(normalized) + r'(?![a-z0-9])',
          caseSensitive: false,
        );
        if (pattern.hasMatch(lower)) return true;
      } else if (original.contains(term)) {
        return true;
      }
    }
    return false;
  }

  static const _explicitTerms = [
    '联网',
    '网络搜索',
    '搜索',
    '查一下',
    '查查',
    '搜一下',
    'search',
    'web search',
    'search the web',
    'look up',
  ];

  static const _timeSensitiveTerms = [
    '当前',
    '最新',
    '最近',
    '今天',
    '今日',
    '现在',
    '几点',
    '日期',
    '时间',
    '新闻',
    '价格',
    '股价',
    '汇率',
    '天气',
    '政策',
    '法规',
    '法律',
    '版本',
    '职位',
    '现任',
    '发布',
    'latest',
    'current',
    'today',
    'now',
    'news',
    'price',
    'weather',
    'policy',
    'regulation',
    'version',
    'release',
    'job',
    'ceo',
    'president',
  ];
}
