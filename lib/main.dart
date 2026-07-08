import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/database/database_service.dart';
import 'core/theme/app_theme.dart';
import 'features/ai_character/ai_character_list_page.dart';
import 'features/chat_group/chat_group_list_page.dart';
import 'features/chat_group/chat_room_page.dart';
import 'features/direct_chat/direct_chat_session.dart';
import 'features/settings/settings_page.dart';
import 'providers/providers.dart';

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
    final db = ref.read(databaseServiceProvider);
    final savedMode = db.savedThemeMode;
    return MaterialApp(
      title: 'AI 群聊模拟器',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: savedMode,
      routes: {
        '/': (_) => const AICharacterListPage(),
        '/groups': (_) => const ChatGroupListPage(),
        '/settings': (_) => const SettingsPage(),
      },
      onGenerateRoute: (settings) {
        if (settings.name?.startsWith('/chat/') ?? false) {
          final groupId = settings.name!.replaceFirst('/chat/', '');
          return MaterialPageRoute(
              builder: (_) => ChatRoomPage(groupId: groupId));
        }
        if (settings.name?.startsWith('/dm/') ?? false) {
          final characterId = settings.name!.replaceFirst('/dm/', '');
          final conversationId =
              DirectChatSession.conversationIdFor(characterId);
          return MaterialPageRoute(
              builder: (_) => ChatRoomPage(groupId: conversationId));
        }
        return null;
      },
    );
  }
}
