# 最新 DEBUG 独立验收报告

日期：2026-10-15。RUN_ID：acceptance-20261015T101325Z。验收基准：当前工作树，HEAD 9bbaef70752dcfe26c2b784728bae8556f2abf52。

## 结论

**总体：blocked，不能签署产品验收通过。** 当前源码已重新构建为 macOS DEBUG，代码分析、重点回归、包安全测试和签名检查通过；但真实群内模型请求没有生成可供成员使用的产物。SenseNova 现场尝试多次在 300 秒无首字节超时，usage 为 0，未产出文件；当前 DEBUG 窗口又显示一条已保存配置，导致这次 GUI 的数据根不能仅凭现有观测证明隔离。按验收提示词，不能用自动化测试、P0 样本或 CUA 单独操作代替 AI 成员实际使用产物。

矩阵共 77 项：**45 blocked、7 partial、25 not_run、0 passed、0 failed**。partial 仅表示存在局部代码/渲染/包检查证据，不表示现场产品工作流通过。

## 主要发现

1. **[P1 / 环境阻塞] 真实模型没有完成一次可用响应。** 此前获准的合成群任务使用 SenseNova 的 qa-maker-1015，出现 4 次 300 秒无输出请求及后续重试；未收到 completion 内容、usage 或候选文件。这里没有证据证明是客户端 token 截断，也不能将零 usage 说成 20,480 token 被客户端消耗。单测验证当前协议请求对 OpenAI Chat Completions、Responses、Gemini 不发送固定 max-token 参数；Anthropic 仍须按协议发送必需参数。模型服务商默认值/硬上限仍存在，“不设客户端绝对上限”不等于无限生成。本轮没有可用的真实响应来核对 reasoning/completion 分项。
2. **[P1 / 隔离未证实] DEBUG GUI 显示 1 条已保存 API 配置。** 精确构建路径启动后窗口有 DEBUG 标记；设置页显示 1 个已配置项、Key 已保存但完全遮罩。虽然启动命令提供了临时 CHAT_GROUP_TEST_DATA_DIR，PID 及其实际打开文件路径未在进程退出前留存，因此无法排除启动环境未被采用或临时库已有配置。未点击测试、编辑、删除或发送任务，随后退出 App；没有读取 Key 内容。不能据此宣称本次 GUI 数据隔离已验收。
3. **[已修复 / P1 回归] “稍后处理”没有持久保存暂停标记。** 原实现只更新 updatedAt 并保存，重启恢复可能把用户明确延后的讨论重新自动启动。现在 _implDeferUserAction 同步持久化 resumeRequired=true；回归测试覆盖“重建协调器后保持暂停，只有显式 resumeByUser 才启动”。相关测试通过，当前 DEBUG 已重编。
4. **[无新增确认缺陷] 最新代码复审回归。** T01 稳定结果断言、T02 本地技能草稿试用候选、T03 DOCX 直接/样式继承字体并集、T04 冻结候选人工基线均已在当前源码中看到对应处理，并由重点测试覆盖。此结论只限代码/测试层，未形成 GUI 或真实成员证据。
5. **[安全回归] 原生 App ZIP 包内假凭据拦截。** 当前 DEBUG 包通过真实封装/校验/解包用例；签名 fixture 内加入假的 .env 和 dev_credentials.hive 后，封装拒绝并清理临时 ZIP。没有复制真实凭据，也没有改生产包。

## 当前 DEBUG 身份

- App：/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Debug/伴伴.app
- Bundle ID：com.example.chatGroup；版本：2.1.0，Build：225
- 可执行文件 SHA-256：29ef91e660e4341c75af16bf10cd4d8d7deebb9d3a248ad3eb4b47dcdc2c14ef
- Flutter kernel SHA-256：de45c8b245db3d581dceb0cc8233321460d9097429e9c2c31f5c6f66f2d1ca95
- codesign --verify --deep --strict --verbose=2：有效，满足 Designated Requirement
- 最近构建文件时间：2026-10-15 17:57 CST；本轮从仓库根目录再次执行 Debug build，退出码 0，内容 hash 未变化。
- 本轮 GUI PID：未捕获；窗口观察后已通过该 App 的 Cmd-Q 退出，按精确 bundle executable 查询未发现本次 DEBUG 进程。
- 测试数据目录：/var/folders/8g/ld5ysm9x2zvc9_2y2kn6233h0000gn/T/chat-group-debug-ui.yTG5zj。保留原样，不删除；此处现有 Hive 文件的来源及其与 UI 配置的对应关系未核实。

环境：macOS 15.6 (24G84), arm64；Flutter 3.27.1 / Dart 3.6.0；Xcode 16.3 (16E140)。工作区已有大量未提交改动，状态快照见本轮 commands.log；未提交或清理任何用户改动。

## 验证结果

- flutter analyze --no-pub：通过，无问题。
- git diff --check：通过。
- 本轮重点 Flutter 回归：301 通过、1 跳过；独立 Appium 所有权/原生断言测试 8/8 通过。
- 输出 token 协议检查 11/11 通过；输出预留边界测试 5/5 通过；当前真实 DEBUG App Bundle 封装测试 5/5 通过。
- Gateway npm test：32/32 通过。
- 前一验证轮同一当前源码完成的 Flutter 全量套件：3531 通过、3 跳过、0 失败。为避免覆盖仓库已有的 P3 文档验收证据，本轮重复全量运行在观测到用例会写入 docs/autonomous_group_work/p3-evidence/generated/tool-render 后中止；该重复运行没有完整总结，不计作本轮通过。P3 证据目录保留，未清理。
- 本轮对所有已修改 Dart 文件作只读格式检查，138 个文件中仅 test/api_config_form_capability_test.dart 被报告未格式化；这是既有用户修改文件，本轮未触碰。3 个本轮代码/测试文件及新建包安全测试格式检查通过。

## 数据保护与现场限制

本轮没有通过 UI 删除、覆盖或编辑任何角色、API Key、聊天记录；未查看 Key 原文，也未对当前 DEBUG 设置页发起连接测试。由于 UI 显示保存配置且运行 PID 路径未留证，不能对“App 完全没有读取用户数据”作无条件保证；后续测试必须先在全新临时目录启动并以 lsof 证明进程只打开该目录内的 Hive 文件，之后才可建立测试角色。

此前用户授权的测试已在原 DEBUG 数据库中留下合成群 DEBUG-QA-ExpenseLedger-1015-v2 和合成任务 c8a9a090；原暂停任务 7664a72f 与这些记录均保留，未删除、未查看正文。获批的 /tmp/chat-group-debug-acceptance.0oN8Sr/expense-ledger/round-01 仍无工作模式交付文件。不要误把这些合成记录当作成员完成讨论或已交付产物。

原生权限现场仍受前次核验的 Automation Mode disabled/需用户认证、DevToolsSecurity disabled、未安装 Appium 限制。没有绕过或擅自开启系统权限。

## 继续条件

先解决并验证隔离 DEBUG 的数据路径，再为至少三位隔离测试角色分别配置经授权且可响应的模型；角色配置、图片能力和使用者场景必须逐人可核对。不得把当前 GUI 中的配置自动用于测试。SenseNova 无响应时不应无授权地切换到其他 provider。原生桌面用例需要用户通过系统认证启用相应权限；之后从合成群的新任务开始执行，不能重放状态未知的任务。

完整结果见 [matrix.md](matrix.md)、[evidence-index.json](evidence-index.json)、[commands.log](commands.log)、[transcripts/README.md](transcripts/README.md)、[artifacts/README.md](artifacts/README.md) 和 [handoff.md](handoff.md)。
