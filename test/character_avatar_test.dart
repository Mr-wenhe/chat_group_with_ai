import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

AICharacter _character({
  String ipImageRelPath = '',
  bool avatarFromIpImage = false,
}) =>
    AICharacter(
      id: 'c1',
      name: '小美',
      avatar: '美',
      age: 25,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'custom',
      ipImageRelPath: ipImageRelPath,
      avatarFromIpImage: avatarFromIpImage,
    );

UserProfile _profile({
  String ipImageRelPath = '',
  bool avatarFromIpImage = false,
}) =>
    UserProfile(
      displayName: '小明',
      preferredAddress: '',
      avatar: '',
      bio: '',
      ipImageRelPath: ipImageRelPath,
      avatarFromIpImage: avatarFromIpImage,
    );

void main() {
  group('CharacterAvatar 渲染回落', () {
    testWidgets('无图时回落文本', (tester) async {
      await tester.pumpWidget(_wrap(const CharacterAvatar(
        fallbackText: '美',
        size: 48,
        textStyle: TextStyle(fontSize: 20),
      )));

      expect(find.text('美'), findsOneWidget);
    });

    testWidgets('有图时出图且不再叠文本', (tester) async {
      // 注入 MemoryImage 而非 FileImage：`testWidgets` 的 FakeAsync 区里
      // 真实文件解码永不完成，会让整个用例 hang 死。
      await tester.pumpWidget(_wrap(CharacterAvatar(
        fallbackText: '美',
        size: 48,
        image: MemoryImage(Uint8List.fromList(_kTransparentPng)),
      )));

      expect(find.text('美'), findsNothing);
      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.image, isNotNull);
    });

    testWidgets('fallbackText 为空时显示 child 兜底', (tester) async {
      await tester.pumpWidget(_wrap(const CharacterAvatar(
        fallbackText: '',
        size: 32,
        child: Icon(Icons.groups_2_outlined),
      )));

      expect(find.byIcon(Icons.groups_2_outlined), findsOneWidget);
    });

    testWidgets('overlay 铺满头像叠层', (tester) async {
      await tester.pumpWidget(_wrap(const CharacterAvatar(
        fallbackText: '美',
        size: 48,
        overlay: DecoratedBox(
          decoration:
              BoxDecoration(shape: BoxShape.circle, color: Colors.black26),
          child: Icon(Icons.pause_rounded, size: 16),
        ),
      )));

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.text('美'), findsOneWidget);
    });

    testWidgets('矩形头像带圆角时按 borderRadius 裁切', (tester) async {
      await tester.pumpWidget(_wrap(const CharacterAvatar(
        fallbackText: 'A',
        size: 40,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.all(Radius.circular(4)),
        background: Colors.blue,
      )));

      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.rectangle);
      expect(
        decoration.borderRadius,
        const BorderRadius.all(Radius.circular(4)),
      );
    });

    testWidgets('onTap 包一层手势', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_wrap(CharacterAvatar(
        fallbackText: '美',
        size: 48,
        onTap: () => tapped++,
      )));

      await tester.tap(find.byType(CharacterAvatar));
      expect(tapped, 1);
    });
  });

  group('characterAvatarPath / characterAvatarImage 取值门控', () {
    late Directory hiveDirectory;
    late DatabaseService db;

    setUp(() async {
      hiveDirectory = await openLifecycleHive();
      db = DatabaseService();
    });

    tearDown(() async {
      await closeLifecycleHive(hiveDirectory, db);
    });

    test('角色为 null / 未启用 IP 图时强制返回 null', () {
      expect(db.characterAvatarPath(null), isNull);
      expect(db.characterAvatarImage(null), isNull);
      // 未点「设为头像」：即使已有 IP 图也不进头像通道。
      expect(
        db.characterAvatarPath(_character(ipImageRelPath: 'a/b.png')),
        isNull,
      );
      expect(
        db.characterAvatarImage(_character(ipImageRelPath: 'a/b.png')),
        isNull,
      );
    });

    test('启用后按相对路径解析到真实文件', () async {
      // 用自定义 ai-processing 根目录，同时覆盖「用户改了工作目录」场景；
      // 也避开 `aiProcessingDir` 对 `DatabaseService.init()` 的依赖。
      final root = await Directory.systemTemp.createTemp('ip_image_root');
      addTearDown(() => root.deleteSync(recursive: true));
      await db.saveAiProcessingDirPath(root.path);

      final dir = Directory('${root.path}/path_gate_test')
        ..createSync(recursive: true);
      File('${dir.path}/ip.png').writeAsBytesSync(_kTransparentPng);

      final character = _character(
        ipImageRelPath: 'path_gate_test/ip.png',
        avatarFromIpImage: true,
      );
      final resolved = db.characterAvatarPath(character);

      expect(resolved, isNotNull);
      expect(File(resolved!).existsSync(), isTrue);
      expect(db.characterAvatarImage(character), isNotNull);
    });

    test('文件缺失时静默回落 null（跨设备还原本场景）', () {
      expect(
        db.characterAvatarImage(_character(
          ipImageRelPath: 'definitely_missing_dir/gone.png',
          avatarFromIpImage: true,
        )),
        isNull,
      );
    });

    test('越界相对路径一律拒绝', () {
      expect(
        db.characterAvatarPath(_character(
          ipImageRelPath: '../escape.png',
          avatarFromIpImage: true,
        )),
        isNull,
      );
      expect(
        db.characterAvatarPath(_character(
          ipImageRelPath: 'C:/windows/system32/config.png',
          avatarFromIpImage: true,
        )),
        isNull,
      );
    });
  });

  group('userAvatarPath / userAvatarImage 取值门控', () {
    late Directory hiveDirectory;
    late DatabaseService db;

    setUp(() async {
      hiveDirectory = await openLifecycleHive();
      db = DatabaseService();
    });

    tearDown(() async {
      await closeLifecycleHive(hiveDirectory, db);
    });

    test('资料为空 / 未启用 IP 图时强制返回 null', () {
      expect(db.userAvatarPath(null), isNull);
      expect(db.userAvatarImage(null), isNull);
      // 未点「设为头像」：即使已有 IP 图也不进头像通道。
      expect(db.userAvatarPath(_profile(ipImageRelPath: 'a/b.png')), isNull);
      expect(db.userAvatarImage(_profile(ipImageRelPath: 'a/b.png')), isNull);
    });

    test('启用后按相对路径解析到真实文件', () async {
      final root = await Directory.systemTemp.createTemp('user_avatar_root');
      addTearDown(() => root.deleteSync(recursive: true));
      await db.saveAiProcessingDirPath(root.path);

      final dir = Directory('${root.path}/me')..createSync(recursive: true);
      File('${dir.path}/ip.png').writeAsBytesSync(_kTransparentPng);

      final profile = _profile(
        ipImageRelPath: 'me/ip.png',
        avatarFromIpImage: true,
      );
      final resolved = db.userAvatarPath(profile);

      expect(resolved, isNotNull);
      expect(File(resolved!).existsSync(), isTrue);
      expect(db.userAvatarImage(profile), isNotNull);
    });

    test('文件缺失时静默回落 null（跨设备还原本场景）', () {
      expect(
        db.userAvatarImage(_profile(
          ipImageRelPath: 'definitely_missing_dir/gone.png',
          avatarFromIpImage: true,
        )),
        isNull,
      );
    });
  });
}

/// 1×1 透明 PNG。
const List<int> _kTransparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
