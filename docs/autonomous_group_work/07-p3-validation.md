# P3 文档与拟人化表达验证

日期：2026-10-13。状态：**未通过（P3 代码、真实文档渲染和自动检查已通过；真实多角色模型讨论样本与产品自然度验收未完成）**。没有把模拟请求、渲染工具测试或本文设计材料当作真实成员验收。

## 实现范围

| 范围 | 实现与调用链 |
|---|---|
| v2 实际提示入口 | 在 `WorkDiscussionRunner` 的 v2 `_request` / `_memberContext` 路径复用角色系统提示、`AgentPromptBuilder.replyGuidance` 和当前成员自己的统一记忆。每轮上下文携带接话对象、上一位成员的发言、当前未决问题、本人运行时观察、有效关系与心情、当前责任；观察只从本人收据生成，缺关系记录时不编造。协议段按讨论阶段裁剪。没有改 legacy `_buildPrompt` 或无调用者的规划提示。 |
| 群内公开表达 | 只有正文命中协议标识、编号清单或固定职业前缀时，当前成员才会收到至多一次正文改写请求。改写沿用该成员人格、记忆与接话上下文，只能替换公开正文；解析后的立场、问题、异议和责任不变，不能补造事实、执行或认可。改写失败或仍像台账时保留原话。格式信号仅用于触发清理，不参与自然度验收。 |
| 文档页图 | `workspace.document` 新增 `operation: render`，仅能渲染有权访问的当前文档页；复用已安装的 LibreOffice 和 Poppler。一次返回一页 PNG、摘要和 manifest，模型单次请求只收到一张页图。manifest 记录文档摘要、SHA-256、页数、引擎版本、字体嵌入/Unicode/CJK 覆盖及图像摘要。 |
| 使用证据 | 复用生产 runner 的成员使用流程。只有真实模型请求正文含有该次文档原文，或真实请求含有该页图 URL，才记正文/视觉观察；观察绑定成员、任务、场景、当前候选摘要、计划、校验版本、页码或原文位置。通过和失败反馈都要有来源；视觉通过要求每个文件的全页覆盖与解析字体状态，正文通过要求全部文本分块。正文角色可用 DOCX 段落位置，无视觉能力时不强制虚构页码。明确 `blocked` 可记录缺少渲染器、视觉模型或页覆盖；阻塞回执不满足通过门禁。 |

主要改动涉及 `work_discussion_v2_session.dart`、`work_discussion_v2_requests.dart`、`work_public_update_stream.dart`、`work_document_tool.dart`、`document_page_renderer.dart`、`default_work_task_runner_usage.dart`、`work_usage_feedback.dart` 及相应测试。新增的文档收据测试只验证解析和边界，不代表真实模型使用。

## 真实文件与视觉/文字检查

用 `python-docx` 生成了实际 ZIP/XML DOCX 输入，再用本机 LibreOffice 转成实际 PDF；它们是可复现的合成样本，不是用户提供的生产文档。样本含 64 行跨页表格、重复续页表头、白字遮挡的 AC-18 记录、错字“界面缩入后”和模板句“请在此处填写项目摘要”。

我逐页查看了修复前后 DOCX 和 PDF 的全部 16 张渲染页图。修复版将错字改为“界面缩放后”，把模板句替换为具体检查范围，恢复 AC-18 的可见文字，并将结论更新为“排版检查已完成，待独立角色复测后签署。”续页表头、表格边界和页 4 结论均可读。Poppler 正文读回与前后差异核对确认了文字更改；白字遮挡只能从真实页图发现，文字抽取本身仍读得到该行，未被当成视觉检查。

生成文件和工具回执：

