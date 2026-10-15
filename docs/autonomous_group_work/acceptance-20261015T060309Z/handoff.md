# 继续验收交接

## 当前状态

本批总体结论为 `blocked`，不是通过，也没有据此确认产品缺陷。Release App 仍在前台/运行中：

- App：`/Volumes/new_disk/work/flutter/chat_group/chat_group/build/macos/Build/Products/Release/伴伴.app`
- `bundleId`: `com.example.chatGroup`，版本 `2.1.0+225`，当前 PID `62732`。
- 专用数据根目录：`/private/var/folders/8g/ld5ysm9x2zvc9_2y2kn6233h0000gn/T/chat-group-acceptance-20261015T060309Z.0jdWc5`；应用数据位于其 `data/` 子目录。
- 隔离应用尚未建立角色/群聊/私聊；API Key 配置显示 `0 / 4`。未读取、复制或输出生产凭据。
- Automation Mode 和 DevToolsSecurity 均关闭。前者要求用户认证；未尝试绕过或启用。`appium` 不在 PATH。

## 恢复所需条件

1. 在本机应用自己的 API Key 设置界面，为专用验收数据配置已授权、可用的模型；视觉/排版角色必须使用真实支持图像的模型。不要把 Key 粘贴到对话或写入证据。
2. 在隔离数据里建立至少 3 位独立角色（协调者、制作候选、不同关注点的使用者），分别配置模型，再建立专用群聊和私聊。
3. 若要验证生产原生自动化路径，按用户现有安全入口完成必要系统认证/授权；本轮没有获得这些权限，不能把 CUA 样本操作等同于该路径。
4. 重新核对测试数据路径、PID、精确 appPath、版本和签名，然后从软件场景 S1 开始。测试任务只发布一次，按提示观察自动推进；不要手工制造使用收据或提示成员“现在试用”。
5. S1 后才进入 S2 文档、N/D/K 负例、真实 GitHub 技能的群聊/私聊复用，以及暂停/停止/空转/备份恢复检查。每轮必须保留真实候选、哈希、模型/工具关联和逐成员使用证据。

## 保留物和限制

- 不要清理隔离数据根目录或 `/tmp/chat-group-acceptance-shadow-g4ItNG`：后者是为避免覆盖仓库已有 `p3-evidence/generated/tool-render` 而创建的副本，当前渲染 manifest 的 `documentPath` 指向该处。
- 目录 `artifacts/` 中是合成文档和 renderer 输出，不含工作模式正式产物。P0 样本 App 仅是辅助桌面证据。
- 全量 Flutter 测试排除了会覆盖原证据目录的 `test/work_mode/work_document_real_render_test.dart`；该文件在隔离副本中单独运行并通过。其余全量回归最终状态见 `commands.log`。
- 若后续代码基线变化，当前构建/证据不可给新版本签字；先重建并建立新 RUN_ID。不要把这份报告当作当前 UI/模型功能已通过。
