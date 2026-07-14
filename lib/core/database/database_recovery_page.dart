import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'database_service.dart';

/// Standalone screen shown when Hive cannot be opened.
///
/// It intentionally does not depend on any database/provider state, so it can
/// render even when initialization stopped halfway through.
class DatabaseRecoveryApp extends StatelessWidget {
  final Object error;
  final String? dataDirPath;

  const DatabaseRecoveryApp({
    super.key,
    required this.error,
    this.dataDirPath,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: DatabaseRecoveryPage(
        error: error,
        dataDirPath: dataDirPath,
      ),
    );
  }
}

class DatabaseRecoveryPage extends StatelessWidget {
  final Object error;
  final String? dataDirPath;

  const DatabaseRecoveryPage({
    super.key,
    required this.error,
    this.dataDirPath,
  });

  String? get boxName => error is DatabaseOpenException
      ? (error as DatabaseOpenException).boxName
      : null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('数据库保护模式')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lock_clock_outlined,
                      size: 48,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '数据库暂时无法打开',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '为保护你的数据，应用没有删除、清空或重建任何数据库文件。',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '请先备份数据库，再处理恢复或文件修复。',
                      style: TextStyle(
                        color: colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '请退出应用后，复制整个 data 数据目录及其中的 .hive 文件，保留原始副本。完成备份后，再尝试重新启动应用或联系维护人员处理。',
                    ),
                    if (boxName != null) ...[
                      const SizedBox(height: 16),
                      Text('无法打开的数据库：$boxName'),
                    ],
                    if (dataDirPath != null && dataDirPath!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text('数据目录：'),
                      const SizedBox(height: 4),
                      SelectableText(dataDirPath!),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => _copyPath(context),
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        label: const Text('复制数据目录路径'),
                      ),
                    ],
                    const SizedBox(height: 16),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('查看错误详情'),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(error.toString()),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyPath(BuildContext context) async {
    final path = dataDirPath;
    if (path == null || path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('数据目录路径已复制')),
      );
    }
  }
}
