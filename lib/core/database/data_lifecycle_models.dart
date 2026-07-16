enum CharacterDeletionPolicy { keepMessageHistory, deleteRelatedData }

enum DataClearScope { chatContent, userContent, factoryReset }

class DeletionPlan {
  final String title;
  final Map<String, int> counts;

  const DeletionPlan({required this.title, required this.counts});

  int count(String key) => counts[key] ?? 0;
}

class DataLifecycleResult {
  final List<String> incompleteItems;
  final int reclaimedFiles;
  final int reclaimedBytes;

  const DataLifecycleResult({
    this.incompleteItems = const [],
    this.reclaimedFiles = 0,
    this.reclaimedBytes = 0,
  });

  bool get isComplete => incompleteItems.isEmpty;
}

class MediaUsage {
  final int totalFiles;
  final int totalBytes;
  final int orphanFiles;
  final int orphanBytes;
  final List<String> orphanPaths;

  const MediaUsage({
    required this.totalFiles,
    required this.totalBytes,
    required this.orphanFiles,
    required this.orphanBytes,
    this.orphanPaths = const [],
  });

  static const empty = MediaUsage(
    totalFiles: 0,
    totalBytes: 0,
    orphanFiles: 0,
    orphanBytes: 0,
  );
}
