#!/bin/bash
# The original app mark, traced with a simplified small-size tail junction.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_icon="$repo_root/scripts/assets/status-bar-mark.svg"
assets="$repo_root/Murmur/Resources/Assets.xcassets/StatusBarIcon.imageset"
mkdir -p "$assets"
swift "$repo_root/scripts/render-status-icon.swift" "$source_icon" "$assets"
