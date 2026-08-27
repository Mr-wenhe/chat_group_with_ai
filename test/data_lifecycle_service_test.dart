import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/search_audit_entry.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

part 'data_lifecycle_service_test_helpers_01.dart';
part 'data_lifecycle_service_test_part_01.dart';
part 'data_lifecycle_service_test_part_02.dart';
part 'data_lifecycle_service_test_part_03.dart';
part 'data_lifecycle_service_test_part_04.dart';
part 'data_lifecycle_service_test_part_05.dart';

late Directory hiveDirectory;
late Directory mediaDirectory;
late DatabaseService db;
late MemoryCredentialStore credentialStore;
late DataLifecycleService service;

void main() {
  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
    credentialStore = MemoryCredentialStore();
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      clearExternalSettings: () async {},
    );
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  _registerDataLifecycleServiceTestPart1();
  _registerDataLifecycleServiceTestPart2();
  _registerDataLifecycleServiceTestPart3();
  _registerDataLifecycleServiceTestPart4();
  _registerDataLifecycleServiceTestPart5();
}