- [修复前 DOCX](p3-evidence/generated/review-before.docx)、[修复后 DOCX](p3-evidence/generated/review-after.docx)
- [修复前 PDF](p3-evidence/generated/review-before.pdf)、[修复后 PDF](p3-evidence/generated/review-after.pdf)
- [全文读回差异](p3-evidence/generated/text-review/review-before.txt)、[修复后全文](p3-evidence/generated/text-review/review-after.txt)
- [修复前续页图](p3-evidence/generated/tool-render/before-docx/page-3.png)、[修复后续页图](p3-evidence/generated/tool-render/after-docx/page-3.png)、[修复后末页图](p3-evidence/generated/tool-render/after-pdf/page-4.png)
- 所有 DOCX/PDF 页图及对应 JSON manifest 位于 `p3-evidence/generated/tool-render/`。

16 页 manifest 均报告 4/4 页完整覆盖、CJK 字体状态 `resolved`；实际 PDF 字体为 PingFang SC，`embedded=yes`、`unicodeMap=yes`。DOCX 使用 LibreOfficeDev `26.8.0.0.alpha0 2c87e51eeaa2b413ff4ae097b2705eea1995d8e5`；PDF 页图由 Poppler `26.05.0` 渲染。样本转换使用隔离的临时 LibreOffice profile 和本机 macOS Fontconfig；未安装新依赖。

## 实际命令与结果

```sh
python3 tool/p3_documents/generate_review_corpus.py
```

结果：创建修复前后两份真实 DOCX。其后使用已安装 `soffice --headless --convert-to pdf:writer_pdf_Export`，临时 `UserInstallation` profile 将两份 DOCX 转为 PDF；设置 `FONTCONFIG_FILE=/opt/homebrew/etc/fonts/fonts.conf` 后保留 PingFang SC。

```sh
flutter test --no-pub --concurrency=1 --reporter expanded \
  test/work_mode/work_discussion_v2_test.dart \
  test/work_mode/work_public_update_stream_test.dart \
  test/work_mode/work_document_tool_test.dart \
  test/work_mode/work_document_render_transport_test.dart \
  test/work_mode/work_document_real_render_test.dart \
  test/work_mode/work_mode_s8_end_to_end_test.dart \
  test/work_mode/work_usage_document_evidence_test.dart
```

结果：退出码 0，150 项通过。覆盖 v2 当前提示路径、单次正文改写、公开更新流、文档页图/字体/单图传输、文档反馈证据与 S8 使用门禁。S8 使用确定性模型请求，只验证代码边界，不是实际产品使用。首次联跑发现一条诊断标题断言仍期待旧文案以及渲染测试缺少导入；均修正后本次联跑通过。

```sh
flutter test --no-pub --concurrency=1 --reporter expanded \
  test/work_mode/work_document_real_render_test.dart
```

结果：退出码 0，4 项通过。每个真实 DOCX/PDF 输入均逐页运行生产 `WorkDocumentTool` 与已安装渲染器，4 页各自返回一张模型格式页图、manifest 和字体检查。测试进程不调用真实视觉模型。

```sh
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed \
  lib/features/agentic/agent_prompt_builder.dart \
  lib/features/document/document_page_renderer.dart \
  lib/features/work_mode/default_work_task_runner_usage.dart \
  lib/features/work_mode/work_discussion_v2_requests.dart \
  lib/features/work_mode/work_discussion_v2_session.dart \
  lib/features/work_mode/work_document_tool.dart \
  lib/features/work_mode/work_public_update_stream.dart \
  lib/features/work_mode/work_usage_feedback.dart \
  test/work_mode/work_discussion_v2_regressions.dart \
  test/work_mode/work_document_real_render_test.dart \
  test/work_mode/work_document_render_transport_test.dart \
  test/work_mode/work_document_tool_test.dart \
  test/work_mode/work_public_update_stream_test.dart \
  test/work_mode/work_usage_document_evidence_test.dart
git diff --check
python3 - <<'PY'
from pathlib import Path
compile(Path('tool/p3_documents/generate_review_corpus.py').read_text(),
        'tool/p3_documents/generate_review_corpus.py', 'exec')
PY
flutter build macos --no-pub
```

