# Spec: 角色性别与永久记忆面板重设计

> 状态：实施完成。2026-08-14 已完成生产 Hive Adapter、记忆范围/空状态、观察者标题、返回导航和详情返回滚动位置修复，并通过全量验收。

## Objective

为 AI 角色增加不可变的二元性别设定，并把永久记忆页面从技术审计界面改造成用户能快速理解的“某个 AI 记得谁、记得什么”。

确认后的入口行为：

- 私聊：只读展示当前 AI 对用户的全部记忆；有效记忆展开，历史状态折叠。
- 群聊：先选择当前群内的观察 AI，再查看它对用户、其他当前群成员及自身成长的记忆；允许显示跨场合来源。
- 设置：展示全部 AI 的全部记忆，并保留修正、固定、删除等管理能力。

成功意味着页面不再暴露 UUID，不再平铺角色和筛选胶囊，不再把迁移诊断正文堆在列表底部，并忠实采用已选视觉方案 2：宽屏左侧观察 AI 列表、右侧记忆列表。

## Requirements

### 角色性别

- 性别仅有“男”和“女”。
- 新建角色时必须选择，保存后不可修改。
- 编辑页、角色列表、角色详情和群成员面板显示性别。
- 性别进入角色扮演 Prompt，并覆盖群聊、私聊、主动聊天和角色成长入口。
- 旧角色执行一次通用迁移：使用名字、职业、人设 Prompt 和历史 AI 回复判断。
- 迁移允许调用已有 API 配置的 LLM；无凭据、请求失败或结果不明确时使用本地规则；仍相同时固定回退为“女”。
- 迁移结果写入 Hive，完成后不再重新判断。

### 记忆浏览与管理

- 设置入口采用顶部搜索、筛选按钮、观察 AI 导航和简洁列表。
- 观察 AI、记忆对象、来源场合选择器可搜索；显示名称而非内部 ID。
- 高级筛选放入弹窗，并解释来源、状态、类型和固定状态。
- 记忆正文在列表只显示摘要；点击进入独立详情页。
- 迁移诊断通过按钮进入独立页面。
- 私聊和群聊入口只读；设置入口允许固定、修正和删除。
- 从详情页返回后保留搜索、观察 AI 和筛选状态。

## Selected Visual Target

- Product Design ideation result 2.
- Source: `/Users/fengye/.codex/generated_images/019ff011-7069-7f30-8fd7-cd749b53a8df/exec-e9e492e2-bc37-498c-bef9-75795423eecf.png`
- Desktop target: 1440 × 1024，浅色 Material 3，克制的淡紫强调色。
- 窄屏退化为顶部观察 AI 搜索选择器，不保留固定侧栏。

## Tech Stack

- Flutter / Dart
- Riverpod
- Hive
- Dio
- 现有 Material 3 组件；不增加依赖

## Commands

- 生成 Hive 适配器：`dart run build_runner build`
- 定向测试：`flutter test test/character_gender_test.dart test/memory_management_page_test.dart test/memory_audit_filter_test.dart`
- 全量测试：`flutter test`
- 静态检查：`flutter analyze`
- 本地运行：`flutter run -d macos`

## Project Structure

- `lib/core/models/ai_character.dart`：性别模型、共享人物描述
- `lib/features/ai_character/`：创建、编辑和列表展示
- `lib/features/memory/`：迁移、筛选、列表、详情和诊断页面
- `lib/features/chat_group/`、`lib/features/direct_chat/`：Prompt 与群成员展示
- `test/`：迁移、Prompt、筛选及页面行为测试

## Code Style

```dart
String get promptIdentity => '$name，$age岁，性别${gender.label}，身份是$role';
```

- 复用现有模型和 Material 组件，不引入单实现抽象或新依赖。
- 复杂筛选保持纯函数，Widget 只负责展示和派发选择。
- 单个页面拆出详情和诊断页面，避免主页面继续增长。

## Testing Strategy

- 单元测试：性别标签、Prompt 注入、本地回退及记忆可见范围。
- Widget 测试：创建必选、编辑只读、三入口范围、搜索、筛选弹窗、详情和诊断导航。
- 兼容测试：旧 Hive 记录可读取并完成一次迁移。
- 视觉检查：以已选方案 2 为源图，对宽屏实现截图执行 Product Design QA。

## Boundaries

- Always：保留旧数据；迁移失败必须本地兜底；聊天入口只读；运行代码生成和测试。
- Ask first：新增依赖、改变性别选项、允许编辑已保存性别、改变记忆生成算法。
- Never：展示裸 UUID；后台自动删除记忆；把迁移诊断重新塞回主列表；为迁移写入或回读测试凭据。

## Implementation Tasks

- [x] 增加性别模型、Hive 字段、共享 Prompt 描述和一次迁移。
- [x] 在创建/编辑、角色列表和群成员面板展示性别。
- [x] 重构记忆页的私聊、群聊和设置范围。
- [x] 增加可搜索选择器、筛选弹窗、独立详情页和迁移诊断页。
- [x] 更新测试、生成代码、运行分析和视觉 QA。

## Success Criteria

- 新角色未选择性别不能保存，已有角色性别控件不可编辑。
- 旧角色迁移后均为男或女，且第二次启动不再次请求判断。
- 所有角色扮演 Prompt 都包含明确性别。
- 私聊不会显示其他 AI 或非用户主体记忆。
- 群聊不会显示群外主体记忆，设置入口仍可看到全部。
- 页面不显示裸 UUID，不出现下拉文字重叠或筛选胶囊墙。
- 详情与迁移诊断均为独立页面，返回后筛选状态保留。
- 定向测试、全量测试、`flutter analyze` 和设计 QA 通过。

## Open Questions

无。需求已通过逐问确认，并选择视觉方案 2。
