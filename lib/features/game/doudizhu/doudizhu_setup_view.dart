import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'doudizhu_game_providers.dart';

enum DoudizhuSetupMode { god, participant }

class DoudizhuSelectedRole {
  const DoudizhuSelectedRole({required this.character, required this.config});

  final AICharacter character;
  final ApiConfig? config;
}

class DoudizhuMatchSetup {
  const DoudizhuMatchSetup({
    required this.mode,
    required this.roles,
    this.humanSeat,
  });

  final DoudizhuSetupMode mode;
  final List<DoudizhuSelectedRole?> roles;
  final int? humanSeat;
}

class DoudizhuSetupView extends ConsumerStatefulWidget {
  const DoudizhuSetupView({super.key, required this.onStart});

  final ValueChanged<DoudizhuMatchSetup> onStart;

  @override
  ConsumerState<DoudizhuSetupView> createState() => _DoudizhuSetupViewState();
}

class _DoudizhuSetupViewState extends ConsumerState<DoudizhuSetupView> {
  DoudizhuSetupMode _mode = DoudizhuSetupMode.god;
  int _humanSeat = 0;
  final List<String?> _roleIds = List<String?>.filled(3, null);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final characters = ref.watch(userManagedAICharactersProvider);
    final configs = ref.watch(doudizhuApiConfigsProvider);
    if (characters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 48, color: colors.outline),
              const SizedBox(height: 14),
              Text('还没有 AI 角色', style: TextStyle(color: colors.onSurface)),
              const SizedBox(height: 8),
              Text(
                '先创建至少一个 AI 角色。未绑定模型或凭据不可用时，由宗师引擎接手。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    final readyIds = <String>{
      for (final character in characters)
        if (_configFor(character, configs)?.hasCredential ?? false)
          character.id,
    };
    final seats = _mode == DoudizhuSetupMode.god
        ? [0, 1, 2]
        : [0, 1, 2].where((seat) => seat != _humanSeat).toList();
    final selectedRoleIds = _resolvedRoleIds(seats, characters);
    final hasEnoughUniqueRoles =
        characters.map((character) => character.id).toSet().length >=
            seats.length;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          '选择对局模式',
          style: TextStyle(
            color: colors.onSurface,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<DoudizhuSetupMode>(
          segments: const [
            ButtonSegment(
              value: DoudizhuSetupMode.god,
              label: Text('上帝视角'),
              icon: Icon(Icons.visibility_outlined),
            ),
            ButtonSegment(
              value: DoudizhuSetupMode.participant,
              label: Text('真人参与'),
              icon: Icon(Icons.sports_esports_outlined),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (value) => setState(() => _mode = value.first),
        ),
        const SizedBox(height: 8),
        Text(
          '每个 AI 角色只能占一个席位；选择已分配角色会交换席位。角色模型优先决定叫分和出牌，模型不可用时由宗师接手。',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        if (_mode == DoudizhuSetupMode.participant) ...[
          Text('选择真人席位', style: TextStyle(color: colors.onSurface)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('下家席')),
              ButtonSegment(value: 1, label: Text('对家席')),
              ButtonSegment(value: 2, label: Text('上家席')),
            ],
            selected: {_humanSeat},
            onSelectionChanged: (value) =>
                setState(() => _humanSeat = value.first),
          ),
          const SizedBox(height: 20),
        ],
        for (final seat in seats) ...[
          _RolePicker(
            seat: seat,
            characters: characters,
            readyIds: readyIds,
            selectedId: selectedRoleIds[seat]!,
            onChanged: (id) =>
                setState(() => _selectRole(seat, id, seats, selectedRoleIds)),
          ),
          const SizedBox(height: 14),
        ],
        if (_mode == DoudizhuSetupMode.participant)
          _HumanSeatSummary(seat: _humanSeat),
        const SizedBox(height: 20),
        if (!hasEnoughUniqueRoles) ...[
          Text(
            '当前有 ${characters.map((character) => character.id).toSet().length} 个不同角色；此模式需要 ${seats.length} 个。请先创建更多角色。',
            style: TextStyle(color: colors.error, fontSize: 12),
          ),
          const SizedBox(height: 10),
        ],
        FilledButton.icon(
          key: const ValueKey<String>('doudizhu-start'),
          onPressed: hasEnoughUniqueRoles
              ? () => _start(characters, configs, seats)
              : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('开始发牌'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }

  Map<int, String> _resolvedRoleIds(
    List<int> seats,
    List<AICharacter> characters,
  ) {
    final result = <int, String>{};
    final usedIds = <String>{};
    for (final seat in seats) {
      AICharacter? selected;
      final requestedId = _roleIds[seat];
      for (final character in characters) {
        if (character.id == requestedId && !usedIds.contains(character.id)) {
          selected = character;
          break;
        }
      }
      selected ??= characters.firstWhere(
        (character) => !usedIds.contains(character.id),
        orElse: () => characters.first,
      );
      result[seat] = selected.id;
      usedIds.add(selected.id);
    }
    return result;
  }

  void _selectRole(
    int seat,
    String selectedId,
    List<int> seats,
    Map<int, String> currentRoleIds,
  ) {
    int? otherSeat;
    for (final candidate in seats) {
      if (candidate != seat && currentRoleIds[candidate] == selectedId) {
        otherSeat = candidate;
        break;
      }
    }
    if (otherSeat != null) {
      _roleIds[otherSeat] = currentRoleIds[seat];
    }
    _roleIds[seat] = selectedId;
  }

  void _start(
    List<AICharacter> characters,
    List<ApiConfig> configs,
    List<int> seats,
  ) {
    final selectedRoleIds = _resolvedRoleIds(seats, characters);
    final roles = List<DoudizhuSelectedRole?>.generate(3, (seat) {
      if (_mode == DoudizhuSetupMode.participant && seat == _humanSeat) {
        return null;
      }
      final character = characters.firstWhere(
        (item) => item.id == selectedRoleIds[seat],
      );
      return DoudizhuSelectedRole(
        character: character,
        config: _configFor(character, configs),
      );
    });
    widget.onStart(
      DoudizhuMatchSetup(
        mode: _mode,
        roles: List.unmodifiable(roles),
        humanSeat: _mode == DoudizhuSetupMode.participant ? _humanSeat : null,
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
    required this.seat,
    required this.characters,
    required this.readyIds,
    required this.selectedId,
    required this.onChanged,
  });

  final int seat;
  final List<AICharacter> characters;
  final Set<String> readyIds;
  final String selectedId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final modelReady = readyIds.contains(selectedId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('第${seat + 1}席 · AI 角色',
            style: TextStyle(color: colors.onSurface)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey<String>('doudizhu-role-picker-$seat'),
          value: selectedId,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: [
            for (final character in characters)
              DropdownMenuItem(
                value: character.id,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CharacterAvatar(fallbackText: character.avatar, size: 24),
                    const SizedBox(width: 10),
                    Flexible(
                        fit: FlexFit.loose,
                        child: Text(character.name,
                            overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Text(
                      readyIds.contains(character.id) ? '已配模型' : '宗师兜底',
                      style: TextStyle(
                        color: readyIds.contains(character.id)
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: (id) {
            if (id != null) onChanged(id);
          },
        ),
        const SizedBox(height: 5),
        Text(
          modelReady
              ? '模型优先叫分和出牌；请求失败、回复无效或超时后由宗师接手。'
              : '未绑定可用模型或凭据；此角色会直接使用本地叫分策略和宗师引擎。',
          key: ValueKey<String>('doudizhu-role-model-status-$seat'),
          style: TextStyle(
            color: modelReady ? colors.onSurfaceVariant : colors.error,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _HumanSeatSummary extends StatelessWidget {
  const _HumanSeatSummary({required this.seat});

  final int seat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: colors.primary,
            child: const Text('我', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text('你坐在第${seat + 1}席。叫分结束后按手牌行动。')),
        ],
      ),
    );
  }
}
