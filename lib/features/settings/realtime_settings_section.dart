import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/realtime/providers/realtime_providers.dart';
import 'package:chat_group/features/realtime/realtime_settings.dart';

/// 「多人联机」设置区：服务地址 + 共享令牌（可选）。
///
/// 通常情况下这里什么都不用改：地址有编译期默认值，默认那台服务端不校验
/// 令牌，装上就能用。这一区存在的意义是换服务器，以及服务端要求令牌时补上。
///
/// 令牌是凭据，保存时走安全存储（与 API Key 同一套），不落 Hive 明文，
/// 也不会进入完整备份包。地址不是机密，仍然存在 `app_settings` 里，
/// 这样即使钥匙串不可用，用户也能看到自己配的是哪台服务器。
class RealtimeSettingsSection extends ConsumerStatefulWidget {
  const RealtimeSettingsSection({super.key});

  @override
  ConsumerState<RealtimeSettingsSection> createState() =>
      _RealtimeSettingsSectionState();
}

class _RealtimeSettingsSectionState
    extends ConsumerState<RealtimeSettingsSection> {
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _secureStorageAvailable = true;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final available = ref.read(realtimeSettingsStoreProvider)
        .secureStorageAvailable;
    final RealtimeSettings settings;
    try {
      settings = await ref.read(realtimeSettingsProvider.future);
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _secureStorageAvailable = available;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _baseUrlController.text = settings.baseUrl;
      _tokenController.text = settings.token;
      _secureStorageAvailable = available;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final store = ref.read(realtimeSettingsStoreProvider);
    final error = await store.save(RealtimeSettings(
      baseUrl: _baseUrlController.text,
      token: _tokenController.text,
    ));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _secureStorageAvailable = store.secureStorageAvailable;
    });
    if (error != null) {
      AppToast.show(context, error, icon: Icons.error_outline_rounded);
      return;
    }
    // 聊天页读的是这个 FutureProvider，失效后重进群聊就会用新配置连接。
    ref.invalidate(realtimeSettingsProvider);
    if (!mounted) return;
    AppToast.show(context, '多人联机配置已保存',
        icon: Icons.check_circle_outline_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          cs: cs,
          margin: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: '服务地址',
                      hintText: 'http://120.26.241.84:9210',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: '主人与客人必须填同一台服务器',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tokenController,
                    obscureText: _obscureToken,
                    decoration: InputDecoration(
                      labelText: '共享令牌（可选）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      // 令牌是可选的：默认那台服务器不校验令牌，地址填对就能用。
                      // 说清楚这点，否则用户看到空白的必填样式的输入框会以为没配好。
                      helperText: '留空即可连接不校验令牌的服务；服务端要求令牌时才需要填写，'
                          '填写后会存进系统安全存储',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureToken
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _obscureToken = !_obscureToken),
                        tooltip: _obscureToken ? '显示令牌' : '隐藏令牌',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!_secureStorageAvailable)
              _UnavailableNotice(cs: cs)
            else
              const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存联机配置'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '群主人创建群聊后可在群内「邀请客人」，客人凭邀请码加入。'
          '只有主人的设备会调用 AI 生成回复，客人负责参与聊天。',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _UnavailableNotice extends StatelessWidget {
  final ColorScheme cs;

  const _UnavailableNotice({required this.cs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前环境没有可用的安全存储，令牌无法保存；'
              '如果这台服务器不校验令牌，留空就行。',
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          ),
        ],
      ),
    );
  }
}
