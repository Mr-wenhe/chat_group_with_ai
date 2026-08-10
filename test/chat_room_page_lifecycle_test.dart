import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUpAll(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(
        id: 'g1',
        name: '测试群',
        theme: '测试',
        aiCharacterIds: const [],
      ),
    );
  });

  tearDownAll(() async {
    await closeLifecycleHive(directory, db);
  });

  testWidgets('reactivated chat room accepts UI state updates', (tester) async {
    addTearDown(() async {
      // Dispose the room before tearDownAll closes the shared Hive fixture.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    final hostKey = GlobalKey<_RelocatingHostState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: _RelocatingHost(
              key: hostKey,
              roomKey: GlobalKey(),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TextField), findsOneWidget);

    hostKey.currentState!.moveRoom();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '重新激活');
    await tester.pump();

    final send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.send_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNotNull);
  });
}

class _RelocatingHost extends StatefulWidget {
  final GlobalKey roomKey;

  const _RelocatingHost({
    super.key,
    required this.roomKey,
  });

  @override
  State<_RelocatingHost> createState() => _RelocatingHostState();
}

class _RelocatingHostState extends State<_RelocatingHost> {
  bool _moved = false;

  void moveRoom() => setState(() => _moved = true);

  Widget _room() => ChatRoomPage(
        key: widget.roomKey,
        groupId: 'g1',
      );

  @override
  Widget build(BuildContext context) {
    return _moved
        ? Padding(padding: const EdgeInsets.all(1), child: _room())
        : Align(alignment: Alignment.topLeft, child: _room());
  }
}
