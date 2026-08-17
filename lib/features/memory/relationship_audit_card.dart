import 'package:chat_group/core/models/relationship_state.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// One scan-friendly relationship row. Editing and event history live on the
/// detail route so the list remains comparable at a glance.
class RelationshipAuditCard extends StatelessWidget {
  final RelationshipState relationship;
  final String targetName;
  final String targetRole;
  final String targetAvatar;
  final String stageLabel;
  final String moodLabel;
  final String recentChange;
  final bool pinned;
  final VoidCallback onOpenDetails;

  const RelationshipAuditCard({
    super.key,
    required this.relationship,
    required this.targetName,
    required this.targetRole,
    required this.targetAvatar,
    required this.stageLabel,
    required this.moodLabel,
    required this.recentChange,
    required this.pinned,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        return Semantics(
          button: true,
          label: '查看$targetName的关系详情',
          child: InkWell(
            onTap: onOpenDetails,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: compact ? _compactLayout(context) : _wideLayout(context),
            ),
          ),
        );
      },
    );
  }

  Widget _wideLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _avatar(context),
        const SizedBox(width: 10),
        SizedBox(width: 175, child: _targetIdentity(context)),
        const SizedBox(width: 14),
        SizedBox(width: 92, child: _stage(context)),
        SizedBox(width: 78, child: _mood(context)),
        Expanded(
            child: Text(recentChange,
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 12),
        _updatedAt(context),
        _trailing(context),
      ],
    );
  }

  Widget _compactLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _avatar(context),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: _targetIdentity(context)),
                  _trailing(context),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _stage(context),
                  _mood(context),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      recentChange,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _updatedAt(context),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _avatar(BuildContext context) => CircleAvatar(
        radius: 18,
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          targetAvatar,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  Widget _targetIdentity(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            targetName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            targetRole,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );

  Widget _stage(BuildContext context) => Text(
        stageLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: _stageColor(context),
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _mood(BuildContext context) => Text(
        moodLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _moodColor(context)),
      );

  Widget _updatedAt(BuildContext context) => Text(
        _date(relationship.updatedAt),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );

  Widget _trailing(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pinned)
            Semantics(
              label: '已固定',
              child: Tooltip(
                message: '已固定',
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          const Icon(Icons.chevron_right_rounded),
        ],
      );

  Color _stageColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (relationship.stage) {
      RelationshipStage.friend ||
      RelationshipStage.closeFriend ||
      RelationshipStage.romantic =>
        Colors.indigo,
      RelationshipStage.stranger ||
      RelationshipStage.acquaintance =>
        cs.primary,
      RelationshipStage.strained || RelationshipStage.hostile => cs.error,
    };
  }

  Color _moodColor(BuildContext context) => switch (relationship.recentMood) {
        RelationshipMood.warm || RelationshipMood.protective => Colors.green,
        RelationshipMood.annoyed || RelationshipMood.awkward => Colors.orange,
        RelationshipMood.cold => Theme.of(context).colorScheme.error,
        RelationshipMood.neutral =>
          Theme.of(context).colorScheme.onSurfaceVariant,
      };

  String _date(DateTime value) =>
      DateFormat('MM月dd日 HH:mm').format(value.toLocal());
}
