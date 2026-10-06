#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release -j 4
app="$PWD/artifacts/Mac Monitor Probe.app"
mkdir -p "$app/Contents/MacOS"
for executable in MaintenanceProbe MaintenanceProbeHelper Benchmark CapabilityProbe; do
  install -m 755 ".build/release/$executable" "$app/Contents/MacOS/$executable"
  codesign --force --sign - "$app/Contents/MacOS/$executable"
done
install -m 644 Tools/MaintenanceProbe/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'G4 probe bundle (not installed): %s\n' "$app"
