import 'package:flutter/material.dart';
import '../work_task_usage_summary.dart';

/// 常驻任务汇总，不把设备账本缺失伪装成零消耗。
class WorkTaskUsageCard extends StatelessWidget {
  final WorkTaskUsageSummary summary;
  final bool unavailable;

  const WorkTaskUsageCard(
      {super.key, required this.summary, this.unavailable = false});

  @override
  Widget build(BuildContext context) {
    if (unavailable) return const Text('当前设备用量账本不可用');
    final s = summary;
    // 零请求不是"零消耗"：没有上游实报时只能显示未知，不能用文本长度补造数字。
    if (s.requests == 0) return const Text('本轮尚无上游实报用量，无法展示 Token 合计。');
    String value(ReportedTokenTotal field) =>
        '${field.label}${field.requests > 0 && field.requests < s.requests ? '（部分）' : ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 12, runSpacing: 2, children: [
              Text('输入 ${value(s.input)} Token'),
              Text('输出 ${value(s.output)} Token'),
              if (s.input.requests < s.requests && s.uncached.requests > 0)
                Text('普通输入 ${value(s.uncached)} Token（总输入缺字段）'),
              Tooltip(
                message: '缓存表示上游实报的命中 Token；缓存写入不计为命中。',
                child: Text('缓存 ${value(s.cached)} Token'),
              ),
              Text(
                  '命中率 ${s.cacheHitRate}（${s.cacheRateRequests}/${s.requests} 次）'),
              if (s.reasoning.requests > 0)
                Text('推理 ${value(s.reasoning)} Token（已含在输出）'),
            ]),
            Text(
              '上游实报（缓存已含输入）· 输入/输出完整 ${s.completeRequests}/${s.requests} 次'
              ' · 输入/输出缺失 ${s.unknownRequests} · 预算估算 ${s.estimatedRequests}'
              ' · 历史口径 ${s.legacyRequests} · 异常 ${s.invalidRequests}'
              '${s.incomplete ? ' · 统计不完整' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
