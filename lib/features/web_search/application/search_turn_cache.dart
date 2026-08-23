import 'dart:async';

import '../models/search_models.dart';

typedef SearchCacheLoader<T> = Future<T> Function();
typedef SearchCachePredicate<T> = bool Function(T value);
typedef SearchCacheMarker<T> = T Function(T value);

/// A short-lived cache owned by one search coordinator/room.
///
/// The maps are deliberately instance fields. A room can therefore share one
/// request among its AI replies without leaking results or futures into a
/// different test, conversation, or room.
class SearchTurnCache {
  static int _globalGeneration = 0;

  final DateTime Function() _clock;
  final Map<SearchTurnCacheKey, _CompletedCacheValue> _completed = {};
  final Map<SearchTurnCacheKey, Future<Object?>> _inFlight = {};
  int _generation;

  SearchTurnCache({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        _generation = _globalGeneration;

  /// Invalidates completed entries in every active coordinator on the next
  /// cache access. In-flight requests are intentionally allowed to finish.
  static void clearAll() => _globalGeneration++;

  int get completedCount {
    _syncGeneration();
    return _completed.length;
  }

  int get inFlightCount {
    _syncGeneration();
    return _inFlight.length;
  }

  /// Returns a cached value, joins an existing load, or starts one load.
  ///
  /// Failed values are not retained when [shouldCache] returns false. A
  /// thrown loader error is never retained, which is important for recovery
  /// after a transient Provider failure.
  Future<T> getOrLoad<T>({
    required SearchTurnCacheKey key,
    required Duration ttl,
    required SearchCacheLoader<T> loader,
    bool forceRefresh = false,
    SearchCachePredicate<T>? shouldCache,
    SearchCacheMarker<T>? markFromCache,
  }) {
    _syncGeneration();
    final running = _inFlight[key];
    if (running != null) return running as Future<T>;

    if (!forceRefresh && ttl > Duration.zero) {
      final cached = _completed[key];
      if (cached != null && _isFresh(cached, ttl)) {
        final value = cached.value as T;
        final marker = markFromCache ?? _identity<T>;
        return Future<T>.value(marker(value));
      }
      if (cached != null) _completed.remove(key);
    }

    final completer = Completer<T>();
    _inFlight[key] = completer.future;
    _load(
      key: key,
      ttl: ttl,
      loader: loader,
      completer: completer,
      shouldCache: shouldCache,
    );
    return completer.future;
  }

  void invalidate(SearchTurnCacheKey key) {
    _syncGeneration();
    _completed.remove(key);
  }

  /// Clears completed entries but lets an active request finish normally.
  void clearCompleted() {
    _syncGeneration();
    _completed.clear();
  }

  /// Clears completed entries and forgets references to active futures.
  ///
  /// The active operation is not cancelled; callers that need cancellation
  /// should pass a CancelToken to the Provider. Forgetting the reference is
  /// useful when a room is disposed and no later caller should join it.
  void clear() {
    _syncGeneration();
    _completed.clear();
    _inFlight.clear();
  }

  void _syncGeneration() {
    if (_generation == _globalGeneration) return;
    _completed.clear();
    _generation = _globalGeneration;
  }

  bool _isFresh(_CompletedCacheValue value, Duration ttl) {
    final age = _clock().difference(value.storedAt);
    return age >= Duration.zero && age < ttl;
  }

  Future<void> _load<T>({
    required SearchTurnCacheKey key,
    required Duration ttl,
    required SearchCacheLoader<T> loader,
    required Completer<T> completer,
    required SearchCachePredicate<T>? shouldCache,
  }) async {
    try {
      final value = await loader();
      if (ttl > Duration.zero && (shouldCache?.call(value) ?? true)) {
        _completed[key] = _CompletedCacheValue(
          value: value,
          storedAt: _clock(),
        );
      }
      completer.complete(value);
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_inFlight[key], completer.future)) {
        _inFlight.remove(key);
      }
    }
  }

  T _identity<T>(T value) => value;
}

class SearchTurnCacheKey {
  final String sourceMessageId;
  final String turnId;
  final String normalizedQuery;
  final SearchCategory category;
  final SearchFreshness freshness;
  final String locale;
  final String? country;
  final int maxResults;
  final bool safeSearch;
  final String provider;

  SearchTurnCacheKey({
    required String sourceMessageId,
    required String turnId,
    required String normalizedQuery,
    this.category = SearchCategory.general,
    required this.freshness,
    String locale = 'zh-CN',
    String? country,
    this.maxResults = searchDefaultMaxResults,
    this.safeSearch = true,
    required String provider,
  })  : sourceMessageId = sourceMessageId.trim(),
        turnId = turnId.trim(),
        normalizedQuery = _normalizeQuery(normalizedQuery),
        locale = _normalizeLocale(locale),
        country = _normalizeCountry(country),
        provider = provider.trim().toLowerCase();

  factory SearchTurnCacheKey.fromRequest({
    required SearchRequest request,
    required String provider,
    String? sourceMessageId,
  }) {
    return SearchTurnCacheKey(
      sourceMessageId: sourceMessageId ?? request.sourceMessageId,
      turnId: request.turnId,
      normalizedQuery: request.query,
      category: request.category,
      freshness: request.freshness,
      locale: request.locale,
      country: request.country,
      maxResults: request.maxResults,
      safeSearch: request.safeSearch,
      provider: provider,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SearchTurnCacheKey &&
        other.sourceMessageId == sourceMessageId &&
        other.turnId == turnId &&
        other.normalizedQuery == normalizedQuery &&
        other.category == category &&
        other.freshness == freshness &&
        other.locale == locale &&
        other.country == country &&
        other.maxResults == maxResults &&
        other.safeSearch == safeSearch &&
        other.provider == provider;
  }

  @override
  int get hashCode => Object.hash(
        sourceMessageId,
        turnId,
        normalizedQuery,
        category,
        freshness,
        locale,
        country,
        maxResults,
        safeSearch,
        provider,
      );

  @override
  String toString() =>
      '$sourceMessageId|$turnId|$normalizedQuery|${category.name}|'
      '${freshness.name}|$locale|$country|$maxResults|$safeSearch|$provider';
}

class _CompletedCacheValue {
  final Object? value;
  final DateTime storedAt;

  const _CompletedCacheValue({required this.value, required this.storedAt});
}

String _normalizeQuery(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

String _normalizeLocale(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? 'zh-cn' : normalized.toLowerCase();
}

String? _normalizeCountry(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty
      ? null
      : normalized.toUpperCase();
}
