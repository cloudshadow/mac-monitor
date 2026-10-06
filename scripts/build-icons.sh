#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_icon_stage="$(mktemp -d /private/tmp/macmonitor-icons.XXXXXXXX)"
trap 'rm -rf "$task_icon_stage"' EXIT
mkdir "$task_icon_stage/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/Brand/logo.png --out "$task_icon_stage/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" Resources/Brand/logo.png --out "$task_icon_stage/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$task_icon_stage/AppIcon.iconset" -o Resources/Brand/AppIcon.icns
