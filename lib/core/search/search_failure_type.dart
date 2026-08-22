/// Stable, presentation-safe categories shared by search adapters and audit.
///
/// This type lives in core so the search domain does not depend on the
/// governance persistence model that records its failures.
enum SearchFailureType {
  offline,
  connection,
  permissionMissing,
  dns,
  tls,
  connectionTimeout,
  receiveTimeout,
  cancelled,
  unauthorized,
  forbidden,
  quotaExceeded,
  rateLimited,
  providerUnavailable,
  invalidResponse,
  invalidConfiguration,
  unsafeQuery,
  noResults,
  unknown,
}
