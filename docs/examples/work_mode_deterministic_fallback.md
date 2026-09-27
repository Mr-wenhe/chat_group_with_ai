# 示例：Work Mode 确定性兜底剧本（不进入生产路径）

## 这是什么

`default_work_task_runner_doudizhu.dart` 是一份**针对单一交付物**（离线斗地主单文件 HTML）的确定性兜底实现。当模型不可用时，它按用户措辞的字面量命中，直接返回预置的规划决策、预置 HTML 与预置 QA 报告，使该任务在 provider 不稳定时仍能"完成"。

它曾被 `part` 进 `lib/features/work_mode/default_work_task_runner.dart`，并在
`default_work_task_runner_model_io.dart` 的 `_completeModelTurn` 首行短路调用；同类字面量分支还散落在另外 5 个 `lib/features/work_mode/` 文件里。

## 为什么它被移出生产代码

1. **绕过模型**：命中字面量即返回预置决策，群讨论与执行都不再调用配置的 LLM。
2. **伪造验收证据**：内置的 QA 报告对运行期从未核对过的文件恒定断言 30 条 PASS，
   即使 HTML 被改写也不会变化。
3. **硬编码**：分支条件里出现具体文件名（`doudizhu_game.html`）、具体角色名、具体措辞
   （`work mode` / `qa-only`），违反 CLAUDE.md 代码质量检查清单第 4 条。
4. **判定与措辞耦合**：同一个任务是否走确定性剧本，取决于用户有没有写出那几个关键词。

## 保留它的用途

作为"离线确定性兜底"这类需求的反面参考。如果将来确实要做兜底，边界应当是：

- 夹具（HTML/报告模板）放 `test/` 或示例数据目录，不放进 `lib/`；
- 生产路径只保留**通用**合同处理，分支条件不得出现具体文件名 / 角色名 / 用户措辞；
- 兜底产出只能是记账与状态，不得伪造回读结果或验收结论；
- 诚实的失败优于看似成功的假交付。

## 源码

以下为原始文件内容，按原样保存（未编译、未纳入静态分析、没有调用方）。
它首行的 `part of` 指向已不存在的库，因此无法单独编译，仅作参考。

~~~dart
part of 'default_work_task_runner.dart';

/// Deterministic recovery for the confirmed offline Dou Dizhu deliverable.
/// It still goes through the normal WorkAgentLoop tools, artifact guard, and
/// attachment delivery; it only replaces an unavailable planner response.
extension _DefaultWorkTaskRunnerDoudizhuFallback on DefaultWorkTaskRunner {
  bool _isConfirmedDoudizhuTask(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final state = decoded.state;
    final location = state?.deliverableContract?['location']?.toString() ?? '';
    final exactPath = location.replaceAll('\\', '/').endsWith(
              '/doudizhu_game.html',
            ) ||
        location == 'doudizhu_game.html';
    final source = '${task.userRequest}\n'
            '${task.contextSummary}\n'
            '${task.queuedUserRequests.join('\n')}\n'
            '${WorkDiscussionState.currentRequestScope(task)}'
        .toLowerCase();
    // A QA-only follow-up must reach the browser/report runner.  The durable
    // contract still carries the HTML path, so path presence alone cannot
    // force the deterministic developer writer; use the newest request as
    // the stage authority and ignore stale stage-correction context.
    final latestRequest =
        WorkDiscussionState.latestRequestScope(task).toLowerCase();
    final stageRequest = '${latestRequest}\n'
            '${WorkDiscussionState.currentRequestScope(task)}'
        .toLowerCase();
    final qaOnlyStage = stageRequest.contains('qa-only') ||
        stageRequest.contains('qa only') ||
        (stageRequest.contains('只打开') &&
            stageRequest.contains('不要重新生成') &&
            stageRequest.contains('不要编辑 html'));
    final latestDeveloper = latestRequest.contains('dev fix') ||
        latestRequest.contains('developer patch') ||
        latestRequest.contains('developer stage') ||
        latestRequest.contains('developer') ||
        latestRequest.contains('纯开发') ||
        latestRequest.contains('开发阶段');
    final effectiveLatestDeveloper = !qaOnlyStage && latestDeveloper;
    final contractDeveloper = !qaOnlyStage &&
        (state?.deliverableContract?['contentScope']?.toString() ?? '')
            .toLowerCase()
            .contains('developer');
    if (qaOnlyStage && !effectiveLatestDeveloper && !contractDeveloper) {
      return false;
    }
    final targetMentioned = source.contains('doudizhu_game.html') ||
        source.contains('斗地主') ||
        source.contains('dou dizhu');
    final qaOnly = source.contains('qa-only') ||
        source.contains('qa only') ||
        source.contains('doudizhu_test_report') ||
        source.contains('test report');
    final htmlFirstOverride = source.contains('html-first') ||
        source.contains('html first') ||
        source.contains('no qa before') ||
        source.contains('stage correction');
    return exactPath ||
        source.contains('confirmed source and contract') ||
        (targetMentioned &&
            (effectiveLatestDeveloper ||
                contractDeveloper ||
                htmlFirstOverride ||
                !qaOnly) &&
            source.contains('work mode'));
  }

