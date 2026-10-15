# Flutter 全量复测记录

日期：2026-10-14（Asia/Shanghai）。

命令：

```text
flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only
```

第一次执行退出码 1：3,478 项通过、1 项失败、3 项按环境条件跳过。失败位于 `test/work_mode/work_discussion_v2_test.dart:255`，期望 `/Users/fengye/Desktop/chat_group_out/flight-chess`，实际为 `desktop`。

随后分别执行该用例、整份 `test/work_mode/work_discussion_v2_test.dart`，均退出码 0；整份文件 119 项通过。第二次全量命令退出码 0：3,479 项通过、3 项跳过、0 项失败。第一次失败没有复现，根因未确认，因此作为低级测试稳定性风险保留，不声称已修复。

全仓静态分析：`flutter analyze --no-pub`，退出码 0，`No issues found.`

该全量命令里的 3 项跳过为两个需要 `CHAT_GROUP_RUN_MACOS_APPIUM_TEST=1` 的服务所有权用例，以及一个需要 `CHAT_GROUP_P2_APP_PATH` 的真实产品包测试；真实产品包归档随后单独启用并通过，记录见 `macos-app-bundle-2026-10-14.md`。跳过项没有计入全量通过数。

## 公开表达提示更新后的复测

把公开对话例句标为风格参考、并补充本人操作证据约束后，曾直接用全量命令检查。运行到 `+2380 ~1 -1` 时，`不同成员真实接线：97 次读取后当前方案逐人认可` 失败：最终请求没带开发成员的稳定偏好。其后另一个 Flutter 用例等待超过 1 分钟没有新结果；为遵守仓库 30 秒单例时限，停止了该次全量命令，没有全量完成结论。

失败根因是提示变长后越过 `runWithUnifiedMemory` 的可选上下文预算，回退路径会省略个人记忆。已压缩共用发言提示、保留本人操作证据和例句仅作风格参考的约束。随后单项 97 次读取回归通过；完整 `test/work_mode/work_discussion_v2_test.dart` 119 项通过；`test/agentic/agent_prompt_builder_test.dart` 11 项通过。v2 每人提示接线用例单独通过。

为收集不依赖该项的结果，还分别运行 `work_mode_config_service_test.dart`（2 项）、`work_mode_data_clear_lifecycle_test.dart`（2 项）、`work_mode_directory_service_test.dart`（3 项）及 `work_mode_end_to_end_test.dart`（1 项），均通过。随后又完成一次最终串行全量回归：

```text
flutter test --no-pub --concurrency=1 --timeout 30s --reporter failures-only
退出码 0；3,480 项通过、3 项跳过、0 项失败。
```

这次全量执行覆盖压缩后的提示和 `native.app sessionRef` 协议变更，取代此前“提示更新后全量未完成”的结论。3 项跳过仍是上述两个 Appium 服务 opt-in 用例与一个真实产品包 opt-in 用例；它们另有服务生命周期与包归档检查，但没有创建产品 Mac2/XCTest 会话。此前路径改写断言单次失败的根因仍未确认。
