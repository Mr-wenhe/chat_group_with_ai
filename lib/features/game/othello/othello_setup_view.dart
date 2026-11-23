import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'othello_game_providers.dart';
import 'othello_types.dart';

enum OthelloMode { aiVsAi, humanVsAi }

class OthelloMatchSetup {
  const OthelloMatchSetup({
    required this.mode,
    required this.blackAi,
    required this.blackConfig,
    required this.whiteAi,
    required this.whiteConfig,
    this.humanSide,
  })  : assert(mode != OthelloMode.aiVsAi || blackAi != null),
        assert(mode != OthelloMode.aiVsAi || whiteAi != null),
        assert(mode != OthelloMode.humanVsAi || humanSide != null);

  final OthelloMode mode;
  final AICharacter? blackAi;
  final ApiConfig? blackConfig;
  final AICharacter? whiteAi;
  final ApiConfig? whiteConfig;
  final OthelloSide? humanSide;

  OthelloMatchSetup swappedSides() {
    if (mode == OthelloMode.humanVsAi) {
      return OthelloMatchSetup(
        mode: mode,
        blackAi: whiteAi,
        blackConfig: whiteConfig,
        whiteAi: blackAi,
        whiteConfig: blackConfig,
        humanSide: humanSide!.opponent,
      );
    }
    return OthelloMatchSetup(
      mode: mode,
      blackAi: whiteAi,
      blackConfig: whiteConfig,
      whiteAi: blackAi,
      whiteConfig: blackConfig,
    );
  }
}

class OthelloSetupView extends ConsumerStatefulWidget {
  const OthelloSetupView({super.key, required this.onStart});

  final ValueChanged<OthelloMatchSetup> onStart;

  @override
  ConsumerState<OthelloSetupView> createState() => _OthelloSetupViewState();
}

