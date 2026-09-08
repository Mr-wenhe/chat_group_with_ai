import 'dart:io';

import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';
import 'package:chat_group/features/settings/ai_processing_directory_policy.dart';
import 'package:chat_group/features/settings/api_config_form_page.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/features/settings/backup_restore_page.dart';
import 'package:chat_group/features/settings/user_profile_page.dart';
import 'package:chat_group/features/settings/ai_governance_page.dart';
import 'package:chat_group/features/settings/voice_service_settings_page.dart';
import 'package:chat_group/features/settings/work_mode_agent_settings_section.dart';
import 'package:chat_group/features/memory/relationship_audit_page.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/search/global_search_page.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/data_lifecycle_result_dialog.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';

part 'settings_page_build.dart';
part 'settings_page_config_support.dart';
part 'settings_page_token_support.dart';
part 'settings_page_lifecycle_support.dart';
part 'settings_page_profile_support.dart';
part 'settings_page_widgets.dart';

class _WeComField extends StatelessWidget {
  final ColorScheme cs;
  final String label;
  final TextEditingController controller;
  final bool obscure;

  const _WeComField({
    required this.cs,
    required this.label,
    required this.controller,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: cs.onSurfaceVariant),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _WeComConfigCard extends ConsumerStatefulWidget {
  const _WeComConfigCard();

  @override
  ConsumerState<_WeComConfigCard> createState() => _WeComConfigCardState();
}

class _WeComConfigCardState extends ConsumerState<_WeComConfigCard> {
  final _corpIdCtl = TextEditingController();
  final _corpSecretCtl = TextEditingController();
  final _agentIdCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await SecureStorageService().getWeComAppConfig();
    if (cfg != null && mounted) {
      _corpIdCtl.text = cfg['corpid'] ?? '';
      _corpSecretCtl.text = cfg['corpsecret'] ?? '';
      _agentIdCtl.text = cfg['agentid'] ?? '';
    }
  }

  @override
  void dispose() {
    _corpIdCtl.dispose();
    _corpSecretCtl.dispose();
    _agentIdCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cfg = {
      'corpid': _corpIdCtl.text.trim(),
      'corpsecret': _corpSecretCtl.text.trim(),
      'agentid': _agentIdCtl.text.trim(),
    };
    if (cfg['corpid']!.isEmpty ||
        cfg['corpsecret']!.isEmpty ||
        cfg['agentid']!.isEmpty) {
      AppToast.show(context, '请填写完整的 corpid / corpsecret / agentid');
      return;
    }
    await SecureStorageService().saveWeComAppConfig(cfg);
    if (mounted) {
      AppToast.show(context, '企业微信推送配置已保存', icon: Icons.check);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      cs: cs,
      margin: EdgeInsets.zero,
      children: [
        _WeComField(cs: cs, label: 'Corp ID', controller: _corpIdCtl),
        const SizedBox(height: 12),
        _WeComField(
            cs: cs,
            label: 'Corp Secret',
            controller: _corpSecretCtl,
            obscure: true),
        const SizedBox(height: 12),
        _WeComField(cs: cs, label: 'Agent ID', controller: _agentIdCtl),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存配置'),
          ),
        ),
      ],
    );
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final AiApiService _apiService;
  late final WorkFolderGrantService _workFolderGrantService;
  final _credentialResolver = SecureApiCredentialResolver();
  AppSkinMode _currentSkinMode = AppSkinMode.dark;
  bool _isTtsEnabled = true;
  Map<String, dynamic> _tokenUsage = {};
  String _aiProcessingDirPath = '';
  MediaUsage _mediaUsage = MediaUsage.empty;
  bool _hasPendingDeletion = false;
  bool _isCleaningMedia = false;

  /// Settings can be rendered by lightweight callers before DatabaseService
  /// has completed its normal startup initialization. The work-mode settings
  /// remain useful without undo controls in that state; production startup
  /// still supplies the durable snapshot service once the database is ready.
  WorkSnapshotService? _tryReadWorkSnapshotService() {
    try {
      return ref.read(workSnapshotServiceProvider);
    } on Object {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _apiService = AiApiService(
      AiRequestGateway(store: AiGovernanceStore.forDatabase(db)),
    );
    _workFolderGrantService = ref.read(workFolderGrantServiceProvider);
    _currentSkinMode = db.savedAppSkinMode;
    _isTtsEnabled = db.isTtsEnabled;
    _tokenUsage = db.getTokenUsage();
    _loadAiProcessingDirPath();
    _loadLifecycleState();
  }

  Future<void> _loadLifecycleState() async {
    final service = DataLifecycleService(db: ref.read(databaseServiceProvider));
    final usage = await service.mediaUsage();
    if (!mounted) return;
    setState(() {
      _mediaUsage = usage;
      _hasPendingDeletion = service.hasPendingOperation;
    });
  }

  Future<void> _loadAiProcessingDirPath() async {
    final db = ref.read(databaseServiceProvider);
    final path = await resolveAiProcessingDirectoryLabel(
      isWeb: kIsWeb,
      nativePathLoader: db.effectiveAiProcessingDirPath,
    );
    if (mounted) {
      setState(() => _aiProcessingDirPath = path);
    }
  }

  void _safeSetState(VoidCallback callback) {
    if (mounted) setState(callback);
  }

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
