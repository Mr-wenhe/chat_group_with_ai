import 'search_models.dart';

/// User-controlled defaults applied when a user turn is prepared.
///
/// These values are settings metadata only; credentials remain in the
/// search-specific secure credential repository.
class SearchRuntimeSettings {
  static const defaultLocale = 'zh-CN';
  static const defaultMaxResults = searchDefaultMaxResults;
  static const defaultSafeSearch = true;

  final String locale;
  final String? country;
  final int maxResults;
  final bool safeSearch;

  const SearchRuntimeSettings({
    this.locale = defaultLocale,
    this.country,
    this.maxResults = defaultMaxResults,
    this.safeSearch = defaultSafeSearch,
  });

  factory SearchRuntimeSettings.fromMap(Object? raw) {
    if (raw is! Map) return const SearchRuntimeSettings();
    return SearchRuntimeSettings(
      locale: _normalizeLocale(raw['locale']),
      country: _normalizeCountry(raw['country']),
      maxResults: _normalizeMaxResults(raw['maxResults']),
      safeSearch: raw['safeSearch'] != false,
    );
  }

  Map<String, dynamic> toMap() => {
        'locale': locale,
        'country': country,
        'maxResults': maxResults,
        'safeSearch': safeSearch,
      };

  SearchRuntimeSettings copyWith({
    String? locale,
    String? country,
    bool clearCountry = false,
    int? maxResults,
    bool? safeSearch,
  }) {
    return SearchRuntimeSettings(
      locale: _normalizeLocale(locale ?? this.locale),
      country: clearCountry ? null : _normalizeCountry(country ?? this.country),
      maxResults: _normalizeMaxResults(maxResults ?? this.maxResults),
      safeSearch: safeSearch ?? this.safeSearch,
    );
  }

  static String _normalizeLocale(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? defaultLocale : normalized;
  }

  static String? _normalizeCountry(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized.toUpperCase();
  }

  static int _normalizeMaxResults(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return (parsed ?? defaultMaxResults).clamp(1, searchMaxResultsLimit);
  }
}
