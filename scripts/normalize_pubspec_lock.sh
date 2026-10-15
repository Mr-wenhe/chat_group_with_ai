#!/usr/bin/env bash
# Keep `pubspec.lock` free of machine-local pub mirrors.
#
# A developer whose shell exports PUB_HOSTED_URL (the pub.flutter-io.cn mirror
# sits in this repo's author's ~/.zshrc) rewrites every hosted package's
# `description.url` on the next `flutter pub get`. CI runs without that
# variable and resolves against pub.dev, so `flutter pub get
# --enforce-lockfile` sees all hosted entries as changed and exits 65 --
# before build_runner, analyze or test ever run. That is how commit e02933f
# (2026-10-15) broke CI: it carried 181 mirror URLs into the lockfile.
#
# The packages are identical either way -- same name, version and sha256,
# verified by regenerating the lockfile against pub.dev and comparing -- so
# rewriting the host string restores exactly the file pub would have written
# against pub.dev. Only `source: hosted` entries are touched; git, path and
# sdk sources keep their URLs.
#
# Usage:
#   scripts/normalize_pubspec_lock.sh           # rewrite pubspec.lock in place
#   scripts/normalize_pubspec_lock.sh --check   # exit 1 if it would rewrite
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/pubspec.lock"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

CANONICAL="https://pub.dev"

# Hosts known to serve pub.dev content verbatim. Any other non-canonical host
# is reported instead of rewritten: we cannot know whether an unknown host
# serves byte-identical archives.
MIRROR_HOSTS=(
  "https://pub.flutter-io.cn"
)

CHECK_ONLY="false"
case "${1:-}" in
  --check) CHECK_ONLY="true" ;;
  "") ;;
  *)
    echo "usage: $SCRIPT_NAME [--check]" >&2
    exit 2
    ;;
esac

if [[ ! -f "$LOCK" ]]; then
  echo "pubspec.lock not found at $LOCK" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Buffers one `packages:` entry at a time so a mirror URL is only rewritten
# when that entry's own source is `hosted` -- a git dependency's `url:` sits at
# the same indent and must survive untouched. Messages go to /dev/stderr
# because stdout is the rewritten file.
awk -v canonical="$CANONICAL" \
    -v mirrors="${MIRROR_HOSTS[*]}" \
    -v script_name="$SCRIPT_NAME" \
    -v check_only="$CHECK_ONLY" '
  function replace_all(s, from, to,   out, i) {
    out = ""
    while ((i = index(s, from)) > 0) {
      out = out substr(s, 1, i - 1) to
      s = substr(s, i + length(from))
    }
    return out s
  }
  function flush(   i, line, before, url, count, lines) {
    if (entry == "") return
    if (index(entry, "\n    source: hosted\n") > 0) {
      before = entry
      for (i = 1; i <= n_mirrors; i++) {
        entry = replace_all(entry, mirror[i], canonical)
      }
      if (entry != before) rewritten++
      count = split(entry, lines, "\n")
      for (i = 1; i <= count; i++) {
        if (lines[i] !~ /^      url: "/) continue
        url = lines[i]
        sub(/^      url: "/, "", url)
        sub(/"$/, "", url)
        if (url != canonical) {
          if (!(url in host_count)) {
            host_order[++n_hosts] = url
            host_example[url] = pkg
          }
          host_count[url]++
        }
      }
    }
    printf "%s", entry
    entry = ""
  }
  BEGIN {
    n_mirrors = split(mirrors, mirror, " ")
    rewritten = 0
    n_hosts = 0
    pkg = ""
  }
  {
    if ($0 ~ /^  [A-Za-z0-9_]/ || $0 ~ /^[^ ]/) {
      flush()
      if ($0 ~ /^  /) {
        pkg = $0
        sub(/^  /, "", pkg)
        sub(/:$/, "", pkg)
      }
    }
    entry = entry $0 "\n"
  }
  END {
    flush()
    if (n_hosts > 0) {
      print "pubspec.lock has hosted entries from unrecognised pub hosts:" > "/dev/stderr"
      for (i = 1; i <= n_hosts; i++) {
        printf "  %s  (%d packages, e.g. %s)\n", host_order[i], host_count[host_order[i]], host_example[host_order[i]] > "/dev/stderr"
      }
      print "Refusing to rewrite: only hosts serving byte-identical content can be" > "/dev/stderr"
      print "normalised. Point PUB_HOSTED_URL at pub.dev, or add the host to" > "/dev/stderr"
      print "MIRROR_HOSTS in " script_name " if it is a mirror." > "/dev/stderr"
      exit 1
    }
    if (rewritten > 0) {
      verb = check_only == "true" ? "would normalise" : "normalised"
      printf "pubspec.lock: %s %d hosted entries to %s\n", verb, rewritten, canonical > "/dev/stderr"
    }
  }
' "$LOCK" > "$TMP"

if cmp -s "$TMP" "$LOCK"; then
  exit 0
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "pubspec.lock carries non-$CANONICAL hosts; run $SCRIPT_NAME to fix" >&2
  exit 1
fi

cat "$TMP" > "$LOCK"