class _OthelloSetupViewState extends ConsumerState<OthelloSetupView> {
  OthelloMode _mode = OthelloMode.aiVsAi;
  OthelloSide _humanSide = OthelloSide.black;
  String? _blackId;
  String? _whiteId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final characters = ref.watch(userManagedAICharactersProvider);
    final configs = ref.watch(othelloApiConfigsProvider);
    if (characters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 48, color: cs.outline),
              const SizedBox(height: 16),
              Text('还没有 AI 角色', style: TextStyle(color: cs.onSurface)),
              const SizedBox(height: 8),
              Text(
                '请先在「AI 角色」里创建角色。未绑定模型或凭据不可用时，Hard 会接手。',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    _blackId =
        _validSelectedId(_blackId, characters)?.id ?? characters.first.id;
    if (characters.length > 1) {
      final validWhite = characters.where(
          (character) => character.id != _blackId && character.id == _whiteId);
      _whiteId = validWhite.isNotEmpty
          ? validWhite.first.id
          : characters.firstWhere((character) => character.id != _blackId).id;
    }

    final readyIds = {
      for (final character in characters)
        if (_configFor(character, configs)?.hasCredential ?? false)
          character.id,
    };
    final enoughCharacters =
        _mode != OthelloMode.aiVsAi || characters.length > 1;

    return ListView(
      padding: const EdgeInsets.all(24),
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
        SegmentedButton<OthelloMode>(
          segments: const [
            ButtonSegment(
              value: OthelloMode.aiVsAi,
              label: Text('上帝视角'),
              icon: Icon(Icons.visibility_outlined),
            ),
            ButtonSegment(
              value: OthelloMode.humanVsAi,
              label: Text('真人参与'),
              icon: Icon(Icons.sports_esports_outlined),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (value) => setState(() => _mode = value.first),
        ),
        const SizedBox(height: 12),
        Text(
          _mode == OthelloMode.aiVsAi
              ? '黑方先手。你能看到完整棋盘、双方角色和公开战术说明；棋盘只读。'
              : '选择执黑或执白。棋盘双方都可见，只在你的回合接受合法落点。',
          style:
              TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
        ),
        const SizedBox(height: 8),
        Text(
          readyIds.isEmpty
              ? '当前角色没有可用模型凭据，对局会直接使用 Hard。'
              : 'AI 角色先使用各自绑定的模型；模型返回失败或非法动作后，Hard 才接手。',
          style:
              TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
        ),
        const SizedBox(height: 24),
        if (_mode == OthelloMode.aiVsAi) ...[
          _RolePicker(
            label: '黑方（先手）· AI 角色',
            characters: characters,
            modelReadyIds: readyIds,
            selectedId: _blackId,
            excludeId: _whiteId,
            onChanged: (id) => setState(() => _blackId = id),
          ),
          const SizedBox(height: 16),
          if (characters.length > 1)
            _RolePicker(
              label: '白方 · AI 角色',
              characters: characters,
              modelReadyIds: readyIds,
              selectedId: _whiteId,
              excludeId: _blackId,
              onChanged: (id) => setState(() => _whiteId = id),
            )
          else
            Text(
              '上帝视角需要两位不同角色，请切换到「真人参与」或先创建另一位角色。',
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
        ] else ...[
          SegmentedButton<OthelloSide>(
            segments: const [
              ButtonSegment(
                value: OthelloSide.black,
                label: Text('我执黑 · 先手'),
              ),
              ButtonSegment(
                value: OthelloSide.white,
                label: Text('我执白 · 后手'),
              ),
            ],
            selected: {_humanSide},
            onSelectionChanged: (value) =>
                setState(() => _humanSide = value.first),
          ),
          const SizedBox(height: 16),
          _RolePicker(
            label: 'AI 对手',
            characters: characters,
            modelReadyIds: readyIds,
            selectedId: _blackId,
            onChanged: (id) => setState(() => _blackId = id),
          ),
        ],
        const SizedBox(height: 28),
        OutlinedButton.icon(
          onPressed: enoughCharacters ? _swapSides : null,
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text('交换黑白'),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed:
              enoughCharacters ? () => _start(characters, configs) : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('开局'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }

  AICharacter? _validSelectedId(
    String? selectedId,
    List<AICharacter> characters,
  ) {
    for (final character in characters) {
      if (character.id == selectedId) return character;
    }
    return null;
  }

  void _swapSides() {
    setState(() {
      if (_mode == OthelloMode.aiVsAi) {
        final previousBlackId = _blackId;
        _blackId = _whiteId;
        _whiteId = previousBlackId;
      } else {
        _humanSide = _humanSide.opponent;
      }
    });
  }

  void _start(List<AICharacter> characters, List<ApiConfig> configs) {
    final selected =
        characters.firstWhere((character) => character.id == _blackId);
    final selectedConfig = _configFor(selected, configs);
    if (_mode == OthelloMode.aiVsAi) {
      final second = characters.firstWhere((character) =>
          character.id == _whiteId && character.id != selected.id);
      widget.onStart(
        OthelloMatchSetup(
          mode: _mode,
          blackAi: selected,
          blackConfig: selectedConfig,
          whiteAi: second,
          whiteConfig: _configFor(second, configs),
        ),
      );
      return;
    }

    widget.onStart(
      OthelloMatchSetup(
        mode: _mode,
        blackAi: _humanSide == OthelloSide.white ? selected : null,
        blackConfig: _humanSide == OthelloSide.white ? selectedConfig : null,
        whiteAi: _humanSide == OthelloSide.black ? selected : null,
        whiteConfig: _humanSide == OthelloSide.black ? selectedConfig : null,
        humanSide: _humanSide,
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

class _RolePicker extends StatelessWidget {
  const _RolePicker({
    required this.label,
    required this.characters,
    required this.modelReadyIds,
    required this.selectedId,
    required this.onChanged,
    this.excludeId,
  });

  final String label;
  final List<AICharacter> characters;
  final Set<String> modelReadyIds;
  final String? selectedId;
  final String? excludeId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final options = characters.where(
        (character) => character.id != excludeId || characters.length == 1);
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        character.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
