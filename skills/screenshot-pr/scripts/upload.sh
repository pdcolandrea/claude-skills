#!/usr/bin/env bash
# Upload every PNG under a directory tree to GitHub via `gh image` and
# emit a JSON map of relative paths to user-attachments URLs.
#
# gh image is the `drogers0/gh-image` gh CLI extension. It posts to
# the same uploads.github.com endpoint the web UI uses, returning
# https://github.com/user-attachments/assets/<uuid> URLs that inherit
# the repository's visibility — private repos stay private. Install:
#   gh extension install drogers0/gh-image
#
# Usage:
#   upload.sh <src-dir>
#     iterates <src-dir>/before/*.png and <src-dir>/after/*.png,
#     uploads each, emits {relpath: url} JSON on stdout.

set -euo pipefail

src_dir="${1:?src-dir required}"

if ! gh image --help >/dev/null 2>&1; then
  printf 'gh image extension not installed — run: gh extension install drogers0/gh-image\n' >&2
  exit 1
fi

if [ ! -d "$src_dir" ]; then
  printf 'src-dir %s does not exist\n' "$src_dir" >&2
  exit 1
fi

extract_url() {
  # gh image prints `![alt](url)` markdown — pull the URL out.
  sed -nE 's/.*\(([^)]+)\).*/\1/p' | head -n1
}

printf '{\n'
first=1
for sub in before after; do
  sub_dir="$src_dir/$sub"
  [ -d "$sub_dir" ] || continue
  for f in "$sub_dir"/*.png; do
    [ -f "$f" ] || continue
    if ! md_out="$(gh image "$f" 2>&1)"; then
      printf 'upload failed for %s:\n%s\n' "$f" "$md_out" >&2
      exit 1
    fi
    url="$(printf '%s\n' "$md_out" | extract_url)"
    if [ -z "$url" ]; then
      printf 'no URL parsed from gh image output for %s:\n%s\n' "$f" "$md_out" >&2
      exit 1
    fi
    rel="$sub/$(basename "$f")"
    if [ $first -eq 1 ]; then first=0; else printf ',\n'; fi
    printf '  "%s": "%s"' "$rel" "$url"
  done
done
printf '\n}\n'
