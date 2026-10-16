#!/usr/bin/env python3
"""把分章 Markdown 组装成单页离线 HTML。

流程：
  1. 按固定顺序拼接章节，把中篇/下篇的标题降一级（让「篇」成为一级、章成为二级）
  2. 调 pandoc 生成带目录的 HTML 片段
  3. 把 <img> 换成 base64 内嵌，套上侧边栏外壳

用法: python3 build_manual.py <src_dir> <out_html>
"""

import base64
import mimetypes
import re
import subprocess
import sys
from pathlib import Path

# 章节顺序。名称里的数字前缀只用于排序，不参与最终输出。
ORDER = [
    "00-front.md",
    "00-upper-01-install.md",
    "00-upper-02-api-config.md",
    "00-upper-03-character.md",
    "00-upper-04-group.md",
    "00-upper-05-direct.md",
    "00-upper-06-websearch.md",
    "00-upper-07-workmode.md",
    "00-upper-08-after.md",
    "10-middle-01-character.md",
    "10-middle-02-api.md",
    "10-middle-03-group.md",
    "10-middle-04-roundtable.md",
    "10-middle-05-direct.md",
    "10-middle-06-realtime.md",
    "10-middle-07-voice.md",
    "10-middle-08-attachments.md",
    "10-middle-09-websearch.md",
    "10-middle-10-workmode.md",
    "10-middle-11-memory.md",
    "10-middle-12-governance.md",
    "10-middle-13-search.md",
    "10-middle-14-wecom.md",
    "30-lower-A-settings.md",
    "30-lower-B-troubleshooting.md",
    "30-lower-C-data.md",
    "30-lower-D-security.md",
    "30-lower-E-limitations.md",
]

# 这些文件里的标题整体降一级（H1→H2 …）
DEMOTE_PREFIXES = ("10-", "30-")
# 「篇」标题是目录的一级，降级时跳过它们
PART_HEADING = re.compile(r"^# (上篇|中篇|下篇) ·")
HEADING = re.compile(r"^(#{1,5}) ", re.MULTILINE)
# 图注形如 `*图 12：说明*`。编号在构建时按出现顺序重排，
# 这样中间插图不用手工改后面所有编号。
CAPTION = re.compile(r"图 \d+：")


def renumber_figures(markdown_text: str) -> str:
    counter = 0

    def repl(_match: "re.Match[str]") -> str:
        nonlocal counter
        counter += 1
        return f"图 {counter}："

    return CAPTION.sub(repl, markdown_text)



def demote(markdown: str) -> str:
    """给标题加一个 #。「篇」标题和代码围栏内的 # 不动。"""
    out = []
    in_fence = False
    for line in markdown.split("\n"):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(line)
            continue
        if not in_fence and HEADING.match(line) and not PART_HEADING.match(line):
            out.append("#" + line)
        else:
            out.append(line)
    return "\n".join(out)


def load_chapters(src: Path) -> str:
    parts = []
    for name in ORDER:
        path = src / "chapters" / name
        if not path.is_file():
            raise SystemExit(f"missing chapter: {path}")
        text = path.read_text(encoding="utf-8")
        if name.startswith(DEMOTE_PREFIXES):
            text = demote(text)
        parts.append(text.rstrip() + "\n")
    return "\n\n".join(parts)


def to_html_fragment(markdown_text: str) -> str:
    # 注意：pandoc 的 --toc 只在 --standalone 下生效，片段模式会被忽略，
    # 所以目录由下面的 build_toc 自己生成。
    result = subprocess.run(
        [
            "pandoc",
            "-f", "gfm+pipe_tables+task_lists",
            "-t", "html5",
            "--wrap=none",
        ],
        input=markdown_text,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


HEADING_TAG = re.compile(
    r'<h(?P<level>[12]) id="(?P<id>[^"]*)">(?P<text>.*?)</h(?P=level)>', re.DOTALL
)
INNER_TAG = re.compile(r"<[^>]+>")


def build_toc(fragment: str) -> str:
    """按 H1（篇）→ H2（章）两层生成侧边目录。"""
    items: list[tuple[int, str, str]] = []
    for match in HEADING_TAG.finditer(fragment):
        level = int(match.group("level"))
        anchor = match.group("id")
        text = INNER_TAG.sub("", match.group("text")).strip()
        text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
        items.append((level, anchor, text))

    if not items:
        raise SystemExit("no headings found; cannot build toc")

    out = ["<ul>"]
    open_sub = False
    for level, anchor, text in items:
        if level == 1:
            if open_sub:
                out.append("</ul></li>")
                open_sub = False
            elif len(out) > 1:
                out.append("</li>")
            out.append(f'<li><a href="#{anchor}">{text}</a>')
        else:
            if not open_sub:
                out.append("<ul>")
                open_sub = True
            out.append(f'<li><a href="#{anchor}">{text}</a></li>')
    if open_sub:
        out.append("</ul></li>")
    else:
        out.append("</li>")
    out.append("</ul>")
    return '<nav id="TOC" aria-label="目录">' + "\n".join(out) + "</nav>"



IMG_SRC = re.compile(r'<img src="([^"]+)"([^>]*?)/?>')
BLOCKQUOTE = re.compile(r"<blockquote>(.*?)</blockquote>", re.DOTALL)


def mark_warnings(html: str) -> str:
    """给含 ⚠️ 的引用块加 warn 类，样式里换成警示配色。"""

    def repl(match: "re.Match[str]") -> str:
        inner = match.group(1)
        if "⚠️" in inner:
            return f'<blockquote class="warn">{inner}</blockquote>'
        return match.group(0)

    return BLOCKQUOTE.sub(repl, html)



def inline_images(html: str, src: Path) -> tuple[str, set[str]]:
    used: set[str] = set()

    def repl(match: "re.Match[str]") -> str:
        rel = match.group(1)
        rest = match.group(2)
        path = (src / "chapters" / rel).resolve()
        if not path.is_file():
            path = (src / rel).resolve()
        if not path.is_file():
            raise SystemExit(f"image not found: {rel}")
        used.add(path.name)
        mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        return f'<img src="data:{mime};base64,{data}"{rest}>'

    return IMG_SRC.sub(repl, html), used


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = Path(sys.argv[1]).resolve()
    out_path = Path(sys.argv[2]).resolve()

    markdown_text = renumber_figures(load_chapters(src))
    fragment = to_html_fragment(markdown_text)
    toc = build_toc(fragment)
    fragment, used = inline_images(fragment, src)
    fragment = mark_warnings(fragment)

    available = {p.name for p in (src / "images").glob("*.jpg")}
    unused = sorted(available - used)

    shell = (src / "tools" / "shell.html").read_text(encoding="utf-8")
    fixed = (
        shell.replace("<!--CONTENT-->", fragment)
        .replace("<!--TOC-->", toc)
        .replace("<!--TITLE-->", "伴伴 · 使用手册")
    )
    out_path.write_text(fixed, encoding="utf-8")

    sections = toc.count("<a ")
    size_mb = out_path.stat().st_size / 1024 / 1024
    print(f"已写入 {out_path}  ({size_mb:.1f} MB)")
    print(f"目录条目 {sections} 条；内嵌图片 {len(used)} 张；素材目录 {len(available)} 张")
    if unused:
        print(f"未使用（未进 HTML）: {', '.join(unused)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
