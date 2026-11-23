/// 五子棋开局配置与席位选择。
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 对局模式。
enum GomokuMode {
  /// 两个 AI 角色对弈，你纯观战。
  aiVsAi,

  /// 一个 AI 角色与真人对弈。
  aiVsHuman,
}

/// 当前对局席位。AI 对弈时 primary 执黑、secondary 执白；
/// 人机对弈时 primary 是 AI，humanBlack 决定真人是否执黑。
class GomokuMatchSetup {
  final GomokuMode mode;
  final AICharacter primaryAi;
  final ApiConfig? primaryConfig;
  final AICharacter? secondaryAi;
  final ApiConfig? secondaryConfig;
  final bool humanBlack;

  const GomokuMatchSetup({
    required this.mode,
    required this.primaryAi,
    required this.primaryConfig,
    this.secondaryAi,
    this.secondaryConfig,
    this.humanBlack = false,
  }) : assert(mode != GomokuMode.aiVsAi || secondaryAi != null);

  /// 对局结束后沿用参赛者，交换黑白再开一局。
  GomokuMatchSetup swappedSides() {
    if (mode == GomokuMode.aiVsAi) {
      return GomokuMatchSetup(
        mode: mode,
        primaryAi: secondaryAi!,
        primaryConfig: secondaryConfig,
        secondaryAi: primaryAi,
        secondaryConfig: primaryConfig,
      );
    }
    return GomokuMatchSetup(
      mode: mode,
      primaryAi: primaryAi,
      primaryConfig: primaryConfig,
      humanBlack: !humanBlack,
    );
  }
}

/// 开局配置视图：选择模式、角色与黑白方。
class GomokuSetupView extends ConsumerStatefulWidget {
  final ValueChanged<GomokuMatchSetup> onStart;

  const GomokuSetupView({super.key, required this.onStart});

  @override
  ConsumerState<GomokuSetupView> createState() => _GomokuSetupViewState();
}

class _GomokuSetupViewState extends ConsumerState<GomokuSetupView> {
  GomokuMode _mode = GomokuMode.aiVsAi;
  String? _blackId;
  String? _whiteId;
  bool _humanBlack = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final characters = ref.watch(userManagedAICharactersProvider);
    final configs = ref.watch(apiConfigsProvider);

    if (characters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 48, color: cs.outline),
              const SizedBox(height: 16),
              Text(
                '还没有 AI 角色',
                style: TextStyle(fontSize: 16, color: cs.onSurface),
              ),
              const SizedBox(height: 8),
              Text(
                '请先在「AI 角色」里创建角色，再来对弈。未绑定模型的角色会由内置棋力辅助接手。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (!characters.any((character) => character.id == _blackId)) {
      _blackId = characters.first.id;
    }
    if (_mode == GomokuMode.aiVsAi &&
        characters.length > 1 &&
        (_whiteId == null ||
            _whiteId == _blackId ||
            !characters.any((character) => character.id == _whiteId))) {
      _whiteId =
          characters.firstWhere((character) => character.id != _blackId).id;
    }

