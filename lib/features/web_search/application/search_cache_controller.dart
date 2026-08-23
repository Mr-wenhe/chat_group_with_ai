import '../data/search_settings_store.dart';
import 'search_turn_cache.dart';

/// Coordinates the settings action across persisted and active turn caches.
class SearchCacheController {
  const SearchCacheController._();

  static Future<void> clear(SearchProviderConfigStore store) async {
    SearchTurnCache.clearAll();
    await store.clearSearchCache();
  }
}
