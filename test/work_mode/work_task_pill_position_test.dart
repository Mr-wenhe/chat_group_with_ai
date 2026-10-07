import 'dart:io';
import 'dart:ui';

import 'package:chat_group/features/work_mode/presentation/work_task_pill_position.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../helpers/lifecycle_hive.dart';

void main() {
  group('clampWorkTaskPillPosition', () {
    const viewport = Size(800, 600);
    const pill = Size(80, 34);

    test('keeps a position that is already inside the window', () {
      expect(
        clampWorkTaskPillPosition(
          position: const Offset(200, 150),
          pillSize: pill,
          viewport: viewport,
        ),
        const Offset(200, 150),
      );
    });

    test('pulls a position back from the right and bottom edges', () {
      // 拖过头时胶囊必须整体留在窗口内：留着半个在屏幕外就再也点不到了。
      expect(
        clampWorkTaskPillPosition(
          position: const Offset(5000, 5000),
          pillSize: pill,
          viewport: viewport,
        ),
        Offset(viewport.width - pill.width - 8, viewport.height - pill.height - 8),
      );
    });

    test('pulls a position back from the left and top edges', () {
      expect(
        clampWorkTaskPillPosition(
          position: const Offset(-500, -500),
          pillSize: pill,
          viewport: viewport,
        ),
        const Offset(8, 8),
      );
    });

    test('falls back to the margin when the window is smaller than the pill',
        () {
      expect(
        clampWorkTaskPillPosition(
          position: const Offset(300, 300),
          pillSize: const Size(200, 200),
          viewport: const Size(100, 100),
        ),
        const Offset(8, 8),
      );
    });
  });

  group('WorkTaskPillPosition', () {
    late Directory hiveDirectory;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
    });

    tearDownAll(() async {
      await closeLifecycleHive(hiveDirectory).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    setUp(() async {
      await Hive.box<dynamic>('app_settings')
          .delete(WorkTaskPillPosition.storageKey);
    });

    test('reads back the position it wrote', () async {
      final box = Hive.box<dynamic>('app_settings');
      await WorkTaskPillPosition.write(box, const Offset(120.5, 240.25));

      expect(
        WorkTaskPillPosition.read(box),
        const Offset(120.5, 240.25),
      );
    });

    test('reads a missing or damaged value as "never dragged"', () async {
      final box = Hive.box<dynamic>('app_settings');
      expect(WorkTaskPillPosition.read(box), isNull);

      for (final damaged in <Object>['', 'abc', '10', '10,20,30', '10,x']) {
        await box.put(WorkTaskPillPosition.storageKey, damaged);
        expect(
          WorkTaskPillPosition.read(box),
          isNull,
          reason: '损坏值 $damaged 必须当作没有拖过，而不是抛异常',
        );
      }
    });
  });
}