    final modelReadyIds = {
      for (final character in characters)
        if (_configFor(character, configs)?.hasCredential ?? false)
          character.id,
    };
    final canStart = _mode != GomokuMode.aiVsAi || characters.length > 1;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '选择对局模式',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<GomokuMode>(
            segments: const [
              ButtonSegment(
                value: GomokuMode.aiVsAi,
                label: Text('两个 AI 对弈（观战）'),
                icon: Icon(Icons.visibility_outlined),
              ),
              ButtonSegment(
                value: GomokuMode.aiVsHuman,
                label: Text('我 vs AI'),
                icon: Icon(Icons.sports_esports_outlined),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value.first),
          ),
          const SizedBox(height: 12),
          Text(
            modelReadyIds.isEmpty
                ? '当前角色都未绑定模型，对局由内置棋力辅助完成。'
                : '标「模型」的角色会优先由自己绑定的模型落子；未绑定的由内置棋力辅助接手。',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          _RolePicker(
            label: _mode == GomokuMode.aiVsAi || !_humanBlack
                ? '黑方（先手）· AI 角色'
                : '白方 · AI 角色',
            characters: characters,
            modelReadyIds: modelReadyIds,
            selectedId: _blackId,
            excludeId: _mode == GomokuMode.aiVsAi ? _whiteId : null,
            onChanged: (id) => setState(() => _blackId = id),
          ),
          const SizedBox(height: 16),
          if (_mode == GomokuMode.aiVsAi && characters.length > 1)
            _RolePicker(
              label: '白方 · AI 角色',
              characters: characters,
              modelReadyIds: modelReadyIds,
              selectedId: _whiteId,
              excludeId: _blackId,
              onChanged: (id) => setState(() => _whiteId = id),
            )
          else if (_mode == GomokuMode.aiVsAi)
            Text(
              'AI 对弈需要至少两个角色，请切换到「我 vs AI」或先创建角色。',
              style: TextStyle(fontSize: 13, color: cs.error),
            )
          else
            _HumanSeatCard(humanBlack: _humanBlack),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: canStart ? _swapSides : null,
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('交换黑白'),
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: canStart ? () => _start(characters, configs) : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('开局'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }

  void _swapSides() {
    setState(() {
      if (_mode == GomokuMode.aiVsAi) {
        final previousBlackId = _blackId;
        _blackId = _whiteId;
        _whiteId = previousBlackId;
      } else {
        _humanBlack = !_humanBlack;
      }
    });
  }

  void _start(List<AICharacter> characters, List<ApiConfig> configs) {
    final primaryAi =
        characters.firstWhere((character) => character.id == _blackId);
    final secondaryAi = _mode == GomokuMode.aiVsAi
        ? characters.firstWhere((character) => character.id == _whiteId)
        : null;
    widget.onStart(
      GomokuMatchSetup(
        mode: _mode,
        primaryAi: primaryAi,
        primaryConfig: _configFor(primaryAi, configs),
        secondaryAi: secondaryAi,
        secondaryConfig:
            secondaryAi == null ? null : _configFor(secondaryAi, configs),
        humanBlack: _mode == GomokuMode.aiVsHuman && _humanBlack,
      ),
    );
  }

  ApiConfig? _configFor(AICharacter character, List<ApiConfig> configs) {
    if (character.apiConfigId.isEmpty) return null;
    for (final config in configs) {
      if (config.id == character.apiConfigId) return config;
    }
    return null;
  }
}

class _HumanSeatCard extends StatelessWidget {
  final bool humanBlack;

  const _HumanSeatCard({required this.humanBlack});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final seatDescription =
        humanBlack ? '黑方（先手）由你执子，你先在棋盘上点击落子' : '白方由你执子，轮到你时在棋盘上点击落子';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: cs.primary,
            child: const Text('我', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              seatDescription,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

/// 角色下拉选择。
class _RolePicker extends StatelessWidget {
  final String label;
  final List<AICharacter> characters;
  final Set<String> modelReadyIds;
  final String? selectedId;
  final String? excludeId;
  final ValueChanged<String> onChanged;

  const _RolePicker({
    required this.label,
    required this.characters,
    required this.modelReadyIds,
    required this.selectedId,
    this.excludeId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final options = characters.where((character) => character.id != excludeId);
    final effectiveId = options.any((character) => character.id == selectedId)
        ? selectedId
        : options.first.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: effectiveId,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: [
            for (final character in options)
              DropdownMenuItem(
                value: character.id,
                child: Row(
                  children: [
                    CharacterAvatar(fallbackText: character.avatar, size: 24),
                    const SizedBox(width: 10),
                    Text(character.name, style: TextStyle(color: cs.onSurface)),
                    if (modelReadyIds.contains(character.id)) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '模型',
                          style: TextStyle(fontSize: 10, color: cs.primary),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
          onChanged: (id) {
            if (id != null) onChanged(id);
          },
        ),
      ],
    );
  }
}
