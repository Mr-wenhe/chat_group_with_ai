part of 'doudizhu_table_view.dart';

class _RoundFeed extends StatelessWidget {
  const _RoundFeed({required this.events, required this.seats});

  final List<DoudizhuPublicEvent> events;
  final List<DoudizhuSeatSnapshot> seats;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visible =
        events.length > 8 ? events.sublist(events.length - 8) : events;
    final modelActions = events
        .where((event) => event.source == DoudizhuDecisionSource.characterModel)
        .length;
    final engineActions =
        events.where((event) => event.engineElapsedMilliseconds != null).length;
    final localBidActions = events
        .where((event) =>
            event.actionKind == DoudizhuLogKind.bid &&
            event.source == DoudizhuDecisionSource.masterFallback)
        .length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '公开牌桌动态',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (events.length > 8)
                TextButton(
                  key: const ValueKey<String>('doudizhu-show-full-log'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text('完整牌桌记录 · ${events.length} 条'),
                      content: SizedBox(
                        width: 420,
                        height: 420,
                        child: ListView.builder(
                          itemCount: events.length,
                          itemBuilder: (context, index) {
                            return _PublicEventRow(
                              event: events[index],
                              seats: seats,
                              showDetails: true,
                              showDealNumber: true,
                            );
                          },
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  child: Text('查看全部（${events.length}）'),
                ),
            ],
          ),
          Text(
            '角色模型 $modelActions · 宗师引擎 $engineActions · 叫分策略 $localBidActions',
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          if (visible.isEmpty)
            Text(
              '第 ${events.isEmpty ? 1 : events.last.dealNumber} 副牌 · 等待第一步',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            )
          else
            for (final event in visible)
              _PublicEventRow(
                event: event,
                seats: seats,
                showDetails: false,
                showDealNumber: false,
              ),
        ],
      ),
    );
  }
}

class _PublicEventRow extends StatelessWidget {
  const _PublicEventRow({
    required this.event,
    required this.seats,
    required this.showDetails,
    required this.showDealNumber,
  });

  final DoudizhuPublicEvent event;
  final List<DoudizhuSeatSnapshot> seats;
  final bool showDetails;
  final bool showDealNumber;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final source = _eventSourceLabel(event, seats);
    final details = _eventDetails(event);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: showDetails ? 5 : 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showDealNumber)
                Text(
                  '第 ${event.dealNumber} 副 · ',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              Expanded(
                child: Text(
                  event.message,
                  maxLines: showDetails ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: showDetails ? 13 : 11,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SourceBadge(label: source),
            ],
          ),
          if (event.publicLine?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(
                '“${event.publicLine}”',
                maxLines: showDetails ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: showDetails ? 12 : 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (showDetails && details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 3),
              child: Text(
                details,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
          if (!showDetails && event.fallbackNote != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                '兜底原因：${event.fallbackNote}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.error,
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.onSecondaryContainer,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _eventSourceLabel(
  DoudizhuPublicEvent event,
  List<DoudizhuSeatSnapshot> seats,
) {
  if (event.source == DoudizhuDecisionSource.characterModel) return '角色模型';
  if (event.source == DoudizhuDecisionSource.masterFallback) {
    if (event.actionKind == DoudizhuLogKind.bid) return '叫分策略';
    if (event.fallbackNote == '角色模型或凭据不可用' && (event.modelAttempts ?? 0) == 0) {
      return '宗师直连';
    }
    if (event.engineElapsedMilliseconds != null) return '宗师兜底';
    return '规则恢复';
  }
  final seat = event.seat;
  if (seat != null && seat >= 0 && seat < seats.length) {
    return seats[seat].isHuman ? '真人' : '自动规则';
  }
  return '系统';
}

String _eventDetails(DoudizhuPublicEvent event) {
  final details = <String>[];
  if ((event.modelAttempts ?? 0) > 0) {
    details.add('模型请求 ${event.modelAttempts} 次');
  }
  if (event.fallbackNote != null) details.add(event.fallbackNote!);
  if (event.engineElapsedMilliseconds != null) {
    details.add(
      '宗师 ${event.engineElapsedMilliseconds} ms · '
      '${event.engineCandidateCount ?? 0} 个候选 · '
      '评估分 ${event.engineScore ?? 0} · '
      '手数 ${event.engineHandsBefore ?? 0}→${event.engineHandsAfter ?? 0}',
    );
  }
  return details.join(' · ');
}
