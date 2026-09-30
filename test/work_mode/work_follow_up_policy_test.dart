import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = WorkFollowUpPolicy();

  test('explicit current/previous/same wording targets structured artifact',
      () {
    for (final request in const [
      '请修改当前文件',
      '把上次的结果修复一下',
      'Please revise the same file',
    ]) {
      final decision = policy.resolve(
        request: request,
        lastArtifactPaths: const ['/workspace/report.md'],
      );
      expect(decision.kind, WorkFollowUpKind.reviseArtifact);
      expect(decision.artifactPath, '/workspace/report.md');
      expect(decision.autoRenameIfExists, isFalse);
    }
  });

  test('colloquial edit wording still targets the original artifact', () {
    final decision = policy.resolve(
      request: '帮我改一下当前文件',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('equivalent same-file wording also targets the original artifact', () {
    final decision = policy.resolve(
      request: '请修改相同文件',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('bare optimization targets the only existing artifact by default', () {
    final decision = policy.resolve(
      request: '优化一下',
      lastArtifactPaths: const ['/workspace/report.md'],
    );

    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('new-file wording allows collision rename but revision never does', () {
    final newFile = policy.resolve(
      request: '新建一个 report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(newFile.kind, WorkFollowUpKind.newArtifact);
    expect(newFile.autoRenameIfExists, isTrue);

    final revision = policy.resolve(
      request: '修改 report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(revision.kind, WorkFollowUpKind.reviseArtifact);
    expect(revision.autoRenameIfExists, isFalse);
  });

  test('重新生成 continues the existing artifact instead of creating a file', () {
    final decision = policy.resolve(
      request: '重新生成',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.continueTask);
    expect(decision.artifactPath, isNull);
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('design-and-implement wording is recognized as a new artifact', () {
    final decision = policy.resolve(
      request: '设计并实现一个 html 教师节贺卡',
      lastArtifactPaths: const ['/workspace/flight-chess.html'],
    );

    expect(decision.kind, WorkFollowUpKind.newArtifact);
    expect(decision.autoRenameIfExists, isTrue);
  });

  test('relative and resolved copies of one artifact are not ambiguous', () {
    final decision = policy.resolve(
      request: '请修改当前文件',
      lastArtifactPaths: const [
        '/workspace/conversations/group-a/report.md',
        'report.md',
      ],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/conversations/group-a/report.md');
  });

  test('an explicit absolute path is a revision target', () {
    final decision = policy.resolve(
      request: '请修复 /workspace/report.md',
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('an explicit full path wins over a basename-only checkpoint', () {
    final decision = policy.resolve(
      request: '请修改 /workspace/report.md',
      lastArtifactPaths: const ['report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('an explicit absolute path with a Chinese filename is preserved', () {
    final decision = policy.resolve(
      request: '请修复 /workspace/需求文档.docx',
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/需求文档.docx');
  });

  test('a depth-only request revises the single existing artifact', () {
    // 「再详细些」是对上一份产物的深度修订，不是一句新的闲聊。它必须和
    // "优化一下"一样落到唯一产物上，否则用户的补充只会被当成普通追问排队，
    // 当前执行照旧把旧深度的文件交付出去。
    final decision = policy.resolve(
      request: '再详细些',
      lastArtifactPaths: const ['/workspace/隆中对策略.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/隆中对策略.md');
  });

  test('a depth-only request with several artifacts asks for the target', () {
    final decision = policy.resolve(
      request: '内容再详细些',
      lastArtifactPaths: const [
        '/workspace/a.md',
        '/workspace/b.md',
      ],
    );
    expect(decision.kind, WorkFollowUpKind.clarification);
  });

  test('depth adjectives do not authorize overwriting during inspection', () {
    for (final request in [
      '详细阅读当前文件',
      '详细解释 /workspace/report.md',
      'Explain in more detail what /workspace/report.md does',
    ]) {
      final decision = policy.resolve(
        request: request,
        lastArtifactPaths: const ['/workspace/report.md'],
      );
      expect(decision.kind, WorkFollowUpKind.continueTask, reason: request);
      expect(decision.artifactPath, isNull);
    }
  });

  test('depth wording in a new deliverable does not revise the old artifact',
      () {
    for (final request in [
      '新建一份详细报告',
      '生成一份内容丰富的个人主页 html',
      'Create a new report with more detail',
    ]) {
      final decision = policy.resolve(
        request: request,
        lastArtifactPaths: const ['/workspace/old.md'],
      );
      expect(decision.kind, WorkFollowUpKind.newArtifact, reason: request);
      expect(decision.autoRenameIfExists, isTrue);
      expect(decision.artifactPath, isNull);
    }
  });

  test('a brand-new deliverable is still not a depth revision', () {
    final decision = policy.resolve(
      request: '再生成一份个人主页的 html',
      lastArtifactPaths: const ['/workspace/隆中对策略.md'],
    );
    expect(decision.kind, WorkFollowUpKind.newArtifact);
  });

  test('a new deliverable derived from a referenced artifact is not a revision',
      () {
    // 「生成一份 html……优化……这个 docx」里同时出现新建动词、程度词和来源指代。
    // 指代的是**来源材料**，不是要覆盖的目标；把它当成修订请求会让分类器去问
    // "要修改哪个旧文件"，而这个问题对"生成新文件"的请求没有答案。
    for (final request in const [
      '根据这个docx 再帮我生成一份html 使用相关前端技能 优化，内容就是这个 word文档的内容',
      '按这份报告再生成一个网页，顺便优化排版',
      'Generate a new html from this docx and polish the layout',
    ]) {
      final decision = policy.resolve(
        request: request,
        lastArtifactPaths: const [
          '/workspace/量子力学研究报告.md',
          '/workspace/量子力学研究报告.docx',
        ],
      );
      expect(decision.kind, WorkFollowUpKind.newArtifact, reason: request);
      expect(decision.artifactPath, isNull, reason: request);
      expect(decision.autoRenameIfExists, isTrue, reason: request);
    }
  });

  test('a new deliverable that also names a revision target keeps the target',
      () {
    // 新建词与真正的修订动词同时出现时，修订动词描述的仍是既有产物，
    // 不能因为「生成」一词就把目标丢掉。
    final decision = policy.resolve(
      request: '生成一个副本，并修改 /workspace/report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/report.md');
  });

  test('manner wording without a new-file verb still asks which artifact',
      () {
    final decision = policy.resolve(
      request: '优化一下排版',
      lastArtifactPaths: const [
        '/workspace/a.md',
        '/workspace/b.md',
      ],
    );
    expect(decision.kind, WorkFollowUpKind.clarification);
  });

  test('uses the failed command script for an unambiguous repair follow-up',
      () {
    final decision = policy.resolve(
      request: '请修复之前的 PPT 转换问题',
      lastArtifactPaths: const [
        '/workspace/催眠心理学报告.md',
        '/workspace/create_lucid_dream_ppt.py',
      ],
      failedArtifactPath: '/workspace/create_lucid_dream_ppt.py',
    );

    expect(decision.kind, WorkFollowUpKind.reviseArtifact);
    expect(decision.artifactPath, '/workspace/create_lucid_dream_ppt.py');
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('does not guess between same-named failed command scripts', () {
    final decision = policy.resolve(
      request: '请修复之前的转换问题',
      lastArtifactPaths: const [
        '/workspace/first/create_ppt.py',
        '/workspace/second/create_ppt.py',
      ],
      failedArtifactPath: 'create_ppt.py',
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(decision.artifactPath, isNull);
    expect(decision.clarificationQuestion, contains('文件路径'));
  });

  test('ambiguous target asks one precise question and pauses', () {
    final decision = policy.resolve(
      request: '请修改当前文件',
      lastArtifactPaths: const [
        '/workspace/report.md',
        '/workspace/summary.md',
      ],
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(decision.artifactPath, isNull);
    expect(decision.clarificationQuestion, isNotNull);
    expect(decision.clarificationQuestion!.split('？').length - 1, 1);
  });

  test('missing structured artifact never falls back to global recent files',
      () {
    final decision = policy.resolve(
      request: '修改上次文件',
      lastArtifactPaths: const [],
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(decision.artifactPath, isNull);
    expect(decision.clarificationQuestion, contains('文件路径'));
    expect(decision.clarificationOptions, isEmpty);
  });

  test('ambiguous target carries numbered options the user can pick', () {
    final decision = policy.resolve(
      request: '请修改当前文件',
      lastArtifactPaths: const [
        '/workspace/report.md',
        '/workspace/summary.md',
      ],
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(
      decision.clarificationOptions.map((option) => option.index),
      <int>[1, 2],
    );
    // 选项带的是可执行的完整路径：同名候选（不同目录下的 report.md）只有靠
    // 路径才能区分，点选必须比手打文件名更精确。
    expect(
      decision.clarificationOptions.map((option) => option.path),
      <String>['/workspace/report.md', '/workspace/summary.md'],
    );
  });

  test('the question lists every candidate in option order', () {
    final decision = policy.resolve(
      request: '请修改当前文件',
      lastArtifactPaths: const [
        '/workspace/report.md',
        '/workspace/summary.md',
      ],
    );

    final question = decision.clarificationQuestion!;
    // 清单与选项一一对应：用户读到第几条，就该点到第几个按钮。
    expect(question, contains('1. report.md'));
    expect(question, contains('2. summary.md'));
    // 序号是能用的答复形态之一，文案里不写，用户就只能照着抄文件名。
    expect(question, contains('序号'));
    expect(
      question.indexOf('1. report.md'),
      lessThan(question.indexOf('2. summary.md')),
    );
  });

  test('an answer that names an option by its number picks that option', () {
    const options = <WorkFollowUpOption>[
      WorkFollowUpOption(index: 1, path: '/workspace/report.md'),
      WorkFollowUpOption(index: 2, path: '/workspace/summary.md'),
    ];

    for (final answer in const [
      '1',
      ' 1 ',
      '1.',
      '第1个',
      '选1',
      '选择第 1 项',
      '"1"',
      '１',
    ]) {
      expect(
        WorkFollowUpOption.selectedBy(options, answer)?.path,
        '/workspace/report.md',
        reason: '「$answer」应当被读成清单第 1 项',
      );
    }
    expect(
      WorkFollowUpOption.selectedBy(options, '第2个')?.path,
      '/workspace/summary.md',
    );
  });

  test('an answer that is not a bare option number picks nothing', () {
    const options = <WorkFollowUpOption>[
      WorkFollowUpOption(index: 1, path: '/workspace/report.md'),
      WorkFollowUpOption(index: 2, path: '/workspace/summary.md'),
    ];

    for (final answer in const [
      '',
      '0',
      '3', // 清单只有两项：越界序号不是选择，是打错
      'report.md',
      '/workspace/report.md',
      '生成3个文件',
      '第2个方案改成 docx',
      '1 2',
    ]) {
      expect(
        WorkFollowUpOption.selectedBy(options, answer),
        isNull,
        reason: '「$answer」不是点选清单某一项',
      );
    }
  });

  test('same-named candidates stay distinguishable in the question list', () {
    final decision = policy.resolve(
      request: '请修复之前的转换问题',
      lastArtifactPaths: const [
        '/workspace/first/create_ppt.py',
        '/workspace/second/create_ppt.py',
      ],
      failedArtifactPath: 'create_ppt.py',
    );

    expect(decision.kind, WorkFollowUpKind.clarification);
    expect(
      decision.clarificationOptions.map((option) => option.path),
      <String>['/workspace/first/create_ppt.py', '/workspace/second/create_ppt.py'],
    );
  });

  test('ordinary follow-up remains a normal continuation', () {
    final decision = policy.resolve(
      request: '继续检查错误并给我结论',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.continueTask);
    expect(decision.autoRenameIfExists, isFalse);
  });

  test('a file path without an explicit revision verb is not overwritten', () {
    final decision = policy.resolve(
      request: '请查看 report.md',
      lastArtifactPaths: const ['/workspace/report.md'],
    );
    expect(decision.kind, WorkFollowUpKind.continueTask);
    expect(decision.artifactPath, isNull);
    expect(decision.autoRenameIfExists, isFalse);
  });
}
