import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/database_service.dart';
import 'core/theme/app_theme.dart';
import 'features/ai_character/ai_character_list_page.dart';
import 'features/chat_group/chat_group_list_page.dart';
import 'features/chat_group/chat_room_page.dart';
import 'features/settings/settings_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = DatabaseService();
  await db.init();

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'AI 群聊模拟器',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routes: {
        '/': (_) => const AICharacterListPage(),
        '/groups': (_) => const ChatGroupListPage(),
        '/settings': (_) => const SettingsPage(),
      },
      onGenerateRoute: (settings) {
        if (settings.name?.startsWith('/chat/') ?? false) {
          final groupId = settings.name!.replaceFirst('/chat/', '');
          return MaterialPageRoute(builder: (_) => ChatRoomPage(groupId: groupId));
        }
        return null;
      },
    );
  }
}
