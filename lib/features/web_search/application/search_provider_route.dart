import '../models/search_provider_config.dart';
import '../models/search_models.dart';
import '../providers/search_provider.dart';

/// Runtime binding between a normalized Provider interface and its already
/// resolved credential. Credential lookup belongs to the settings layer; the
/// coordinator never reads or persists secrets.
class SearchProviderRoute {
  final SearchProvider provider;
  final String? credential;
  final String id;
  final bool enabled;
  final bool isPrimary;
  final bool isFallback;

  /// Native model search returns full web results even when its independent
  /// fallback is DuckDuckGo. It must not inherit the fallback's
  /// knowledge-only routing restriction.
  final bool isNative;
  final int priority;
  final String? displayName;

  const SearchProviderRoute({
    required this.provider,
    this.credential,
    this.id = '',
    this.enabled = true,
    this.isPrimary = false,
    this.isFallback = false,
    this.isNative = false,
    this.priority = 0,
    this.displayName,
  });

  factory SearchProviderRoute.fromConfig({
    required SearchProviderConfig config,
    required SearchProvider provider,
    String? credential,
    int priority = 0,
  }) {
    return SearchProviderRoute(
      provider: provider,
      credential: credential,
      id: config.id,
      enabled: config.enabled,
      isPrimary: config.isDefault,
      priority: priority,
      displayName: config.name,
    );
  }

  SearchProviderKind get kind => provider.kind;

  String get providerName =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : kind.name;

  /// Stable cache identity without exposing the resolved credential.
  String get cacheKey {
    final normalizedId = id.trim();
    return normalizedId.isEmpty ? kind.name : '${kind.name}:$normalizedId';
  }
}

typedef SearchProviderBinding = SearchProviderRoute;
