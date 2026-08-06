import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/features/settings/user_profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late DatabaseService db;

  setUpAll(() async {
    await openLifecycleHive();
    db = DatabaseService();
  });

  setUp(() async {
    await db.userProfileBox.delete('me');
  });

  tearDownAll(() async {
    db.dispose();
    await Hive.close();
  });

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  group('UserProfilePage rendering', () {
    testWidgets('renders with default display name and privacy notice',
        (tester) async {
      await tester.pumpWidget(app(const UserProfilePage()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('我'), findsWidgets);
      expect(find.textContaining('第三方 LLM 服务'), findsOneWidget);
      expect(find.text('我的资料'), findsOneWidget);
    });

    testWidgets('renders all form sections and field labels',
        (tester) async {
      await tester.pumpWidget(app(const UserProfilePage()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('基本信息'), findsOneWidget);
      expect(find.text('个人详情'), findsOneWidget);
      expect(find.text('性格与兴趣'), findsOneWidget);
      expect(find.text('重要背景'), findsOneWidget);
      expect(find.text('名字 *'), findsWidgets);
      expect(find.text('称呼'), findsWidgets);
      expect(find.text('头像'), findsWidgets);
      expect(find.text('称谓 / 代词'), findsWidgets);
      expect(find.text('年龄'), findsWidgets);
      expect(find.text('个人简介'), findsWidgets);
      expect(find.text('性格标签'), findsWidgets);
      expect(find.text('兴趣'), findsWidgets);
      expect(find.text('重要背景 / 明确事实'), findsWidgets);
    });
  });

  group('UserProfilePage save persistence', () {
    testWidgets('doSave persists all fields through production Hive write',
        (tester) async {
      final pageKey = GlobalKey<UserProfilePageState>();
      await tester.pumpWidget(app(UserProfilePage(key: pageKey)));
      await tester.pump(const Duration(milliseconds: 300));

      final state = pageKey.currentState!;
      state.displayNameController.text = '新名字';
      state.preferredAddressController.text = '称呼';
      state.avatarController.text = '头像';
      state.pronounsController.text = '他';
      state.ageController.text = '30';
      state.bioController.text = '简介';
      state.personalityController.text = '理性, 幽默';
      state.interestsController.text = '画画, 爬山';
      state.importantBackgroundController.text = '背景';
      await tester.pump(const Duration(milliseconds: 100));

      final result = await tester.runAsync(() => state.doSave(skipToast: true));
      expect(result, isTrue);

      final saved = db.userProfileBox.get('me');
      expect(saved, isNotNull);
      expect(saved!.displayName, '新名字');
      expect(saved.preferredAddress, '称呼');
      expect(saved.avatar, '头像');
      expect(saved.pronouns, '他');
      expect(saved.age, 30);
      expect(saved.bio, '简介');
      expect(saved.personality, equals(['理性', '幽默']));
      expect(saved.interests, equals(['画画', '爬山']));
      expect(saved.importantBackground, equals(['背景']));
    });

    testWidgets('blank name guard blocks doSave and nothing is written',
        (tester) async {
      final pageKey = GlobalKey<UserProfilePageState>();
      await tester.pumpWidget(app(UserProfilePage(key: pageKey)));
      await tester.pump(const Duration(milliseconds: 300));

      pageKey.currentState!.displayNameController.text = '   ';
      await tester.pump(const Duration(milliseconds: 100));

      final result = await tester.runAsync(
          () => pageKey.currentState!.doSave(skipToast: true));
      expect(result, isNull);
      expect(db.userProfileBox.get('me'), isNull);
    });

    testWidgets('overwrite preserves createdAt and updates updatedAt',
        (tester) async {
      final existing = UserProfile(
        id: 'me',
        displayName: '旧名',
        preferredAddress: '旧称呼',
        avatar: '',
        pronouns: '',
        age: 20,
        bio: '旧简介',
        personality: const ['旧性格'],
        interests: const ['旧兴趣'],
        importantBackground: const ['旧背景'],
      );
      await tester.runAsync(() => db.userProfileBox.put('me', existing));
      final originalCreatedAt = existing.createdAt;

      final pageKey = GlobalKey<UserProfilePageState>();
      await tester.pumpWidget(app(UserProfilePage(key: pageKey)));
      await tester.pump(const Duration(milliseconds: 300));

      // _loadExistingProfileSync loaded existing data; overwrite.
      final state = pageKey.currentState!;
      state.displayNameController.text = '新名';
      state.preferredAddressController.text = '新称呼';
      state.avatarController.text = '头像';
      state.pronounsController.text = '她';
      state.ageController.text = '25';
      state.bioController.text = '新简介';
      state.personalityController.text = '新性格';
      state.interestsController.text = '新兴趣';
      state.importantBackgroundController.text = '新背景';
      await tester.pump(const Duration(milliseconds: 100));

      final result = await tester.runAsync(() => state.doSave(skipToast: true));
      expect(result, isTrue);
      final saved = db.userProfileBox.get('me');
      expect(saved, isNotNull);
      expect(saved!.id, 'me');
      expect(saved.displayName, '新名');
      expect(saved.createdAt, originalCreatedAt);
      expect(saved.updatedAt.isAfter(originalCreatedAt), isTrue);
    });
  });
}
