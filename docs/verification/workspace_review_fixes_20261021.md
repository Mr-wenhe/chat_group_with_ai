# 未提交改动复核与修复（2026-10-21）

范围：全部已暂存、未暂存及未跟踪代码和相关配置；逐项验证前轮 11 项发现，修复成立项及同类路径，继续复审。不提交、不发布，不操作真实 `data/`。

## 原 11 项结论

| 项目 | 结论与修复位置 | 回归覆盖 |
| --- | --- | --- |
| 1. 不同命令改写后重复验证被跳过 | 成立。`work_agent_loop_safety.dart:1063` 将动作序号纳入产物变更指纹；失败但已启动的命令同样记录可能的文件变更。 | `work_agent_loop_test.dart`，成功写入及部分失败写入后均重新验证。 |
| 2. 超大 colspan 引发无界分配 | 成立。`flutter_html_preview.dart:209` 限制行、列、总单元格及嵌套深度，超限展示提示。 | 超大 colspan、rowspan、嵌套深度用例。 |
| 3. 确认文字附带附件被当成纯确认 | 成立。`work_task_requirements_confirmation.dart:94` 共用确认判据拒绝带附件的消息，走原补充队列保留元数据。 | `work_task_user_checkpoint_test.dart`。 |
| 4. 用户明确改名仍保留旧嵌套 HTML 路径 | 成立。`work_contract_change.dart:149` 复用讨论侧授权语义，按补充顺序处理文件和父目录改名。 | 中英文、连续改名、否定、评估及同名后缀边界。 |
| 5. Anthropic 缓存 token 导致合法用量被拒绝 | 成立。`chat_api_protocol_support.dart:661` 汇总 input、cache creation、cache read；流式用量更新并保留未重复返回的字段。 | 原生流式/非流式经真实网关入账；分段用量。 |
| 6. resize 后断言错误要求先 click | 成立。`default_work_task_runner_usage.dart:901` 将成功 resize 作为新交互，关闭前同样要求断言。 | P8 浏览器会话测试，持久化验收证据。 |
| 7. rowspan 导致后续行列错位 | 成立。`flutter_html_preview.dart:310` 跟踪被跨行占用的列。 | 跨行后的列位置。 |
| 8. 表格单元格图片丢失 | 成立。`flutter_html_preview.dart:287` 保留安全子元素；统一 data-only 图片扩展，修复原扩展断言异常。 | 表内/表外图片、嵌套表格、宽表横向滚动。 |
| 9. 批量换模型异步完成后使用失效 context | 成立。`batch_replace_model_config.dart:60` 保存完成后再次检查 mounted。 | 保存期间卸载调用页面。 |
| 10. S8 端到端测试绕不过新完成选择门禁 | 成立，属于测试未适配。`work_mode_s8_end_to_end_test.dart:435` 等待冻结且无在途动作，再显式选择测试。 | S8 完整流程。 |
| 11. 首次活动回调先完成导致 firstTokenMs 丢失 | 成立。`default_work_task_runner_model_io.dart:236` 首次响应活动同时记录计时。 | 活动回调先于 token 的 P8 用例。 |

## 后续复审

同根路径补充处理：失败命令产生的变更、流式部分用量、表格嵌套和宽表访问。复核期间发现搜索预算测试依赖 40ms 真实时钟，在全量负载下偶发在 Provider 启动前耗尽；生产代码正确超时。测试现复用现有可控时钟，并直接断言 Planner 接收的预算及最终超时结果，取消依赖机器负载的耗时断言。

复审未发现其他有证据支持的待修复缺陷。工作区存在其他会话并发编辑；保留其修改，测试列表排除其临时创建/删除的 `tmp_*` 诊断文件。

## 校验记录

- 全量 Flutter：330 个测试入口，`flutter test --no-pub --timeout 30s --concurrency 2`；3901 通过、3 跳过、1 个上述搜索计时测试失败（修复前）。日志 `/tmp/chat_group_fix_stable_full_tests.log`。
- 修复搜索测试后重跑搜索、HTML、协议、批量模型、合同改名、用户检查点六组：89 项全部通过。日志 `/tmp/chat_group_final_recheck.log`。
- 对全量测试启动后发生变化的媒体代码补跑：`multimodal_content_test.dart`、`multimodal_content_boundary_test.dart`、`attachment_media_preview_test.dart`，21 项全部通过。日志 `/tmp/chat_group_latest_media_recheck.log`。
- 工作模式回归组此前 473 项通过，S8 的在途动作竞态随后修复并单独复验通过；命令部分失败、浏览器 resize、首活动计时均有通过记录。
- `flutter analyze`：无错误或警告；`api_bundle_export_test.dart` 有两条既有 `prefer_const_constructors` 信息。
- `git diff --check` 通过；`xcrun swiftc -frontend -parse macos/Runner/MainFlutterWindow.swift` 通过。

未执行原生完整构建、真机 WebKit 操作、真实供应商请求或自动安装验收；3 项跳过仍未覆盖。修复搜索测试后未再次完整运行全部 330 个入口，全量结果与修复后的定向结果分别记录，不能视为一次全绿全量运行。
