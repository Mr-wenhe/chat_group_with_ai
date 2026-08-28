import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_service.dart';

/// The single app-scoped database dependency.
///
/// Kept outside the feature provider barrel so work-mode providers can depend
/// on storage without importing a barrel that re-exports those same providers.
final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService();
});
