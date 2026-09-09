#!/usr/bin/env bash

set -euo pipefail

# ponytail: keep release packaging as one small, auditable shell workflow; the
# app is built by Flutter and the disk image is created by macOS hdiutil.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"

cd "${repo_root}"

package_version="$(awk -F': ' '/^version:/ {print $2; exit}' pubspec.yaml | tr -d '[:space:]')"
if [[ -z "${package_version}" ]]; then
  printf 'Unable to read the package version from pubspec.yaml.\n' >&2
  exit 1
fi

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [output-suffix]\n' "${0}" >&2
  exit 1
fi

release_products="${repo_root}/build/macos/Build/Products/Release"
output_dir="${repo_root}/dist/macos"
output_suffix="${1:-}"
if [[ -n "${output_suffix}" && ! "${output_suffix}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'Output suffix may contain only letters, numbers, dot, underscore, and hyphen.\n' >&2
  exit 1
fi
dmg_name="chat_group-${package_version}"
if [[ -n "${output_suffix}" ]]; then
  dmg_name+="-${output_suffix}"
fi
dmg_path="${output_dir}/${dmg_name}-macos.dmg"

if [[ -e "${dmg_path}" || -L "${dmg_path}" ]]; then
  printf 'Refusing to overwrite an existing DMG: %s\n' "${dmg_path}" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${temp_root}/chat_group_dmg.XXXXXX")"

cleanup() {
  # The case guard makes the only recursive removal target the directory that
  # this script created with mktemp; it can never resolve to HOME or the repo.
  case "${staging_dir:-}" in
    "${temp_root}"/chat_group_dmg.*)
      if [[ -d "${staging_dir}" ]]; then
        rm -rf -- "${staging_dir}"
      fi
      ;;
    '')
      ;;
    *)
      printf 'Refusing to clean an unexpected staging path: %s\n' "${staging_dir}" >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

flutter build macos --release

app_filename="$(tr -d '\r\n' < "${repo_root}/macos/Flutter/ephemeral/.app_filename")"
if [[ -z "${app_filename}" || "${app_filename}" != *.app ||
  "$(basename -- "${app_filename}")" != "${app_filename}" ]]; then
  printf 'Flutter did not report a valid macOS app filename.\n' >&2
  exit 1
fi

app_path="${release_products}/${app_filename}"
if [[ ! -d "${app_path}" ]]; then
  printf 'Release app not found: %s\n' "${app_path}" >&2
  exit 1
fi

mkdir -p "${output_dir}"
cp -R "${app_path}" "${staging_dir}/"
ln -s /Applications "${staging_dir}/Applications"

hdiutil create \
  -format UDZO \
  -imagekey zlib-level=9 \
  -volname "chat_group ${package_version}" \
  -srcfolder "${staging_dir}" \
  "${dmg_path}"

printf 'Release app: %s\n' "${app_path}"
printf 'DMG: %s\n' "${dmg_path}"
