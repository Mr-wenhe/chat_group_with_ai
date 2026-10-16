# 伴伴使用手册 · 源文件

这里放的是 `docs/伴伴使用手册.html`（面向终端用户的完整操作手册）的源文件。
**HTML 是构建产物，不要手改**——改这里，然后重新构建。

## 一条命令重建

```bash
./scripts/build_user_guide.sh
```

脚本会调 `tools/build_manual.py`，按固定章节顺序拼装 Markdown、内嵌图片，覆盖写出
`docs/伴伴使用手册.html`。

## 目录结构

| 路径 | 内容 |
|---|---|
| `chapters/` | 分章 Markdown，28 个文件 |
| `images/` | 已压缩的 JPEG（构建输入）。尺寸统一为宽 1400px |
| `tools/build_manual.py` | 构建脚本：拼装、自动编图号、base64 内嵌图片、生成目录 |
| `tools/shell.html` | HTML 外壳：样式、侧边栏、滚动高亮、移动端与打印适配 |
| `tools/mask_debug_banner.py` | 抹掉截图右上角的 Flutter 红色 DEBUG 角标 |

## 章节顺序

顺序**不靠文件名排序**，而是写死在 `tools/build_manual.py` 的 `ORDER` 列表里。
新增章节文件后必须把它加进 `ORDER`，否则不会被构建（脚本会直接报错退出）。

文件名的数字前缀只用于人工排序，不参与输出：

- `00-` 封面 + 上篇（跟着做）
- `10-` 中篇（能力详解）
- `30-` 下篇（速查与排错）

## 两个自动处理，别手工干预

**图号是自动编的。** Markdown 里图注统一写成 `*图 1：说明*`，构建时按出现顺序重排。
所以中间插图**不需要**改后面所有编号——这也是为什么你会看到很多图注都写着「图 1」。

**中篇和下篇的标题会自动降一级**，让「篇」成为目录一级、「章」成为二级。
`# 中篇 · 能力详解` / `# 下篇 · 速查与排错` 这两行是例外，它们保持一级不动
（靠 `PART_HEADING` 正则识别）。所以这两个篇标题必须出现在各自区块的**第一个文件**里。

## 加一张截图

1. 截图原图直出，别裁别压，命名为 `NN-描述.png` 放进一个临时目录
2. 抹掉 DEBUG 角标并压缩：

   ```bash
   python3 docs/user_guide_src/tools/mask_debug_banner.py 原图.png 干净.png
   sips -s format jpeg -Z 1400 -s formatOptions 82 干净.png --out docs/user_guide_src/images/NN-描述.jpg
   ```

3. 在对应章节里插入，图注写 `图 1：…`（编号随便写，构建时会被重排）：

   ```markdown
   ![替代文字](images/NN-描述.jpg)

   *图 1：这张图在说什么。*
   ```

## 依赖

- **pandoc**（`brew install pandoc`）——负责 Markdown → HTML
- **python3**——构建脚本与角标处理（图片处理用到 Pillow）
- **sips**——macOS 自带，负责缩放与转 JPEG

## 发布时会发生什么

`scripts/publish_local.sh` 在传完三个平台产物之后，会重建这份手册、提交
`docs/伴伴使用手册.html`、并把 HTML 作为 Release 附件上传（文件名
`chat_group-user-guide-vX.Y.Z.html`）。细节见该脚本里的「使用手册」一节。
