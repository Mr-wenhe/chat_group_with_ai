#!/usr/bin/env bash
# ============================================================================
# build_user_guide.sh — 重建 docs/伴伴使用手册.html
# ----------------------------------------------------------------------------
# 源文件在 docs/user_guide_src/（分章 Markdown + 压缩图 + 构建脚本）。
# HTML 是构建产物，改内容请改源文件再跑本脚本。
#
# 用法：
#   ./scripts/build_user_guide.sh
#
# 依赖：pandoc、python3。缺一不可，缺了会直接报错退出而不是产出半成品。
# ============================================================================

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

src_dir="${repo_root}/docs/user_guide_src"
out_html="${repo_root}/docs/伴伴使用手册.html"
builder="${src_dir}/tools/build_manual.py"

for tool in pandoc python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf '缺少依赖：%s。macOS 上可用 brew install %s 安装。\n' "${tool}" "${tool}" >&2
    exit 1
  fi
done

if [[ ! -f "${builder}" ]]; then
  printf '找不到构建脚本：%s\n' "${builder}" >&2
  exit 1
fi

if [[ ! -d "${src_dir}/chapters" || ! -d "${src_dir}/images" ]]; then
  printf '源目录结构不完整，期望 %s 下有 chapters/ 与 images/\n' "${src_dir}" >&2
  exit 1
fi

# 构建脚本自己会在章节缺失或图片引用不到时以非零码退出，
# 所以这里不再重复校验，直接跑。
python3 "${builder}" "${src_dir}" "${out_html}"

printf '使用手册已更新：%s\n' "${out_html}"