结果：静态分析 `No issues found`；14 个 Dart 文件格式检查零改动；diff 和 Python 语法检查通过；Release `.app` 构建成功，产物为 `build/macos/Build/Products/Release/伴伴.app`（72.2 MB）。Xcode 提示 arm64/x86_64 两个 destination 并选用 arm64。首次静态分析报告 renderer 中一个缺花括号的 lint，已修复并复跑通过。首次 PDF 转换未使用 CJK Fontconfig，真实测试检测出 `substituted`；没有放宽门禁，按生产 Fontconfig 重转后四份全页复测通过。`pdftotext` 不在 shell PATH；改用已安装 Codex runtime 内的 Poppler 二进制读回正文。

## 规格对照、未检查项与风险

| 需求 | 当前结论 |
|---|---|
| v2 当前入口带人格、统一记忆、接话对象、未决问题、本人观察、关系心情和责任 | 调用链已检查；定向 v2 回归通过。 |
| 每轮不默认双模型请求，改写不改变成员立场或增加事实 | 有界触发和字段保持测试通过。模型真实输出的自然度尚无样本评价。 |
| 真 DOCX/PDF 全页渲染、字体覆盖与文字读回 | 本机真实渲染和全页视觉检查通过，证据为合成样本；未检查用户生产文档。 |
| 视觉成员实际收到页图、正文成员实际读到原文；反馈绑定本人、候选、页码/位置 | 生产路径会按实际模型请求内容生成观察，门禁有全页/全分块校验，边界与 S8 测试通过；没有在隔离真实多角色任务中采集其收据，不能算真实使用通过。 |
| 真实多角色讨论样本评估自然接话、不同风格、异议和依据 | **未完成。**当前没有独立隔离的成员模型运行环境；不能复用已安装个人工作数据来替代。 |

代码路径在“改写失败或仍像台账”时会保留原话以保护成员真实立场，所以真实模型输出仍可能出现格式化表达。正则只触发清理，不证明自然度。当前未实测视觉模型接收上限、独立角色风格差异和产品标准自然度；本报告不宣称 P3 产品验收通过。

## 继续验收所需环境

需要一个与个人任务数据隔离的临时测试组/工作目录，并为每个参与成员配置各自可用的模型（视觉成员还需真实视觉能力）。API Key 留在应用安全存储，不要发到聊天。环境就绪后再采集公开讨论、真实页图/正文请求收据、成员反馈和产品标准评审，复测修改后的当前候选；未完成前保持 P3 未通过。

## 隔离环境状态复核（2026-10-13）

只读检查确认 Release bundle `build/macos/Build/Products/Release/伴伴.app` 存在且包含可执行文件，`CFBundleIdentifier` 为 `com.example.chatGroup`，`Info.plist` 声明了 `CHAT_GROUP_TEST_DATA_DIR`。`DatabaseService` 在 macOS 仅于该环境变量指向已创建、位于系统临时目录内的真实目录时启用隔离存储，并写入其 `data` 子目录；否则走应用默认支持目录。当前应用未运行，未提供测试组 ID 或数据目录路径，因此没有可核验的组成员、模型配置或现场会话。本次没有读取默认个人 Hive 数据或凭据。该目录机制隔离应用数据，不构成 macOS 对程序本身的安全沙箱。P3 真实多角色验收仍未开始。

## 后续验收问题记录（2026-10-14）

**问题：真实视觉成员尚未证明逐页收到并检查当前候选页图。** 最近补充的文档检查者提示接线和 S8 断言，只验证提示内容到达模型调用路径；S8 使用确定性 mock，且其文档回执为阻塞状态。这些结果不能证明真实视觉模型实际收到页图、检查全部分配页或针对当前候选给出反馈。影响：P3 视觉成员使用验收未通过，不能据此签署文档视觉检查完成。恢复验收时须在隔离测试组中由成员自己的视觉模型实际接收当前候选的全部必查页图，保留可核对的请求/页码/候选证据，并完成反馈及修复后的复测。

## Computer Use 本机界面试用（2026-10-14）

