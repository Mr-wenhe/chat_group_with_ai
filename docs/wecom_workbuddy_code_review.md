# 企业微信 / WorkBuddy 改造 Code Review 报告

## 范围

- 聊天页企业微信视觉、气泡、时间、引用、`@`、回执、输入区与附件。
- Agentic 任务分类、WorkBuddy 规划/收尾 Prompt、文件交付回执。
- Web 附件数据 URI、打开/下载、多模态上下文与设置页平台分支。
- 新增纯函数/组件测试以及 Web 附件回归测试。

## 审查结果

| 维度 | 结论 | 证据/处置 |
|---|---|---|
| 回归 | 通过静态审查 | 未改 Hive model/provider，不需重生成 `.g.dart`；新逻辑尽量放入可单测纯函数。 |
| 资源泄漏 | 未发现新泄漏 | 未新增长生命周期 controller/subscription；视频播放继续使用原有 dispose 路径。 |
| 并发/时序 | 未改变 AI 轮次机制 | 未改 `_runAiRound`、自动聊天上限或流式取消的 subscription/completer 时序。 |
| Hive 读写 | 有界可控 | Web 使用 data URI 落库，三类附件入库前统一限制 10 MB；仍保留 base64 开销为已知低优先级风险。 |
| 空安全 | 通过 | data URI 解码失败回退本地文件；Web picker 无 bytes 时返回 null；回执文本使用 nullable 字段。 |
| Web/桌面/移动 | 平台分支明确 | Web 使用 bytes/data URI/浏览器下载；原生端使用 `File` 和 `open_filex`；未增加新依赖。 |
| 回执语义 | 已修正 | 仅当用户消息后出现 AI 消息时显示“已读”，否则“未读”；不再借用表示本机用户阅读 AI 消息的 inbox `readAt`。 |
| 任务分类 | 已修正 | 移除“总结这份”无条件触发，保留文档/文件/路径任务命中。 |
| 可访问性 | 可接受，有待校准项 | 附件删除按钮扩大并增加 Tooltip；按文档指定企微颜色实现的两处对比度待真实截图校准。 |

## 审查中发现并已修复

1. Web 待发图片使用 `Image.file(dataUri)`。
2. Web 图片/视频没有字节上限，可造成 IndexedDB 配额耗尽。
3. 所有私聊用户消息无条件显示“已读”。
4. 普通“总结这份电影”闲聊误进入 AgentRuntime。
5. Web 设置页访问原生目录 API，Web 附件读取不存在的本地路径。

## 结论

未发现 Critical 级别问题。重要审查项均已修复；`flutter analyze` 0 issue，416 项全量测试全绿，Web 与 macOS release 构建通过。Android/iOS/Windows 的环境限制详见《测试走查记录》。
