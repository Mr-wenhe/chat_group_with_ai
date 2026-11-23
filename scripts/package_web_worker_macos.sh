#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/web_worker"
case " ${ARCHS:?} " in
  *' arm64 '*) primary=arm64 ;;
  *) primary=x64 ;;
esac
python3 "$repo_root/scripts/package_web_worker.py" "darwin-$primary" "$destination"
case " ${ARCHS} " in
  *' arm64 '*' x86_64 '*|*' x86_64 '*' arm64 '*)
    secondary="$repo_root/build/web_worker_x64"
    python3 "$repo_root/scripts/package_web_worker.py" darwin-x64 "$secondary"
    /usr/bin/lipo -create "$destination/node" "$secondary/node" -output "$destination/node.universal"
    mv "$destination/node.universal" "$destination/node"
    ;;
esac
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination/node"