当前源码执行 `flutter build macos --no-pub` 成功，构建为 `build/macos/Build/Products/Release/伴伴.app`（72.9 MB，包身份 `com.example.chatGroup`，可执行文件 `伴伴`）。桌面上存在多份相同 bundleId 的构建；按 bundleId 选择会报歧义。首次用 Release 路径绑定 CUA 时，界面出现隔离 Hive 目录中不存在的既有任务面板；没有打开任务，立即关闭。该次进程与数据路径无法可靠对应，故不作为隔离或产品验收证据。

随后从刚构建的 Release 包创建一次性临时副本，只在副本中改用 `com.example.chatGroup.cua.p3`、设置 `LSEnvironment.CHAT_GROUP_TEST_DATA_DIR` 到临时测试目录并 ad-hoc 重签。副本路径为 `/var/folders/8g/ld5ysm9x2zvc9_2y2kn6233h0000gn/T/chat-group-cua-p3-safe-l6wshfqx/伴伴-P3-隔离验收.app`，数据目录为其同级 `test-data/`（权限 `0700`）。使用 CUA 实际打开副本、查看控件树和截图，点击进入“群聊”和“设置”。再次打开后按规范化真实路径核对，当前进程打开的 32 个 Hive 文件全部位于临时 `test-data` 目录，目录外为 0；副本目前留在 API Key 设置列表。Apple 将 [LSEnvironment](https://developer.apple.com/documentation/bundleresources/information-property-list/lsenvironment?changes=l_4) 定义为 bundle 的 Launch Services 环境变量入口；这次副本验证的是 UI 可操作和临时数据路径，不是原始生产 bundleId 的启动链路，也不构成 macOS 程序沙箱。

界面实际显示：角色页“还没有 AI 角色”，群聊页“还没有群聊”，设置页 API Key 配置为 `0 / 4`；聊天配置显示“还没有 API 配置”。该设置页明确说明 macOS 将凭据写入应用数据目录内的本地 Hive 库（明文，不经系统钥匙串）。本次只进行了页面导航，没有创建角色/群聊、输入凭据或发送模型请求。CUA 页面截图留在 2026-10-14 本会话的工具结果中，未导出为仓库图片文件。结论：本机 Computer Use 已能对隔离测试副本执行实际 UI 操作；隔离副本目前没有真实角色模型、API 配置或测试群，无法继续真实多角色讨论、逐页视觉使用与反馈复测，P3 仍未通过。

## 最新隔离构建复核（2026-10-14）

提示修订后再次运行 `flutter build macos --no-pub`，退出码 0，最新 Release 产物为 72.9 MB。用新产物刷新上述隔离副本，在副本内设置 `CFBundleIdentifier=com.example.chatGroup.cua.p3`、`LSEnvironment.CHAT_GROUP_TEST_DATA_DIR` 指向同一临时测试目录后 ad-hoc 重签；`codesign --verify --deep --strict` 通过，`plutil` 核实包身份和测试目录，`stat` 核实可执行文件为 `-rwxr-xr-x`。用 CUA 按完整 appPath 启动，实际读取角色页控件树/截图、进入设置和 API Key 列表；当前停在配置列表，明确显示 `0 / 4`、聊天配置“还没有 API 配置”，角色页也没有 AI 角色。没有输入凭据或发起模型请求。

重启后的进程 `84704` 打开了 32 个 `.hive` 文件，逐项检查路径均在隔离 `test-data/` 内，目录外为 0。设置页仍提示 macOS 本地 Hive 凭据为明文、不是系统钥匙串；凭据须由用户本人决定是否在本地填入，不要发送到聊天。刷新时有一个未运行的暂存副本保留在 `refresh/`：命令安全层拒绝了 `rm -rf` 清理请求（提示不允许 `rm -f` 风格命令），因此将暂存包改为独立 bundle ID，并设置独立 `0700` 测试数据目录；它未启动，与当前验收副本不共享数据。真实模型、成员、测试群和逐成员验收仍缺，P3 继续未通过。
