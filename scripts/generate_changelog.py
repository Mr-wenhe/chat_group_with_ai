#!/usr/bin/env python3
"""根据 Conventional Commits 自动生成 CHANGELOG 与版本号。

设计目标：
  - 单一实现，本地手动发布与 GitHub Actions 发布共用，避免逻辑分叉。
  - 仅依赖标准库 + 本地 git，无第三方包。

版本号累加规则（基于 commits 区间内的 Conventional Commits）：
  - 出现 feat! / fix! / BREAKING CHANGE  -> 主版本 +1 (x.0.0)
  - 否则出现 feat:                  -> 次版本 +1 (x.y.0)
  - 否则（含 fix/perf/其它）         -> 修订号 +1 (x.y.z+1)

用法示例：
  # 仅计算下一个版本号（用于 CI prepare 阶段）
  python3 scripts/generate_changelog.py --auto-version --since v1.0.0

  # 生成本次发布的 Release 说明（section.md）
  python3 scripts/generate_changelog.py --force-version 1.1.0 \
      --since v1.0.0 --section-out section.md

  # 更新仓库内的 CHANGELOG.md（幂等：已存在该版本则跳过）
  python3 scripts/generate_changelog.py --force-version 1.1.0 \
      --since v1.0.0 --changelog-out CHANGELOG.md
"""
import argparse
import os
import re
import subprocess
import sys
from datetime import date

REPO = "."

# 类型 -> 展示标题（顺序即输出顺序）
CATEGORY_TITLES = {
    "feat": "🚀 Features / 新功能",
    "fix": "🐛 Bug Fixes / 修复",
    "perf": "⚡ Performance / 性能优化",
    "refactor": "♻️ Refactor / 重构",
    "docs": "📝 Docs / 文档",
    "chore": "🔧 Chore / 杂项",
    "ci": "👷 CI / 构建",
    "build": "📦 Build / 打包",
    "style": "🎨 Style / 样式",
    "test": "✅ Test / 测试",
    "revert": "⏪ Revert / 回滚",
    "other": "📋 Other / 其他",
}
TYPE_ORDER = [
    "feat", "fix", "perf", "refactor", "docs",
    "chore", "ci", "build", "style", "test", "revert", "other",
]

# feat(scope): description   或   feat!: breaking
SUBJECT_RE = re.compile(
    r"^(?P<type>[a-zA-Z]+)(?:\((?P<scope>[^)]*)\))?(?P<break>!)?:\s*(?P<desc>.*)$"
)


def run_git(args):
    return subprocess.run(
        ["git", "-C", REPO] + args, capture_output=True, text=True, check=True
    ).stdout.strip()


def last_tag():
    out = run_git(["tag", "--sort=-v:refname"])
    return out.splitlines()[0] if out else ""


def get_commits(since, until):
    """返回 [(sha, subject, body), ...]，区间 since..until（since 为空则用 until 全量）。"""
    rng = f"{since}..{until}" if since else until
    # 提交间用 \x1e 分隔，字段用 \x1f 分隔：sha \x1f subject \x1f body
    out = run_git(["log", f"--format=%H%x1f%s%x1f%b%x1e", rng])
    commits = []
    for raw in out.split("\x1e"):
        raw = raw.strip("\n")
        if not raw.strip():
            continue
        parts = raw.split("\x1f")
        if len(parts) < 3:
            continue
        commits.append((parts[0], parts[1], parts[2]))
    return commits


def parse_commit(subject, body):
    m = SUBJECT_RE.match(subject)
    if not m:
        return ("other", "", False, subject)
    ctype = m.group("type").lower()
    scope = m.group("scope") or ""
    breaking = m.group("break") == "!" or "BREAKING CHANGE" in body
    return (ctype, scope, breaking, m.group("desc"))


def parse_version(v):
    v = v.strip().lstrip("vV")
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", v)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)


def bump_version(base, commits):
    major, minor, patch = parse_version(base)
    has_breaking = any(c[2] for c in commits)
    has_feat = any(c[0] == "feat" for c in commits)
    if has_breaking:
        return f"{major + 1}.0.0"
    if has_feat:
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def group_commits(commits):
    groups = {}
    for ctype, scope, breaking, desc in commits:
        key = ctype if ctype in TYPE_ORDER else "other"
        groups.setdefault(key, []).append((scope, breaking, desc))
    return groups


def render_section(version, commits):
    today = date.today().isoformat()
    lines = [f"## v{version} - {today}", ""]
    if not commits:
        lines.append("_本次发布无 Conventional Commits 记录。_")
        lines.append("")
        return "\n".join(lines)
    groups = group_commits(commits)
    ordered = [t for t in TYPE_ORDER if t in groups]
    for t in ordered:
        items = groups[t]
        lines.append(f"### {CATEGORY_TITLES.get(t, t)}")
        for scope, breaking, desc in items:
            prefix = "**BREAKING** " if breaking else ""
            scope_txt = f"(`{scope}`) " if scope else ""
            lines.append(f"- {prefix}{scope_txt}{desc}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def write_changelog(path, section, version):
    header = (
        "# Changelog\n\n"
        "All notable changes are documented here, following "
        "[Conventional Commits](https://www.conventionalcommits.org).\n\n"
        "---\n\n"
    )
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            existing = f.read()
        # 幂等：该版本已存在则跳过，避免重复追加
        if f"## v{version} -" in existing:
            print(f"[changelog] {path} 已包含 v{version}，跳过", file=sys.stderr)
            return
        # 去掉旧 header，仅保留历史条目
        idx = existing.find("\n## ")
        body = existing[idx + 1:] if idx != -1 else existing
        new_content = header + section + "\n" + body
    else:
        new_content = header + section + "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"[changelog] 已写入 {path}", file=sys.stderr)


def main():
    global REPO
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--since", default=None, help="起始 ref/tag（不含）。缺省取最近一个 tag")
    ap.add_argument("--until", default="HEAD")
    ap.add_argument("--force-version", default=None, help="指定版本号（用于标题展示）")
    ap.add_argument("--auto-version", action="store_true", help="仅输出累加后的版本号")
    ap.add_argument("--section-out", default=None, help="输出 Release 说明（单段）")
    ap.add_argument("--changelog-out", default=None, help="更新仓库 CHANGELOG.md（幂等）")
    args = ap.parse_args()
    REPO = args.repo

    since = args.since if args.since else last_tag()
    commits = [parse_commit(s, b) for (_, s, b) in get_commits(since, args.until)]

    # 仅计算版本号
    if args.auto_version:
        base = since.lstrip("vV") if since else "1.0.0"
        version = bump_version(base, commits)
        if "GITHUB_OUTPUT" in os.environ:
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write(f"version={version}\n")
        print(version)
        return

    base = since.lstrip("vV") if since else "1.0.0"
    version = args.force_version if args.force_version else bump_version(base, commits)
    section = render_section(version, commits)

    if args.section_out:
        with open(args.section_out, "w", encoding="utf-8") as f:
            f.write(section + "\n")
        print(f"[section] 已写入 {args.section_out}", file=sys.stderr)
    if args.changelog_out:
        write_changelog(args.changelog_out, section, version)


if __name__ == "__main__":
    main()
