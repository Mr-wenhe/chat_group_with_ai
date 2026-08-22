#!/usr/bin/env bash
# ============================================================================
# publish_local.sh — 本地构建并发布「非 Windows」3 个平台
# ----------------------------------------------------------------------------
# 混合发布模型（详见 README「发布指南」）：
#   • 本脚本在开发者本机构建  macOS / iOS / Android，并把这些产物
#     上传到 GitHub Release。
#   • Windows 由 CI（.github/workflows/release.yml）在推送 tag 后自动构建，
#     并以「幂等」方式创建 / 追加到【同一个 Release】。
#
# 使用前提：
#   1) 本机已跑通 flutter doctor（macOS + iOS + Android 工具链齐全）。
#   2) 已登录 gh CLI：gh auth login（需有仓库写权限）。
#   3) 已提交版本号改动并【推送了 tag】，例如：
#        git tag v1.3.8 && git push origin v1.3.8
#      然后再运行本脚本。
#
# 用法：
#   ./scripts/publish_local.sh 1.3.8        # 或带 v 前缀：./scripts/publish_local.sh v1.3.8
#
# 产物命名（与 CI 的 Windows 产物风格一致）：
#   release_artifacts/chat_group-macos-vX.Y.Z.zip
#   release_artifacts/chat_group-ios-app-vX.Y.Z.zip
#   release_artifacts/chat_group-android-apk-vX.Y.Z.apk
#   release_artifacts/chat_group-android-aab-vX.Y.Z.aab
# （release_artifacts/ 已在 .gitignore 中，不会入库）
# ============================================================================

set -euo pipefail

# ---- 颜色输出（非 TTY 时关闭）----
if [ -t 1 ]; then
  C_B="\033[1;34m"; C_G="\033[1;32m"; C_R="\033[1;31m"; C_Y="\033[1;33m"; C_0="\033[0m"
else
  C_B=""; C_G=""; C_R=""; C_Y=""; C_0=""
fi
log()  { echo -e "${C_B}▶${C_0} $*"; }
ok()   { echo -e "${C_G}✓${C_0} $*"; }
warn() { echo -e "${C_Y}⚠${C_0} $*"; }
err()  { echo -e "${C_R}✗${C_0} $*" >&2; }

# ---- 参数解析 ----
if [ $# -lt 1 ]; then
  err "用法: $0 <版本号>   例如: $0 1.3.8  或  $0 v1.3.8"
  exit 1
fi
RAW="$1"
VERSION="${RAW#v}"                       # 去掉可能的 v 前缀
TAG="v$VERSION"

if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  err "版本号格式应为 x.y.z，收到: $VERSION"
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v gh >/dev/null 2>&1      || { err "未找到 gh CLI，请先安装并登录 (gh auth login)"; exit 1; }
command -v flutter >/dev/null 2>&1 || { err "未找到 flutter，请确认其已在 PATH 中"; exit 1; }

# 可选：如需走代理拉取依赖，取消下面这行注释（按你本机代理端口调整）
# export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897

BUILD_NUM="$(git rev-list --count HEAD)"
ART_DIR="release_artifacts"
mkdir -p "$ART_DIR"

# ---- 备份并临时写入版本号（结束后还原）----
PUBSPEC="pubspec.yaml"
BAK="/tmp/_pubspec_bak_$$"
cp "$PUBSPEC" "$BAK"
python3 - "$VERSION" "$BUILD_NUM" <<'PY'
import re, sys
v, b = sys.argv[1], sys.argv[2]
p = "pubspec.yaml"
s = open(p, encoding="utf-8").read()
s = re.sub(r'^version: .*', f'version: {v}+{b}', s, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY
ok "已临时写入版本号 $VERSION+$BUILD_NUM 到 pubspec.yaml"

cleanup() {
  cp "$BAK" "$PUBSPEC" 2>/dev/null || true
  rm -f "$BAK" 2>/dev/null || true
  ok "已还原 pubspec.yaml"
}
trap cleanup EXIT

# ---- 构建辅助 ----
build_one() {
  local name="$1"; shift
  log "构建 $name ..."
  flutter build "$@" 2>&1 | tail -4
}

# ===== macOS =====
build_one "macOS" macos --release
MAC_APP="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -n1)"
[ -n "$MAC_APP" ] || { err "未找到 macOS .app"; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$MAC_APP" "$ART_DIR/chat_group-macos-v$VERSION.zip"
ok "macOS 已打包 → $ART_DIR/chat_group-macos-v$VERSION.zip"

# ===== iOS（未签名，产出 .app；依赖本机已有的签名/team 配置）=====
build_one "iOS" ios --release --no-codesign
IOS_APP="$(find build/ios/Release-iphoneos -maxdepth 1 -name '*.app' | head -n1)"
[ -n "$IOS_APP" ] || { err "未找到 iOS .app"; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$IOS_APP" "$ART_DIR/chat_group-ios-app-v$VERSION.zip"
ok "iOS 已打包 → $ART_DIR/chat_group-ios-app-v$VERSION.zip"

# ===== Android（APK + AAB）=====
build_one "Android APK" apk --release
"$ROOT/scripts/verify_android_release_permissions.sh" \
  build/app/outputs/flutter-apk/app-release.apk
build_one "Android AAB" appbundle --release
cp build/app/outputs/flutter-apk/app-release.apk  "$ART_DIR/chat_group-android-apk-v$VERSION.apk"
cp build/app/outputs/bundle/release/app-release.aab "$ART_DIR/chat_group-android-aab-v$VERSION.aab"
ok "Android 已打包 → $ART_DIR/chat_group-android-{apk,aab}-v$VERSION"

# ---- 发布到同一个 Release（幂等）----
log "发布到 GitHub Release $TAG ..."
if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" --title "Release $TAG" --generate-notes --verify-tag
  ok "已创建 Release $TAG"
else
  warn "Release $TAG 已存在（可能由 CI 先建），直接追加产物"
fi

gh release upload "$TAG" \
  "$ART_DIR/chat_group-macos-v$VERSION.zip" \
  "$ART_DIR/chat_group-ios-app-v$VERSION.zip" \
  "$ART_DIR/chat_group-android-apk-v$VERSION.apk" \
  "$ART_DIR/chat_group-android-aab-v$VERSION.aab" \
  --clobber
ok "3 个平台产物已上传到 $TAG"

REPO_SLUG="$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || echo "OWNER/REPO")"
echo
ok "本地发布完成！Windows 产物由 CI (release.yml) 自动构建并追加到同一 Release。"
echo -e "  ${C_B}Release:${C_0} https://github.com/$REPO_SLUG/releases/tag/$TAG"
