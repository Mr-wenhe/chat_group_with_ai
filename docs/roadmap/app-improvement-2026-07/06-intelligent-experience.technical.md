# 阶段 06 技术方案：记忆、搜索与文档智能

状态：方向提议；实施前应按 06A/06B/06C 拆分  
对应需求：`06-intelligent-experience.requirements.md`

## 1. 共同架构原则

- 消息、记忆和原始附件是事实来源；全文/文档索引均可删除和重建。
- 所有知识片段具有稳定 source reference，避免回答无法追溯。
- 删除/导入/恢复通过阶段 02 和 04 的生命周期服务通知索引更新。
- 检索和文档处理在 UI 之外运行，支持进度、取消和失败恢复。

## 2. 06A 记忆管理设计

### 建议模型增强

在现有 GroupMemory/CharacterMemory 之上增加展示和控制元数据：

- memory item id/type/content
- conversationId/characterId
- source message IDs 或 summary run ID
- createdAt/updatedAt
- pinned/suppressed
- 可选 confidence

短期可先用 DTO 解析现有分层字段并提供编辑；长期建议从“大字符串摘要”迁移为条目化记忆，生成 prompt 时再压缩组合。

### 服务

- `MemoryRepository`
- `MemoryMutationService`
- `MemoryPromptSelector`
- `MemoryAuditViewModel`

删除必须同时处理 legacy `AICharacter.memorySummary` 和 checkpoint，防止旧内容重新出现。

## 3. 06B 全局搜索设计

建立本地 `MessageSearchIndex`，首版可采用规范化 token + 倒排列表或适合当前平台的嵌入式全文索引库。引入依赖前必须验证 Flutter 3.24 和各平台构建兼容。

接口：

- `indexMessage/update/delete`
- `rebuild(progress, cancelToken)`
- `query(text, filters, limit, cursor)`
- `status/clear`

搜索结果保存 messageId/conversationId，不复制完整消息作为事实。跳转使用阶段 03 的 `loadAround(messageId)`。

## 4. 06C 文档理解设计

### 处理流水线

1. MIME/扩展名与文件签名校验。
2. 解析器提取结构化内容。
3. 文本规范化和敏感大小限制。
4. 按页/段落/工作表分块。
5. 建立 document chunk index。
6. 查询时检索相关片段并生成带 source reference 的 prompt。

### 核心类型

- `DocumentRecord`
- `DocumentChunk`
- `SourceLocation`（page/sheet/paragraph/range）
- `DocumentProcessingJob`
- `RetrievalResult`

解析器通过接口注册，首版先实现纯文本/Markdown/JSON/CSV，再评估 PDF/DOCX/XLSX 依赖。二进制解析失败应保留附件但标记不可检索。

## 5. 实施任务

### Task 06A-1：记忆只读审计页

**验收：** 用户能看到实际注入的群/角色记忆和来源。  
**验证：** prompt selector 与 UI snapshot/widget 测试。  
**依赖：** 阶段 03、05。  
**预计范围：** M。

### Task 06A-2：记忆编辑、删除、固定和暂停

**验收：** 修改后 prompt 行为立即一致，旧摘要不回流。  
**验证：** memory lifecycle 集成测试。  
**依赖：** 06A-1。  
**预计范围：** M。

### Task 06B-1：关键词索引与重建

**验收：** 增删改和全量重建一致；5 万消息基线达标。  
**验证：** 固定大数据 fixture 和故障恢复测试。  
**依赖：** 阶段 03 分页、阶段 02 生命周期。  
**预计范围：** M/L，应先做技术 spike 再选库。

### Task 06B-2：全局搜索 UI 与跳转

**验收：** 过滤、分页结果和未加载消息跳转可用。  
**验证：** Widget/导航测试。  
**依赖：** 06B-1。  
**预计范围：** M。

### Task 06C-1：文本类文档解析

**验收：** TXT/MD/JSON/CSV 生成结构化 chunk 和来源。  
**验证：** 编码、超限、损坏和取消测试。  
**依赖：** 阶段 03 附件异步服务、阶段 02 生命周期。  
**预计范围：** M。

### Task 06C-2：检索注入与引用展示

**验收：** 只发送相关片段，回复可展示文件/片段来源。  
**验证：** fake LLM prompt 断言和引用跳转测试。  
**依赖：** 06C-1、阶段 05 Gateway。  
**预计范围：** M。

### Task 06C-3：PDF/DOCX/XLSX 解析器

**验收：** 经确认格式在目标平台 release 构建可用。  
**验证：** 标准/损坏/大文件 fixture 和跨平台 build。  
**依赖：** 依赖兼容性 spike、06C-1。  
**预计范围：** 每种格式独立 M 任务。

## 6. 检查点

- 每个子目标单独发布和验收，不等待整个阶段完成。
- 索引可清除/重建，删除生命周期测试通过。
- 文档处理具备取消、进度、限制和来源定位。
- analyze/test 与目标平台 release build 通过。

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 条目化记忆迁移改变角色表现 | 高 | 先只读审计，再双轨比较 prompt，最后切换 |
| 全文索引依赖跨平台不兼容 | 高 | 先 spike；保留纯 Dart/简化索引备选 |
| 文档解析依赖体积或原生构建过重 | 高 | 按格式插件化，文本格式先行，逐平台验证 |
| 检索片段被提示注入污染 | 高 | 外部内容标记为不可信资料，系统指令与资料边界分离 |

## 8. 开放问题

- 现有 CharacterMemory 是否直接演进为条目模型，还是新建 MemoryItem Box？
- 全文搜索需要支持哪些中文分词策略？
- 文档 chunk 是否进入备份包，还是恢复后重建？建议只备份源附件和处理元数据，索引重建。
