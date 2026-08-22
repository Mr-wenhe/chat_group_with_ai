#!/usr/bin/env bash
# Verify that the final Android release artifact contains the permissions
# required by the production web-search transport.
set -euo pipefail

APK_PATH="${1:-build/app/outputs/flutter-apk/app-release.apk}"
if [[ ! -f "$APK_PATH" ]]; then
  echo "APK not found: $APK_PATH" >&2
  exit 1
fi

find_aapt() {
  local sdk_root="$1"
  [[ -d "$sdk_root/build-tools" ]] || return 0
  local candidate
  candidate="$(find "$sdk_root/build-tools" -type f -name aapt -perm -111 2>/dev/null | sort -V | tail -n1)"
  [[ -n "$candidate" ]] && printf '%s' "$candidate"
}

AAPT_BIN="${AAPT_BIN:-}"
if [[ -z "$AAPT_BIN" ]] && command -v aapt >/dev/null 2>&1; then
  AAPT_BIN="$(command -v aapt)"
fi

if [[ -z "$AAPT_BIN" ]] && command -v flutter >/dev/null 2>&1; then
  ANDROID_SDK_PATH="$(flutter config --machine 2>/dev/null \
    | awk -F'"' '/"android-sdk"/ { print $4; exit }')"
  if [[ -n "$ANDROID_SDK_PATH" ]]; then
    AAPT_BIN="$(find_aapt "$ANDROID_SDK_PATH")"
  fi
fi

if [[ -z "$AAPT_BIN" ]]; then
  for SDK_ROOT in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}"; do
    [[ -n "$SDK_ROOT" ]] || continue
    AAPT_BIN="$(find_aapt "$SDK_ROOT")"
    [[ -n "$AAPT_BIN" ]] && break
  done
fi

if [[ -z "$AAPT_BIN" || ! -x "$AAPT_BIN" ]]; then
  echo 'Unable to locate aapt; set AAPT_BIN or configure the Android SDK.' >&2
  exit 1
fi

PERMISSIONS="$($AAPT_BIN dump permissions "$APK_PATH")"
for REQUIRED_PERMISSION in \
  android.permission.INTERNET \
  android.permission.ACCESS_NETWORK_STATE; do
  if ! grep -Fq "$REQUIRED_PERMISSION" <<<"$PERMISSIONS"; then
    echo "Missing required release permission: $REQUIRED_PERMISSION" >&2
    exit 1
  fi
done

echo "Android release permissions verified: $APK_PATH"
