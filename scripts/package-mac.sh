#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/package-mac.sh path/to/Murmur.app path/to/Murmur.dmg" >&2
  exit 1
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
output_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
command -v create-dmg >/dev/null || { echo 'Install create-dmg: brew install create-dmg' >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
staging="$(mktemp -d -t murmur-dmg)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/payload"
ditto "$app_path" "$staging/payload/Murmur.app"
swift "$repo_root/scripts/dmg-background.swift" "$staging/background.png"
create-dmg --overwrite --volname Murmur \
  --window-pos 200 140 --window-size 680 440 \
  --background "$staging/background.png" \
  --icon-size 112 --text-size 14 \
  --icon Murmur.app 180 220 --hide-extension Murmur.app \
  --app-drop-link 500 220 --filesystem APFS --format ULFO \
  --no-internet-enable "$output_path" "$staging/payload"
hdiutil verify "$output_path"
