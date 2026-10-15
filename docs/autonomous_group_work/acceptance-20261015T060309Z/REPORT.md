# 独立现场验收报告

日期：2026-10-15。RUN_ID：`acceptance-20261015T060309Z`。

## 结论

**总体：blocked，不能签署验收通过。** 当前没有确认新的产品缺陷，但核心目标“群内真实 AI 成员各自讨论、制作、实际使用产物、反复修复复测并自动交付”没有发生。隔离 Release App 设置页显示 API Key `0 / 4`，角色和群聊均为空；因此没有可用模型请求、真实任务、候选或成员级使用收据。缺失环境使主场景无法开始，不应把样本 App、单测或直接渲染说成群聊工作模式已验收。

按矩阵的现场状态汇总（共 77 项）：**31 blocked、3 partial、43 not_run、0 failed、0 passed**。`partial` 仅是文档 renderer 和缺字体检测局部证据；没有 AI 成员现场通过项。

## 主要阻塞

1. **没有能执行任务的隔离模型/角色配置。** 隔离 App 的 CUA 画面显示 `2.1.0+225`、本地存储和 API Key `0 / 4`；角色页与群聊页为空。S1 软件、S2 文档、拟人化对话、逐成员实际使用、GitHub 技能真实导入/复用、usage、空转、暂停/停止、恢复和备份等产品流程均未启动。未读取或复制生产 Hive、真实凭据、聊天或钥匙串。
2. **本机原生服务能力未授权/未安装。** `automationmodetool -status` 显示 Automation Mode disabled 且需要用户认证；`DevToolsSecurity -status` 显示 disabled；`command -v appium` 未找到。没有启用/绕过系统保护或擅自启动 Appium。两个 Appium opt-in 测试因此保留 skip；CUA 对独立样本的操作不能替代生产自动化服务。
3. **截图证据有落盘缺口。** CUA 实际截图只在本次工具输出显示，API 未提供本地保存路径。当前矩阵没有把截图文件当证据；产品 AX 树只暴露窗口根容器，没有 Flutter 页面控件 selector，生产自动化路线也未验证。

## 已完成的检查

- 隔离数据根目录为 `/private/var/folders/8g/ld5ysm9x2zvc9_2y2kn6233h0000gn/T/chat-group-acceptance-20261015T060309Z.0jdWc5`，数据库在其 `data/` 下。精确 Release 窗口/进程为 `/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Release/伴伴.app`，PID `62732`，bundle ID `com.example.chatGroup`，版本 `2.1.0+225`。当前二进制 SHA-256 为 `82824c65516c19de6fea91514f5ed88abb50bac0c297e9bf8db66425682ea3ef`。
- 构建 macOS Release 成功（73.1 MB）；`codesign --verify --deep --strict --verbose=2` 通过，`.app` 在磁盘有效且满足 Designated Requirement。另把准确 Release 路径传给真实 App Bundle 打包测试，打包、验证、解包用例 1/1 通过。这些仅为构建/包验证，不是工作模式自动候选发布。
- `flutter analyze --no-pub` 无问题；格式检查 152 个 Dart 文件、0 个需要格式化；`git diff --check`、发布脚本 shell 语法、Python 工具脚本编译检查通过；Gateway `npm test` 32/32 通过。
- Flutter 回归按仓库约束保持串行及每用例 30 秒上限。主测试集（为保护已有证据而排除一个会写入仓库现有 `p3-evidence/generated/tool-render` 的渲染测试）3500 通过、3 跳过、0 失败；其中真实 App Bundle 测试原本因缺 `CHAT_GROUP_P2_APP_PATH` 跳过，已用当前 Release 精确路径单独补跑并通过 1/1；两项 Appium 所有权测试按 opt-in 保持跳过。被排除的文档渲染测试在 `/tmp/chat-group-acceptance-shadow-g4ItNG` 隔离副本运行，5/5 通过。合并重复用例后为 **3506 通过、2 跳过、0 失败**，耗时分别记录在 JSONL 日志。
- P0 独立 macOS bug/fixed 样本通过 CUA 输入、保存、关闭、重新打开并核对本地值：bug 样本暴露“界面显示已保存但文件写入错误值”，fixed 样本重启后恢复正确值。它证明样本路径可操作，不是伴伴 App 或群聊 AI 角色使用证据。
- 文档工具对合成 DOCX/PDF 四份输入渲染 16 张页图，并生成完整 manifest；缺失字体负例用例通过。设置正确的 `FONTCONFIG_FILE=/opt/homebrew/etc/fonts/fonts.conf` 后中文正常显示；初次无字体配置的诊断图出现方框字，确认不是按产品配置运行的有效结果。实际视觉检查看到合成输入中的 AC-18 空白单元格、错字和模板占位语，但没有把它们告知或归因给 AI 角色，因为本轮没有 AI 角色检查/修订。

## 代码基线与完整性

- `HEAD`：`9bbaef70752dcfe26c2b784728bae8556f2abf52`。验收开始时工作树已有大量未提交修改；`git diff --stat` 统计 133 个已跟踪文件、5495 insertions / 791 deletions，未包括 untracked 文件。验收未修改产品代码、测试或配置，仅新增本 RUN_ID 下验收材料。
- 平台：macOS 15.6 (24G84), arm64；Flutter 3.27.1、Dart 3.6.0；Xcode 16.3 (16E140)。
- 第一条全量测试进程在第 1090 个事件时为保护旧渲染证据而主动取消，不计结果。重跑版本排除副作用测试并将其放入隔离副本，过程和退出码均保留。没有提升单测 timeout。
- 代码/单测通过不代表真实模型、图像传输、角色分工、桌面操作或收据门禁已通过。矩阵按现场判据逐项记状态，评审历史 F01–F19 与第三轮 T01–T04 的关系见 [matrix.md](matrix.md)。

## 继续条件

在 App 自己的安全设置界面配置用户授权的隔离测试模型，并建立至少三位各自绑定模型的角色后，回到仍运行的同一隔离数据目录继续 S1。不要把密钥粘贴到聊天或写入验收文件。生产原生自动化若需要系统授权，应由用户通过现有认证入口完成。具体启动路径、残留目录及恢复顺序见 [handoff.md](handoff.md)。

覆盖矩阵：[matrix.md](matrix.md)；结构化索引：[evidence-index.json](evidence-index.json)；命令与日志：[commands.log](commands.log)；桌面观察：[computer/observations.md](computer/observations.md)；对话记录：[transcripts/README.md](transcripts/README.md)；产物清单：[artifacts/README.md](artifacts/README.md)。
