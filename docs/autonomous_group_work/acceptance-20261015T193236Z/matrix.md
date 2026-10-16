# 阶段覆盖矩阵

本文件仅记录本次 DeepSeek 复验检查点，不能替代 11-independent-acceptance-prompt.md 要求的完整最终矩阵。

| 场景 | 当前结果 | 证据/说明 |
|---|---|---|
| 最新 DEBUG 路径、源码与 kernel 对应 | passed | PID 17076 从精确仓库路径运行；HEAD `7bd7bcd3b980cf14464db4ec4f0371bcbc8019cb`，`lib/` 生产 Dart 源无晚于 kernel 的文件；仅一个无 Git 差异的测试文件时间较新，不会进入 App。kernel SHA-256 `7f6b0683…e61eec34`，Debug 构建与严格签名验证通过。当前 dirty diff 已记录，不能把结果外推为纯 HEAD 构建 |
| 当前提交代码回归 | partial | work-discussion-v2 全套 130/130、自治提案回归 1/1、Gateway 32/32 通过；CI 口径 analyze 与 diff-check 通过。全量 Flutter 套件未跑，因为 macOS 文档测试会写既有 p3-evidence 文件 |
| 三个角色分别绑定 DeepSeek | partial | 早前只读配置检查确认 qa-coord-1015、qa-maker-1015、qa-user-1015 为 DeepSeek；最新 DEBUG 当前角色页仅可见产品经理 DeepSeek 卡及其他 SenseNova 卡，无法在无自动化权限时定位目标三人或证明任何新请求归属。用户要求本轮只用 DeepSeek；没有改配置或发起请求 |
| 模型切换后启动新 DeepSeek 工作任务 | blocked | 旧任务 ef0c1d12 的“回答问题”提醒已失效；新任务输入框 AX 值/焦点与画面不同步，指令未发送、未触发新模型请求；目标输出子目录未创建 |
| 正式决策后出现新的成员响应 | partial | 04:18 后确有新讨论与成员正文；缺模型请求 ID/provider usage，不能归因为三个 DeepSeek 角色的成功调用 |
| S1 自然讨论及方案冻结 | failed | 新成员正文在 04:21 被 v2 artifactContract/nativeBundle 校验拒绝；后续 usageAssignments 覆盖校验也拒绝，任务 04:27 用户停止 |
| 单一制作人及合格性 | not_run | qa-maker-1015 仅在旧路由文案中被推荐；本次未重新核验资格或最终定案 |
| 原生 macOS .app / ZIP 产出 | failed | S1 任务停止且获准工作目录为空，没有候选产物 |
| 每位角色实际打开并独立使用同一候选 | blocked | Automation Mode 关闭且需系统认证；无候选文件 |
| 修复、逐成员复测、自动交付 | not_run | 首轮候选不存在，流程未进入 |
| N01–N14 原生负例 | blocked | Automation Mode 未获授权且无可测试候选，条目未执行 |
| S2 / D01–D07 文档闭环 | not_run | 未提供本轮合成 DOCX/PDF 和渲染产物 |
| K01–K10 GitHub 技能 | not_run | 本轮未导入或执行技能 |
| R01–R16 / A01–A30 全项映射 | not_run | 尚未逐项重新核验；不得继承早前报告结果 |
| 用量、空转、连续修改、恢复、备份 | partial | UI 显示无进展计数到 13、task 累计 579417 Token；无当前请求账本及 provider usage，其他子项未执行 |
| 数据隔离 | blocked | 用户明确要求直接使用默认主数据路径；当前 PID 17076 已打开主 Application Support Hive。未读取 Key 内容、未删除角色/Key/历史；但不满足独立验收提示词的隔离标准 |

当前计数：passed 1；failed 2；blocked 4；partial 4；not_run 5。计数按上表 16 条汇总行统计，不是 77 项完整覆盖计数。
