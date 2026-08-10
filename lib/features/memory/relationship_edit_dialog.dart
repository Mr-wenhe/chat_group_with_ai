import 'package:chat_group/core/models/relationship_state.dart';
import 'package:flutter/material.dart';

class RelationshipEditValues {
  final int affinity;
  final int trust;
  final int friction;
  final int familiarity;
  final RelationshipMood mood;
  final RelationshipStage stage;
  final String notes;

  const RelationshipEditValues({
    required this.affinity,
    required this.trust,
    required this.friction,
    required this.familiarity,
    required this.mood,
    required this.stage,
    required this.notes,
  });
}

class RelationshipEditDialog extends StatefulWidget {
  final RelationshipState relationship;
  final Future<void> Function(RelationshipEditValues values) onSave;

  const RelationshipEditDialog({
    super.key,
    required this.relationship,
    required this.onSave,
  });

  @override
  State<RelationshipEditDialog> createState() => _RelationshipEditDialogState();
}

class _RelationshipEditDialogState extends State<RelationshipEditDialog> {
  late final TextEditingController _affinityController;
  late final TextEditingController _trustController;
  late final TextEditingController _frictionController;
  late final TextEditingController _familiarityController;
  late final TextEditingController _notesController;
  late RelationshipMood _mood;
  late RelationshipStage _stage;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final relationship = widget.relationship;
    _affinityController = TextEditingController(
      text: relationship.affinity.toString(),
    );
    _trustController =
        TextEditingController(text: relationship.trust.toString());
    _frictionController =
        TextEditingController(text: relationship.friction.toString());
    _familiarityController =
        TextEditingController(text: relationship.familiarity.toString());
    _notesController = TextEditingController(text: relationship.notes);
    _mood = relationship.recentMood;
    _stage = relationship.stage;
  }

  @override
  void dispose() {
    _affinityController.dispose();
    _trustController.dispose();
    _frictionController.dispose();
    _familiarityController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑关系'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: _numberField('亲密度', _affinityController)),
                  const SizedBox(width: 8),
                  Expanded(child: _numberField('信任', _trustController)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _numberField('摩擦', _frictionController)),
                  const SizedBox(width: 8),
                  Expanded(child: _numberField('熟悉度', _familiarityController)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _moodField()),
                  const SizedBox(width: 8),
                  Expanded(child: _stageField()),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _notesController,
                maxLines: 4,
                enabled: !_saving,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '关系备注',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const ValueKey('relationship-edit-save'),
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? '保存中' : '保存关系'),
        ),
      ],
    );
  }

  Widget _numberField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      enabled: !_saving,
      keyboardType: const TextInputType.numberWithOptions(signed: true),
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
      ),
    );
  }

  Widget _moodField() {
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        labelText: '当前情绪',
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RelationshipMood>(
          isExpanded: true,
          value: _mood,
          items: [
            for (final mood in RelationshipMood.values)
              DropdownMenuItem(
                value: mood,
                child: Text(_moodLabel(mood)),
              ),
          ],
          onChanged: _saving ? null : (value) => setState(() => _mood = value!),
        ),
      ),
    );
  }

  Widget _stageField() {
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        labelText: '关系阶段',
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RelationshipStage>(
          isExpanded: true,
          value: _stage,
          items: [
            for (final stage in RelationshipStage.values)
              DropdownMenuItem(
                value: stage,
                child: Text(_stageLabel(stage)),
              ),
          ],
          onChanged:
              _saving ? null : (value) => setState(() => _stage = value!),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final affinity = _parseInt(_affinityController.text, '亲密度', -100, 100);
    final trust = _parseInt(_trustController.text, '信任', -100, 100);
    final friction = _parseInt(_frictionController.text, '摩擦', 0, 100);
    final familiarity = _parseInt(_familiarityController.text, '熟悉度', 0, 100);
    if (affinity == null ||
        trust == null ||
        friction == null ||
        familiarity == null) {
      return;
    }

    if (_stage == RelationshipStage.romantic &&
        widget.relationship.stage != RelationshipStage.romantic) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认 romantic 关系'),
          content: const Text('这是人工设定的 romantic 关系，不代表系统自动推断。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认保存'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        RelationshipEditValues(
          affinity: affinity,
          trust: trust,
          friction: friction,
          familiarity: familiarity,
          mood: _mood,
          stage: _stage,
          notes: _notesController.text.trim(),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$error';
      });
    }
  }

  int? _parseInt(String raw, String label, int min, int max) {
    final value = int.tryParse(raw.trim());
    if (value == null || value < min || value > max) {
      setState(() {
        _error = '$label必须是 $min 到 $max 之间的整数';
      });
      return null;
    }
    return value;
  }

  static String _moodLabel(RelationshipMood mood) => switch (mood) {
        RelationshipMood.neutral => '中性',
        RelationshipMood.warm => '温暖',
        RelationshipMood.annoyed => '恼怒',
        RelationshipMood.awkward => '尴尬',
        RelationshipMood.protective => '保护',
        RelationshipMood.cold => '冷淡',
      };

  static String _stageLabel(RelationshipStage stage) => switch (stage) {
        RelationshipStage.stranger => '陌生人',
        RelationshipStage.acquaintance => '认识',
        RelationshipStage.friend => '朋友',
        RelationshipStage.closeFriend => '密友',
        RelationshipStage.romantic => 'romantic',
        RelationshipStage.strained => '紧张',
        RelationshipStage.hostile => '敌对',
      };
}