  Map<String, dynamic>? _doudizhuPlannerDecision(
    WorkAgentModelRequest request,
    AgentTask task,
  ) {
    final routingText = '${task.userRequest}\n'
            '${task.contextSummary}\n'
            '${task.queuedUserRequests.join('\n')}\n'
            '${WorkDiscussionState.currentRequestScope(task)}\n'
            '${WorkDiscussionState.decodeExecutionState(task.executionStateJson).state?.deliverableContract?['contentScope'] ?? ''}\n'
            '${task.plan}\n'
            '${request.messages.map((message) => message['content'] ?? '').join('\n')}'
        .toLowerCase();
    final latestRequest =
        WorkDiscussionState.latestRequestScope(task).toLowerCase();
    final stageRequest = '${latestRequest}\n'
            '${WorkDiscussionState.currentRequestScope(task)}'
        .toLowerCase();
    final qaOnlyStage = stageRequest.contains('qa-only') ||
        stageRequest.contains('qa only') ||
        (stageRequest.contains('只打开') &&
            stageRequest.contains('不要重新生成') &&
            stageRequest.contains('不要编辑 html'));
    final forcedDeveloper = !qaOnlyStage &&
        (routingText.contains('doudizhu_game.html') ||
            routingText.contains('斗地主') ||
            routingText.contains('dou dizhu')) &&
        (routingText.contains('developer') ||
            routingText.contains('dev fix') ||
            routingText.contains('developer stage') ||
            routingText.contains('开发阶段') ||
            routingText.contains('纯开发'));
    // QA-only is a hard stage boundary: historical developer text in queued
    // requests or the old contract must never regain write access to HTML.
    if (_isDoudizhuQaTask(task)) {
      return _doudizhuQaPlannerDecision(task);
    }
    if (!forcedDeveloper && !_isConfirmedDoudizhuTask(task)) return null;
    final stage = _ensureDoudizhuStage(task);
    final completed = task.completedOperations.skip(stage.start).toList();
    final has = (String tool, [String? path]) {
      return completed.any((operation) {
        if (!operation.contains('"tool":"$tool"')) return false;
        return path == null || operation.contains('"path":"$path"');
      });
    };
    Map<String, dynamic> decision(
      String action,
      String update, {
      Map<String, dynamic>? tool,
      Map<String, dynamic>? completion,
    }) =>
        {
          'action': action,
          'public_update': update,
          'tool': tool,
          'completion': completion,
        };

    if ((stage.fresh || task.plan.trim().isEmpty) && completed.isEmpty) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'plan',
            '群讨论已确认目标与验收边界，陈雨薇按 workspace.list → workspace.read → workspace.patch → workspace.read 执行。',
            completion: {
              'steps': [
                '列出授权桌面工作区并确认规则 Markdown',
                '只读斗地主设计文档',
                '一次写入离线 doudizhu_game.html',
                '回读 HTML 并发布真实附件卡',
              ],
            },
          ),
        ),
      };
    }
    if (!has('workspace.list')) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '先盘点授权工作区，确认规则 Markdown 与目标文件位置。',
            tool: {
              'name': 'workspace.list',
              'arguments': {'path': '.', 'page': 1, 'pageSize': 100},
            },
          ),
        ),
      };
    }
    // Use the public target spelling for this repair revision. The mutation
    // resolver normalizes the single Desktop prefix against the authorized
    // Desktop root, while the distinct raw path gives the fresh patch action
    // a new idempotency key after an earlier failed checkpoint.
    const designPath = '斗地主游戏设计文档.md';
    const targetPath = 'Desktop/doudizhu_game.html';
    if (!has('workspace.read', designPath)) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '已确认工作区，正在只读设计 Markdown，不读取其他源文件。',
            tool: {
              'name': 'workspace.read',
              'arguments': {'path': designPath},
            },
          ),
        ),
      };
    }
    if (!has('workspace.patch', targetPath)) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '设计边界已核对，正在一次写入离线单文件斗地主页面。',
            tool: {
              'name': 'workspace.patch',
              'arguments': {
                'path': targetPath,
                'content': _doudizhuHtml,
              },
            },
          ),
        ),
      };
    }
    if (!has('workspace.read', targetPath)) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            'HTML 已写入，正在按合同回读同一路径并检查真实文件内容。',
            tool: {
              'name': 'workspace.read',
              'arguments': {'path': targetPath},
            },
          ),
        ),
      };
    }
    return {
      'success': true,
      'message': jsonEncode(
        decision(
          'finish',
          '目标 HTML 已写入并回读通过，准备发布 APP 真实附件卡；QA 仍按合同在附件卡之后启动。',
          completion: {
            'summary': '已生成并回读 Desktop/doudizhu_game.html，符合离线斗地主交付合同。',
            'evidence': [
              'workspace.list 已确认授权工作区',
              '设计 Markdown 已按只读约束读取',
              '目标 HTML 已写入并回读一次',
            ],
          },
        ),
      ),
    };
  }

  bool _isDoudizhuQaTask(AgentTask task) {
    final latest = WorkDiscussionState.latestRequestScope(task).toLowerCase();
    final stageRequest = '${latest}\n'
            '${WorkDiscussionState.currentRequestScope(task)}'
        .toLowerCase();
    final target = '${task.userRequest}\n$latest'.toLowerCase();
    final latestDeveloper = latest.contains('dev fix') ||
        latest.contains('developer patch') ||
        latest.contains('developer stage') ||
        latest.contains('developer') ||
        latest.contains('纯开发') ||
        latest.contains('开发阶段');
    final qaOnlyStage = stageRequest.contains('qa-only') ||
        stageRequest.contains('qa only') ||
        (stageRequest.contains('只打开') &&
            stageRequest.contains('不要重新生成') &&
            stageRequest.contains('不要编辑 html'));
    final developerOverride = !qaOnlyStage && latestDeveloper;
    final contractScope = WorkDiscussionState.decodeExecutionState(
          task.executionStateJson,
        )
            .state
            ?.deliverableContract?['contentScope']
            ?.toString()
            .toLowerCase() ??
        '';
    final contractDeveloper =
        !qaOnlyStage && contractScope.contains('developer');
    final qa = qaOnlyStage;
    return qa &&
        !developerOverride &&
        !contractDeveloper &&
        (target.contains('doudizhu_game.html') ||
            target.contains('斗地主') ||
            target.contains('dou dizhu'));
  }

  Map<String, dynamic>? _doudizhuQaPlannerDecision(AgentTask task) {
    final stage = _ensureDoudizhuQaStage(task);
    final completed = task.completedOperations.skip(stage.start).toList();
    final has = (String tool, [String? path]) {
      return completed.any((operation) {
        if (!operation.contains('"tool":"$tool"')) return false;
        return path == null || operation.contains('"path":"$path"');
      });
    };
    Map<String, dynamic> decision(
      String action,
      String update, {
      Map<String, dynamic>? tool,
      Map<String, dynamic>? completion,
    }) =>
        {
          'action': action,
          'public_update': update,
          'tool': tool,
          'completion': completion,
        };

    if ((stage.fresh || task.plan.trim().isEmpty) && completed.isEmpty) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'plan',
            'QA 已锁定现有 HTML 为只读输入，先回读文件，再写入唯一的 Markdown 测试报告；不改 HTML。',
            completion: {
              'steps': [
                '列出授权工作区并确认现有 HTML',
                '只读回读 doudizhu_game.html',
                '生成 doudizhu_test_report.md（30 条编号用例）',
                '回读报告并附加 APP 产物卡',
              ],
            },
          ),
        ),
      };
    }
    if (!has('workspace.list')) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '先确认授权工作区与现有附件位置，保持 QA 只读边界。',
            tool: {
              'name': 'workspace.list',
              'arguments': {'path': '.', 'page': 1, 'pageSize': 100},
            },
          ),
        ),
      };
    }
    if (!has('workspace.read', 'doudizhu_game.html')) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '正在只读回读现有 doudizhu_game.html，核对发牌、牌型、过牌和状态恢复实现。',
            tool: {
              'name': 'workspace.read',
              'arguments': {'path': 'doudizhu_game.html'},
            },
          ),
        ),
      };
    }
    if (!has('workspace.patch', 'doudizhu_test_report.md')) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '已完成源码级 30 条验收取证，正在一次写入 Markdown 测试报告；HTML 保持不变。',
            tool: {
              'name': 'workspace.patch',
              'arguments': {
                'path': 'doudizhu_test_report.md',
                'content': _doudizhuQaReport,
              },
            },
          ),
        ),
      };
    }
    if (!has('workspace.read', 'doudizhu_test_report.md')) {
      return {
        'success': true,
        'message': jsonEncode(
          decision(
            'tool',
            '测试报告已写入，正在回读同一路径，确认 30 条用例和修复建议未被截断。',
            tool: {
              'name': 'workspace.read',
              'arguments': {'path': 'doudizhu_test_report.md'},
            },
          ),
        ),
      };
    }
    return {
      'success': true,
      'message': jsonEncode(
        decision(
          'finish',
          '30 条 QA 结果已回读完成；报告已附加，FAIL 项将交给开发阶段修复，动态浏览器项保留真实证据状态。',
          completion: {
            'summary':
                '已生成并回读 Desktop/doudizhu_test_report.md；现有 HTML 未被 QA 修改。',
            'evidence': [
              'workspace.list 已确认授权工作区',
              'doudizhu_game.html 已只读回读',
              '30 条用例报告已写入并回读',
            ],
          },
        ),
      ),
    };
  }

  ({int start, bool fresh}) _ensureDoudizhuQaStage(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final revision = decoded.state?.requestRevision ?? 1;
    Map<String, dynamic> metadata;
    try {
      final raw = jsonDecode(task.executionStateJson);
      metadata =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    } on Object {
      metadata = <String, dynamic>{};
    }
    final existing = metadata['doudizhuQaStage'];
    if (existing is Map &&
        existing['kind'] == 'qa' &&
        existing['revision'] is num &&
        (existing['revision'] as num).toInt() == revision &&
        existing['start'] is num) {
      return (
        start: (existing['start'] as num)
            .toInt()
            .clamp(0, task.completedOperations.length),
        fresh: false,
      );
    }
    metadata['doudizhuQaStage'] = <String, dynamic>{
      'kind': 'qa',
      'revision': revision,
      'start': task.completedOperations.length,
    };
    task.executionStateJson = jsonEncode(metadata);
    return (start: task.completedOperations.length, fresh: true);
  }

  String get _doudizhuQaReport => r'''# 斗地主 HTML QA 测试报告

> 范围：只读核查 APP 生成的 `Desktop/doudizhu_game.html`；QA 未修改 HTML。报告由 APP Work Mode 写入并回读。
>
> 证据边界：源码级检查可复现；当前 Stage 03 没有可调用的浏览器上下文工具，因此需要真实点击/窗口尺寸的项目标记为 `BLOCKED`，不把静态推断冒充浏览器通过。

## 30 条编号用例

| # | 用例 | 预期 | 实际/证据 | 结果 |
|---:|---|---|---|---|
| 01 | 54 张牌组成牌堆 | 52 张普通牌 + 2 王且 id 唯一 | `deck()` 固定生成 54 个唯一 id | PASS |
| 02 | 三家发牌数量 | 17/17/17 + 3 底牌 | `slice(0,17/17/17/3)` | PASS |
| 03 | 发牌后排序 | 点数降序，同点稳定花色 | 三手与底牌均调用 `sortHand()` | PASS |
| 04 | 底牌不重复 | 底牌不出现在三手 | 固定切片且牌堆 id 唯一 | PASS |
| 05 | 地主 20 张 | 叫地主后地主手牌应为 20 | `finishBid()` 将 3 张底牌合并到实际地主并重新排序 | PASS |
| 06 | 1/2 分叫牌继续 | 应进入下一位叫牌 | `bid()` 设置 AI·东，`aiBid()` 再推进 AI·西 | PASS |
| 07 | 不叫后的叫牌流转 | 应由下一位继续叫牌 | `bid(0)` 进入 AI 叫牌；无人叫分才重新发牌 | PASS |
| 08 | 单牌合法性 | 单牌可出 | `typeOf`/`beats` 支持 | PASS |
| 09 | 对子/三张 | 同点 2/3 张可出 | `typeOf` 支持 | PASS |
| 10 | 顺子边界 | >=5，允许 A 且不含 2/王 | `consecutive` 限制 value < 15，允许 3-A | PASS |
| 11 | 连对 | >=3 对连续 | `pairSeq` 分类存在 | PASS |
| 12 | 飞机不带牌 | >=2 个连续三张 | `plane` 分类存在 | PASS |
| 13 | 飞机带单 | 每个三张配 1 张 | `wingCounts.every(x => x === 1)` 且带牌与核心分离 | PASS |
| 14 | 飞机带对 | 每个三张配 1 对 | `wingCounts.length === triples.length` 且每组为 2 张 | PASS |
| 15 | 三带一/三带对 | 带牌数量与核心分离 | 基础分类支持 | PASS |
| 16 | 四带二 | 两单或一对均可 | 仅接受 4+1+1 或 4+2，拒绝其他总张数 | PASS |
| 17 | 炸弹/王炸 | 炸弹压普通牌，王炸最大 | `beats` 支持 | PASS |
| 18 | 比牌 | 同类同长度按主值比较 | `beats` 支持 | PASS |
| 19 | 非法出牌不改手牌 | 失败保持原手 | `play` 先校验再过滤 | PASS |
| 20 | 首手过牌 | 首手禁止过牌 | `pass` 检查无上手或自己出牌 | PASS |
| 21 | 合法提示完整性 | 可提示所有可压制牌型 | `candidates(hand)` 枚举手牌子集并复用完整 `typeOf/ beats` | PASS |
| 22 | AI 使用自身手牌 | AI 不得读取玩家手牌 | `aiTurn()` 传入 `state.ai1/state.ai2` | PASS |
| 23 | AI 轮转 | AI 出牌后回到玩家 | `AI·东 → AI·西 → 你`，连续过牌后牌权重置 | PASS |
| 24 | 计分 | 地主/农民计分一致 | 叫分 × 炸弹/火箭倍数，按地主/农民阵营结算 | PASS |
| 25 | 胜负结算 | 依据阵营结算 | `settle` 有基础展示 | PASS |
| 26 | 刷新恢复 | 刷新后恢复完整合法局面 | `localStorage` 读写存在；未做浏览器刷新实测 | BLOCKED |
| 27 | 375px 响应式 | 牌区可操作无溢出 | CSS 有断点；未打开浏览器实测 | BLOCKED |
| 28 | 768px 响应式 | 布局可用 | CSS 有断点；未打开浏览器实测 | BLOCKED |
| 29 | 1440px 响应式 | 桌面布局可用 | `max-width:1440px`；未打开浏览器实测 | BLOCKED |
| 30 | 键盘/ARIA | 牌与按钮可聚焦、可操作 | `aria-label`/Enter/空格代码存在；未浏览器实测 | BLOCKED |

## 结论

- **源码级 FAIL：0 项**：01–25 均已通过静态规则核查。
- **源码级 PASS：25 项**：01–25，覆盖发牌、排序、牌型、压制、轮转、计分与结算。
- **真实浏览器 BLOCKED：5 项**：26–30；本轮没有调用浏览器上下文，不能宣称通过。

## 开发修复清单

1. 继续在可用浏览器上下文中完成 26–30，并把刷新、375/768/1440、键盘和 ARIA 的真实操作证据补入下一版报告。
''';

  ({int start, bool fresh}) _ensureDoudizhuStage(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final revision = decoded.state?.requestRevision ?? 1;
    Map<String, dynamic> metadata;
    try {
      final raw = jsonDecode(task.executionStateJson);
      metadata =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    } on Object {
      metadata = <String, dynamic>{};
    }
    final existing = metadata['doudizhuStage'];
    if (existing is Map &&
        existing['kind'] == 'developer' &&
        existing['revision'] is num &&
        (existing['revision'] as num).toInt() == revision &&
        existing['start'] is num) {
      return (
        start: (existing['start'] as num)
            .toInt()
            .clamp(0, task.completedOperations.length),
        fresh: false,
      );
    }
    metadata['doudizhuStage'] = <String, dynamic>{
      'kind': 'developer',
      'revision': revision,
      'start': task.completedOperations.length,
    };
    task.executionStateJson = jsonEncode(metadata);
    return (start: task.completedOperations.length, fresh: true);
  }

  String get _doudizhuHtml => r'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>离线斗地主 · 群聊验收版</title>
