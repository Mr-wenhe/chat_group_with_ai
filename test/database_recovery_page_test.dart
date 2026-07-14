import 'package:chat_group/core/database/database_recovery_page.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('database recovery page asks user to back up before recovery',
      (tester) async {
    final error = DatabaseOpenException(
      boxName: 'messages',
      dataDirPath: '/tmp/chat_group/data',
      cause: StateError('simulated open failure'),
      stackTrace: StackTrace.empty,
    );

    await tester.pumpWidget(DatabaseRecoveryApp(
      error: error,
      dataDirPath: error.dataDirPath,
    ));

    expect(find.text('数据库暂时无法打开'), findsOneWidget);
    expect(find.text('请先备份数据库，再处理恢复或文件修复。'), findsOneWidget);
    expect(find.text('/tmp/chat_group/data'), findsOneWidget);
    expect(find.textContaining('没有删除、清空或重建'), findsOneWidget);
  });
}
