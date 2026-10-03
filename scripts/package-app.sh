#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-0.1.4}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 64; }
node scripts/i18n/generate.mjs
npm --prefix web run build
arch="${CMM_ARCH:-$(uname -m)}"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || exit 64
bash scripts/swift.sh build -c release --arch "$arch" -j 4
binaries="$PWD/.build/$arch-apple-macosx/release"
app="$PWD/artifacts/package/$arch/Cloud Mac Monitor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web" "$app/Contents/Resources/LaunchDaemons"
for binary in MonitorControl MonitorAgent MonitorMaintenance; do
  install -m 755 "$binaries/$binary" "$app/Contents/MacOS/$binary"
done
install -m 644 Resources/Control-Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$app/Contents/Info.plist"
cp -R web/dist/. "$app/Contents/Resources/web/"
cp -R "$binaries/CloudMacMonitor_MonitorControl.bundle" "$app/Contents/Resources/"
cp -R ThirdParty "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp Resources/LaunchDaemons/org.cloudmacmonitor.agent.plist "$app/Contents/Resources/LaunchDaemons/"
for binary in MonitorAgent MonitorMaintenance MonitorControl; do codesign --force --sign - "$app/Contents/MacOS/$binary"; done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
archive="$PWD/artifacts/CloudMacMonitor-$version-$arch.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$PWD/artifacts/package/$arch" 'Cloud Mac Monitor.app'
(cd artifacts && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Package: %s\n' "$archive"