<style>
:root{--green:#1f6b3a;--red:#dc3545;--suit-red:#e53935;--ink:#212121;--gold:#ffd54a;--felt:#0c4d32;--card-w:80px;--card-h:120px;--overlap:44px;--gap:8px}
*{box-sizing:border-box}body{margin:0;background:#071f16;color:#f7fff9;font:16px/1.45 system-ui,-apple-system,"PingFang SC",sans-serif}button{font:inherit;cursor:pointer;border:0;border-radius:8px;padding:8px 14px;background:#eef7f0;color:#123522;font-weight:700}button:disabled{opacity:.45;cursor:not-allowed}button:focus-visible,.card:focus-visible{outline:3px solid #fff;outline-offset:3px}.app{max-width:1440px;margin:auto;min-height:100vh;padding:16px;display:grid;gap:var(--gap)}header,.panel{background:rgba(5,35,23,.94);border:1px solid #4c9670;border-radius:12px;padding:16px;box-shadow:0 8px 24px #0004}header{display:flex;justify-content:space-between;align-items:center;gap:var(--gap);flex-wrap:wrap}h1,h2,p{margin:0}h1{font-size:clamp(22px,4vw,34px)}h2{font-size:20px;color:#d4f4de}.badge{display:inline-flex;padding:4px 8px;border-radius:999px;background:#174f35;color:#dff8e7;font-size:13px}.layout{display:grid;grid-template-columns:minmax(0,1fr) 310px;gap:var(--gap)}.table{min-height:490px;background:radial-gradient(circle at 50% 38%,#19734a,#073621 70%);border-radius:14px;padding:16px;display:grid;gap:var(--gap);align-content:start}.status{display:flex;gap:var(--gap);align-items:center;flex-wrap:wrap}.status strong{color:#ffe9a8}.players{display:grid;grid-template-columns:repeat(3,1fr);gap:var(--gap)}.player{padding:10px;background:#062b1ccc;border:1px solid #4c9670;border-radius:8px}.player.active{border-color:var(--gold);box-shadow:0 0 0 2px #ffd54a66}.player small{display:block;color:#b7e7c6}.bottom{display:flex;gap:var(--gap);align-items:center;min-height:54px}.hand{display:flex;align-items:flex-end;min-height:calc(var(--card-h) + 22px);overflow-x:auto;overflow-y:visible;padding:12px var(--overlap) 4px 12px;scrollbar-width:thin}.card{flex:0 0 var(--card-w);width:var(--card-w);height:var(--card-h);margin-left:calc(var(--overlap) * -1);position:relative;background:#fff;color:var(--ink);border:2px solid #d4d4d4;border-radius:8px;padding:6px;display:flex;flex-direction:column;justify-content:space-between;text-align:left;box-shadow:0 4px 8px #0005;transition:transform .12s,border-color .12s,box-shadow .12s}.card:first-child{margin-left:0}.card:hover,.card.selected{transform:translateY(-10px);z-index:4}.card.selected{border-color:var(--green);box-shadow:0 0 0 3px var(--green),0 7px 14px #0006}.card.hint{border-color:var(--gold);box-shadow:0 0 16px 5px #ffd54acc,0 0 0 2px #9b7411}.rank{font-size:clamp(17px,2.5vw,28px);font-weight:900}.suit{font-size:clamp(18px,3vw,30px);align-self:center}.red{color:var(--suit-red)}.black{color:var(--ink)}.actions{display:flex;gap:var(--gap);flex-wrap:wrap;align-items:center}.primary{background:var(--green);color:#fff}.danger{background:#ffeaec;color:#8f1e2b}.hint-button{background:#ffe68b;color:#563e00}.message{min-height:27px;padding:6px 10px;border-radius:6px;color:#dff8e7}.message.error{border:2px solid var(--red);color:#ffd9dd;background:#5e1822}.message.ok{background:#174f35}.side{display:grid;align-content:start;gap:var(--gap)}.rules{color:#c8ead2;font-size:14px}.rules ul{padding-left:20px;margin:8px 0}.settlement{display:none;background:#194e30;border:1px solid var(--gold)}.settlement.show{display:block}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}@media(max-width:899px){:root{--card-w:64px;--card-h:96px;--overlap:44px}.layout{grid-template-columns:1fr}.side{grid-template-columns:repeat(2,minmax(0,1fr))}.rules{grid-column:1/-1}}@media(max-width:599px){:root{--card-w:56px;--card-h:80px;--overlap:34px}.app{padding:8px}.table,header,.panel{padding:10px}.players{font-size:13px}.side{grid-template-columns:1fr}.bottom{align-items:flex-start;flex-direction:column}.card{padding:4px}}
</style>
</head>
<body>
<main class="app" data-build="ddz-r5-20260922" aria-label="离线斗地主游戏">
<header><div><h1>离线斗地主</h1><p class="badge">54 张牌 · 17/17/17 + 3 底牌</p></div><div class="actions"><button id="newGame" class="danger" aria-label="重新发牌">重新发牌</button><span id="phase" class="badge">叫分阶段</span></div></header>
<div class="layout"><section class="table" aria-live="polite">
<div class="status"><span>回合：<strong id="turn">你</strong></span><span>当前牌型：<strong id="lastPlay">无</strong></span><span>分数：<strong id="score">0</strong></span></div>
<div class="players"><div class="player" id="p0"><b>你</b><small>农民 / 17 张</small></div><div class="player" id="p1"><b>AI·东</b><small>待机 / 17 张</small></div><div class="player" id="p2"><b>AI·西</b><small>待机 / 17 张</small></div></div>
<div class="panel" id="bidPanel"><h2>叫分</h2><p>先叫分，3 分直接成为地主；首手出牌不能过牌。</p><div class="actions" id="bids"><button data-bid="1">1 分</button><button data-bid="2">2 分</button><button data-bid="3" class="primary">3 分</button><button data-bid="0">不叫</button></div></div>
<div class="bottom"><b>底牌</b><span id="bottomCards" class="badge">叫分后揭示 3 张</span></div>
<div><h2>你的手牌 <span id="handCount" class="badge">17 张</span></h2><div id="hand" class="hand" role="list" aria-label="你的手牌"></div></div>
<div class="actions"><button id="hint" class="hint-button" aria-label="获取合法提示">提示</button><button id="pass" aria-label="过牌" disabled>过牌</button><button id="play" class="primary" aria-label="出牌">出牌</button></div>
<div id="message" class="message" role="status"></div>
<div id="settlement" class="settlement panel" aria-live="assertive"><h2>本局结算</h2><p id="settlementText"></p><p>地主阵营：<strong id="landlordTeam">待定</strong> · 得分：<strong id="finalScore">0</strong></p></div>
</section><aside class="side"><section class="panel rules"><h2>验收状态</h2><ul><li>合法选中：<code>#1f6b3a</code></li><li>非法状态：<code>#dc3545</code>，手牌不变</li><li>提示牌：金色光晕 + 徽标</li><li>刷新：自动恢复当前局面</li></ul><p id="stateNote">state: ready</p></section><section class="panel rules"><h2>操作说明</h2><p>点击或键盘 Enter/空格选择牌；选择完成后出牌。提示只会推荐能压过上家的牌型。</p></section></aside></div>
</main>
<script>
(() => {
  const STORE='ddz-offline-v1';
  const suits=[['♠','black'],['♥','red'],['♣','black'],['♦','red']];
  const ranks=['3','4','5','6','7','8','9','10','J','Q','K','A','2'];
  const values=Object.fromEntries(ranks.map((r,i)=>[r,i+3]));
  const $=id=>document.getElementById(id);
  let state;
  const suitOrder={'♠':0,'♥':1,'♣':2,'♦':3,'🃏':4};
  function sortHand(cards){return [...cards].sort((a,b)=>b.value-a.value||(suitOrder[a.suit]??9)-(suitOrder[b.suit]??9))}
  function deck(){const d=[];for(const [s,c] of suits)for(const r of ranks)d.push({id:`${s}${r}`,suit:s,color:c,rank:r,value:values[r]});d.push({id:'small-joker',suit:'🃏',color:'red',rank:'小王',value:16});d.push({id:'big-joker',suit:'🃏',color:'red',rank:'大王',value:17});return d}
  function shuffle(a){let seed=20260922;for(let i=a.length-1;i>0;i--){seed=(seed*9301+49297)%233280;const j=Math.floor(seed/233280*(i+1));[a[i],a[j]]=[a[j],a[i]]}return a}
  function newGame(){const d=shuffle(deck());state={phase:'bid',bidTurn:'你',hand:sortHand(d.slice(0,17)),ai1:sortHand(d.slice(17,34)),ai2:sortHand(d.slice(34,51)),bottom:sortHand(d.slice(51)),selected:[],hint:[],bid:0,bidder:null,landlord:null,lastPlay:null,turn:'你',score:0,multiplier:1,passCount:0,passed:false,message:'',error:false};save();render()}
  function save(){localStorage.setItem(STORE,JSON.stringify(state))}
  function load(){try{const x=JSON.parse(localStorage.getItem(STORE)||'null');if(x&&Array.isArray(x.hand)&&x.hand.length<=20){state=x;state.bidTurn=state.bidTurn||'你';state.bidder=state.bidder||null;state.multiplier=state.multiplier||1;state.passCount=state.passCount||0;state.hand=sortHand(state.hand);state.ai1=sortHand(state.ai1||[]);state.ai2=sortHand(state.ai2||[]);state.bottom=sortHand(state.bottom||[]);return}}catch(e){}newGame()}
  function setMessage(text,error=false){state.message=text;state.error=error;renderMessage()}
  function renderMessage(){const el=$('message');el.textContent=state.message||'选择牌后出牌；提示会标记合法推荐。';el.className=`message ${state.error?'error':'ok'}`}
  function typeOf(cs){
    if(!cs.length)return null;
    const v=cs.map(c=>c.value).sort((a,b)=>a-b), counts={};
    v.forEach(x=>counts[x]=(counts[x]||0)+1);
    const keys=Object.keys(counts).map(Number).sort((a,b)=>a-b), groups=Object.values(counts).sort((a,b)=>b-a);
    const consecutive=(xs)=>xs.length>1&&xs.every((x,i)=>i===0||x===xs[i-1]+1)&&xs.every(x=>x<15);
    if(cs.length===1)return {name:'单牌',kind:'single',main:v[0],len:1};
    if(cs.length===2&&v[0]===16&&v[1]===17)return {name:'王炸',kind:'rocket',main:17,len:1};
    if(cs.length===2&&groups[0]===2)return {name:'对子',kind:'pair',main:v[0],len:1};
    if(cs.length===3&&groups[0]===3)return {name:'三张',kind:'triple',main:v[0],len:1};
    if(cs.length===4&&groups[0]===4)return {name:'炸弹',kind:'bomb',main:v[0],len:1};
    if(cs.length>=5&&keys.length===cs.length&&consecutive(keys))return {name:'顺子',kind:'straight',main:keys[keys.length-1],len:keys.length};
    if(cs.length>=6&&cs.length%2===0&&keys.length===cs.length/2&&keys.every(k=>counts[k]===2)&&consecutive(keys))return {name:'连对',kind:'pairSeq',main:keys[keys.length-1],len:keys.length/2};
    const triples=keys.filter(k=>counts[k]===3);
    if(triples.length>=2&&consecutive(triples)){
      const wingCount=cs.length-triples.length*3;
      const wingCounts=keys.filter(k=>!triples.includes(k)).map(k=>counts[k]);
      if(wingCount===0)return {name:'飞机',kind:'plane',main:triples[triples.length-1],len:triples.length};
      if(wingCount===triples.length&&wingCounts.every(x=>x===1))return {name:'飞机带单',kind:'plane1',main:triples[triples.length-1],len:triples.length};
      if(wingCount===triples.length*2&&wingCounts.length===triples.length&&wingCounts.every(x=>x===2))return {name:'飞机带对',kind:'plane2',main:triples[triples.length-1],len:triples.length};
    }
    if(groups[0]===3&&cs.length===4)return {name:'三带一',kind:'triple1',main:keys.find(k=>counts[k]===3),len:1};
    if(groups[0]===3&&cs.length===5&&groups[1]===2)return {name:'三带对',kind:'triple2',main:keys.find(k=>counts[k]===3),len:1};
    if(groups[0]===4&&cs.length===6&&(groups[1]===2||groups[1]===1))return {name:'四带二',kind:'four2',main:keys.find(k=>counts[k]===4),len:1};
    return null;
  }
  function beats(a,b){if(!a)return true;if(!b)return false;if(a.kind==='rocket')return false;if(b.kind==='rocket'||b.kind==='bomb'&&a.kind!=='bomb')return true;return a.kind===b.kind&&a.len===b.len&&a.main>b.main}
  // ponytail: subset scan keeps the hint engine complete; cap changes only if profiling proves it too slow on 20 cards.
  function candidates(hand=state.hand){const h=sortHand(hand),s=[];for(let mask=1;mask<(1<<h.length);mask++){const size=mask.toString(2).replace(/0/g,'').length;if(size>20)continue;const cs=[];for(let i=0;i<h.length;i++)if(mask&(1<<i))cs.push(h[i]);const t=typeOf(cs);if(t&&beats(state.lastPlay,t))s.push(cs)}return s}
  function selectCard(c){state.selected=state.selected.includes(c.id)?state.selected.filter(x=>x!==c.id):[...state.selected,c.id];state.hint=[];save();render()}
  function play(){if(state.phase==='bid'){setMessage('请先完成叫分。',true);return}if(state.turn!=='你'){setMessage('当前不是你的回合。',true);return}const cs=state.hand.filter(c=>state.selected.includes(c.id)),t=typeOf(cs);if(!t||!beats(state.lastPlay,t)){setMessage('非法出牌：牌型不合法或无法压过上家，手牌保持不变。',true);state.selected=[];render();return}state.hand=sortHand(state.hand.filter(c=>!state.selected.includes(c.id)));state.lastPlay={...t,owner:'你'};if(t.kind==='bomb'||t.kind==='rocket')state.multiplier*=2;state.selected=[];state.hint=[];state.passCount=0;state.passed=false;state.turn='AI·东';state.score+=state.landlord==='你'?2:1;setMessage(`已出${t.name}，轮到 AI·东。`);if(!state.hand.length)return settle('你');save();render();setTimeout(aiTurn,500)}
  function aiTurn(){if(state.phase!=='play')return;const actor=state.turn,hand=actor==='AI·东'?state.ai1:state.ai2,options=candidates(hand);if(options.length){const cs=options[0],t=typeOf(cs);if(actor==='AI·东')state.ai1=sortHand(hand.filter(c=>!cs.some(x=>x.id===c.id)));else state.ai2=sortHand(hand.filter(c=>!cs.some(x=>x.id===c.id)));state.lastPlay={...t,owner:actor};if(t.kind==='bomb'||t.kind==='rocket')state.multiplier*=2;state.passCount=0;state.score+=1;setMessage(`${actor}出${t.name}。`)}else{state.passCount=(state.passCount||0)+1;state.passed=true;setMessage(`${actor}过牌。`);if(state.passCount>=2){state.lastPlay=null;state.passCount=0;setMessage(`${actor}过牌，牌权回到你。`)}}state.turn=actor==='AI·东'?'AI·西':'你';if(state.turn!=='你')setTimeout(aiTurn,500);save();render()}
  function pass(){if(state.phase!=='play'||state.turn!=='你'){setMessage('当前不能过牌。',true);return}if(!state.lastPlay||state.lastPlay.owner==='你'){setMessage('首手出牌不能过牌。',true);return}state.selected=[];state.hint=[];state.passCount=(state.passCount||0)+1;state.passed=true;state.turn='AI·东';if(state.passCount>=2){state.lastPlay=null;state.passCount=0}setMessage('你已过牌。');save();render();setTimeout(aiTurn,500)}
  function hint(){if(state.phase!=='play'){setMessage('叫分后才能使用提示。',true);return}const cs=candidates()[0];state.hint=cs?cs.map(c=>c.id):[];setMessage(cs?`提示：${typeOf(cs).name}，金色光晕为合法推荐。`:'没有能压过上家的牌。');render()}
  function finishBid(id){state.landlord=id;state.phase='play';state.turn=id;state.score=state.bid||1;if(id==='你')state.hand=sortHand([...state.hand,...state.bottom]);if(id==='AI·东')state.ai1=sortHand([...state.ai1,...state.bottom]);if(id==='AI·西')state.ai2=sortHand([...state.ai2,...state.bottom]);setMessage(id==='你'?`你成为地主，已将 ${state.bottom.length} 张底牌并入手牌；首手不能过牌。`:`${id}成为地主，已并入 ${state.bottom.length} 张底牌，轮到${id}。`);save();render();if(state.turn!=='你')setTimeout(aiTurn,500)}
  function aiBid(){if(state.phase!=='bid'||state.bidTurn==='你')return;const bidder=state.bidTurn,hand=bidder==='AI·东'?state.ai1:state.ai2,hasJoker=hand.some(c=>c.value>=16);let call=0;if(state.bid===0)call=1;else if(state.bid===1&&hasJoker)call=2;else if(state.bid===2&&hasJoker)call=3;if(call>state.bid){state.bid=call;state.bidder=bidder}if(call===3){finishBid(bidder);return}if(bidder==='AI·东'){state.bidTurn='AI·西';setMessage(`${bidder}${call?'叫'+call+'分':'不叫'}，AI·西继续叫分。`);save();render();setTimeout(aiBid,400);return}if(state.bidder){finishBid(state.bidder);return}setMessage('本轮无人叫分，重新发牌。');save();render();setTimeout(newGame,700)}
  function bid(n){if(state.phase!=='bid'||state.bidTurn!=='你')return;if(n>state.bid){state.bid=n;state.bidder='你'}if(n===3){finishBid('你');return}state.bidTurn='AI·东';setMessage(n===0?'你不叫，等待 AI 叫分。':`你叫${n}分，等待 AI 叫分。`);save();render();setTimeout(aiBid,400)}
  function settle(winner){state.phase='settled';const landlordWin=winner===state.landlord;const base=Math.max(1,state.bid||1)*Math.max(1,state.multiplier||1);const landlordDelta=base*2;state.score=landlordWin?landlordDelta:base;state.message=landlordWin?`${winner}获胜，地主阵营 +${landlordDelta}，两位农民各 -${base}。`:`${winner}获胜，地主阵营 -${landlordDelta}，两位农民各 +${base}。`;save();render()}
  function render(){
    $('phase').textContent=state.phase==='bid'?'叫分阶段':state.phase==='play'?'出牌阶段':'已结算';$('turn').textContent=state.phase==='bid'?state.bidTurn:state.turn;$('score').textContent=state.score;$('lastPlay').textContent=state.lastPlay?state.lastPlay.name:'无';$('handCount').textContent=`${state.hand.length} 张`;$('bottomCards').textContent=state.landlord?state.bottom.map(c=>c.rank).join(' '):'叫分后揭示 3 张';$('bidPanel').style.display=state.phase==='bid'?'block':'none';$('pass').disabled=state.phase!=='play'||!state.lastPlay||state.turn!=='你';$('play').disabled=state.phase!=='play'||state.turn!=='你';$('hint').disabled=state.phase!=='play';$('stateNote').textContent=`state: ${state.phase} · hand=${state.hand.length} · selected=${state.selected.length} · 发牌已按点数降序/花色稳定排序`;$('p0').querySelector('small').textContent=`${state.landlord==='你'?'地主':'农民'} / ${state.hand.length} 张`;$('p1').querySelector('small').textContent=`${state.landlord==='AI·东'?'地主':state.phase==='bid'?'待机':'农民'} / ${state.ai1.length} 张`;$('p2').querySelector('small').textContent=`${state.landlord==='AI·西'?'地主':state.phase==='bid'?'待机':'农民'} / ${state.ai2.length} 张`;
    const h=$('hand');h.innerHTML='';state.hand.forEach(c=>{const b=document.createElement('button');b.className=`card ${c.color} ${state.selected.includes(c.id)?'selected':''} ${state.hint.includes(c.id)?'hint':''}`;b.setAttribute('role','listitem');b.setAttribute('aria-label',`${c.rank}${c.suit}${state.hint.includes(c.id)?'，提示牌':''}`);b.innerHTML=`<span class="rank">${c.rank}</span><span class="suit">${c.suit}</span><span class="sr-only">${state.hint.includes(c.id)?'提示推荐':''}</span>`;b.onclick=()=>selectCard(c);b.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();selectCard(c)}};h.appendChild(b)});$('settlement').classList.toggle('show',state.phase==='settled');$('settlementText').textContent=state.message;$('landlordTeam').textContent=state.landlord||'待定';$('finalScore').textContent=state.score;document.querySelectorAll('[data-bid]').forEach(b=>b.disabled=state.phase!=='bid'||state.bidTurn!=='你');renderMessage();window.__DDZ_STATE__=state;window.__DDZ_TEST__={classify:typeOf,canBeat:beats,handUnchanged:()=>state.hand.length};
  }
  $('newGame').onclick=newGame;$('hint').onclick=hint;$('pass').onclick=pass;$('play').onclick=play;document.querySelectorAll('[data-bid]').forEach(b=>b.onclick=()=>bid(Number(b.dataset.bid)));load();
})();
</script>
</body>
</html>''';
}
~~~
