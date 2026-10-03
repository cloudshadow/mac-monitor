#!/bin/bash
# Inspect this installer before running. Downloads occur without administrator privileges.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(id -u)" != 0 ]] || { echo 'Run as the intended ordinary macOS owner.' >&2; exit 64; }
[[ $# == 3 || ( $# == 4 && "$2" == --local ) ]] || { echo 'usage: install.sh VERSION HTTPS_RELEASE_BASE SHA256 | install.sh VERSION --local ARCHIVE SHA256' >&2; exit 64; }
version="$1"; base="$2"; expected="${!#}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || exit 64
[[ "$base" == --local || "$base" == https://* ]] || exit 64
architecture="$(uname -m)"
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || exit 64
stage="$(mktemp -d /private/tmp/cloudmacmonitor-download.XXXXXXXX)"
trap 'rm -rf "$stage"' EXIT
archive="CloudMacMonitor-$version-$architecture.tar.gz"
if [[ "$base" == --local ]]; then
  [[ -f "$3" && ! -L "$3" && "$(basename "$3")" == "$archive" ]] || { echo 'Local archive must match version and architecture.' >&2; exit 64; }
  [[ "$(stat -f %z "$3")" -le 134217728 ]] || exit 64
  cp "$3" "$stage/archive.tar.gz"
else
  curl --fail --location --proto '=https' --tlsv1.2 --max-time 180 --max-filesize 134217728 "$base/$archive" -o "$stage/archive.tar.gz"
fi
actual="$(shasum -a 256 "$stage/archive.tar.gz" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Checksum mismatch; nothing installed.' >&2; exit 1; }
owner_name="$(id -un)"; owner_uid="$(id -u)"
owner_guid="$(dscl /Local/Default -read "/Users/$owner_name" GeneratedUID | awk '{print $2}')"
[[ "$owner_guid" =~ ^[A-Fa-f0-9-]{36}$ && "$owner_name" =~ ^[A-Za-z0-9._-]+$ ]] || exit 1
printf 'Install %s as service owner %s (%s). Administrator access installs the app and system task.\n' "$version" "$owner_name" "$owner_uid"
# The privileged phase is a fixed script supplied on stdin. It copies the archive to a
# root-owned directory, verifies it again there, then extracts only regular app files.
sudo /bin/bash -s -- "$stage/archive.tar.gz" "$expected" "$owner_name" "$owner_uid" "$owner_guid" <<'ROOT'
set -euo pipefail
source_archive="$1"; expected="$2"; owner_name="$3"; owner_uid="$4"; owner_guid="$5"
root='/Library/Application Support/CloudMacMonitor'
app="$root/Cloud Mac Monitor.app"
public_app='/Applications/Cloud Mac Monitor.app'
job='system/org.cloudmacmonitor.agent'
plist='/Library/LaunchDaemons/org.cloudmacmonitor.agent.plist'
[[ "$owner_uid" =~ ^[0-9]+$ && "$owner_uid" != 0 && "$owner_name" =~ ^[A-Za-z0-9._-]+$ && "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || exit 1
[[ "$(id -u "$owner_name")" == "$owner_uid" && "$(dscl /Local/Default -read "/Users/$owner_name" GeneratedUID | awk '{print $2}')" == "$owner_guid" ]] || exit 1
protected_parent() {
  local current="$1"
  while [[ "$current" != / ]]; do
    [[ ! -L "$current" && "$(stat -f %u "$current")" == 0 ]] || { echo "Unsafe path: $current" >&2; exit 1; }
    local permission; permission="$(stat -f %Lp "$current")"
    (( (8#$permission & 8#022) == 0 )) || { echo "Writable installation parent: $current" >&2; exit 1; }
    current="$(dirname "$current")"
  done
}
# /Applications normally belongs to root:admin and is mode 775. It only hosts
# an entry-point link; trusted executables live under the protected root below.
[[ ! -L /Applications && -d /Applications && "$(stat -f %u /Applications)" == 0 ]] || { echo 'Unsafe Applications directory' >&2; exit 1; }
applications_mode="$(stat -f %Lp /Applications)"
applications_gid="$(stat -f %g /Applications)"
(( (8#$applications_mode & 8#002) == 0 && ((8#$applications_mode & 8#020) == 0 || applications_gid == 80) )) || { echo 'Unsafe Applications directory permissions' >&2; exit 1; }
protected_parent '/Library/Application Support'
protected_parent /Library/LaunchDaemons
[[ ! -L "$root" ]] || exit 1
if [[ ! -e "$root" ]]; then install -d -m 755 -o root -g wheel "$root"; fi
protected_parent "$root"
lock="$root/install.lock"
mkdir -m 700 "$lock" || { echo 'Installation already running, or interrupted lock requires review.' >&2; exit 1; }
root_stage="$(mktemp -d "$root/staging.XXXXXXXX")"
trap 'rm -rf "$root_stage"; rmdir "$lock"' EXIT
install -m 600 -o root -g wheel "$source_archive" "$root_stage/archive.tar.gz"
[[ "$(shasum -a 256 "$root_stage/archive.tar.gz" | awk '{print $1}')" == "$expected" ]] || exit 1
# tar output must contain only the fixed app root, with no traversal, links or special files.
tar -tzf "$root_stage/archive.tar.gz" > "$root_stage/entries"
awk 'BEGIN {ok=1} !/^Cloud Mac Monitor\.app\// {ok=0} /(^|\/)\.\.(\/|$)/ {ok=0} /\\/ {ok=0} END {exit !ok}' "$root_stage/entries"
[[ "$(wc -l < "$root_stage/entries")" -le 10000 ]] || exit 1
tar -tvzf "$root_stage/archive.tar.gz" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}'
mkdir "$root_stage/extract"
tar -xzf "$root_stage/archive.tar.gz" -C "$root_stage/extract" --no-same-owner
new_app="$root_stage/extract/Cloud Mac Monitor.app"
[[ -d "$new_app" && -z "$(find "$new_app" -type l -print -quit)" && -z "$(find "$new_app" -perm -4000 -print -quit)" ]] || exit 1
codesign --verify --deep --strict "$new_app"
for name in MonitorAgent MonitorControl MonitorMaintenance; do [[ -f "$new_app/Contents/MacOS/$name" && -x "$new_app/Contents/MacOS/$name" ]] || exit 1; done
restart=false; enabled=true; legacy=false
if [[ -L "$public_app" ]]; then
  [[ "$(stat -f %u "$public_app")" == 0 && "$(readlink "$public_app")" == "$app" ]] || { echo 'Unmanaged application entry; nothing replaced.' >&2; exit 1; }
elif [[ -e "$public_app" ]]; then
  # Only migrate a legacy bundle whose entire original code path is still protected.
  protected_parent "$public_app"
  [[ -e "$root/installation.json" && ! -e "$app" && "$(plutil -extract CFBundleIdentifier raw -o - "$public_app/Contents/Info.plist")" == org.cloudmacmonitor.control ]] || { echo 'Unmanaged or unsafe legacy app; reviewed migration required.' >&2; exit 1; }
  legacy=true
fi
old="$root/previous.app"
[[ ! -e "$old" && ! -L "$old" ]] || { echo 'Previous recovery bundle exists; inspect it before retrying.' >&2; exit 1; }
if [[ -e "$root/installation.json" ]]; then
  protected_parent "$root/installation.json"
  [[ "$(plutil -extract ownerUid raw -o - "$root/installation.json")" == "$owner_uid" && "$(plutil -extract ownerGuid raw -o - "$root/installation.json")" == "$owner_guid" ]] || { echo 'Owner migration requires an explicit reviewed migration.' >&2; exit 1; }
  installed_app="$app"
  if [[ "$legacy" == true ]]; then installed_app="$public_app"; fi
  protected_parent "$installed_app/Contents/MacOS/MonitorMaintenance"
  "$installed_app/Contents/MacOS/MonitorMaintenance" status > "$root_stage/before.json"
  enabled="$(plutil -extract bootEnabled raw -o - "$root_stage/before.json")"
  if [[ "$(plutil -extract systemEnabled raw -o - "$root_stage/before.json")" != true ]]; then enabled=false; fi
  if [[ "$enabled" == true && "$(plutil -extract running raw -o - "$root_stage/before.json")" == true ]]; then restart=true; fi
  "$installed_app/Contents/MacOS/MonitorMaintenance" stop
else
  restart=true
  for directory in data; do install -d -m 700 -o "$owner_uid" -g "$(id -g "$owner_name")" "$root/$directory"; done
fi
printf '{"ownerName":"%s","ownerUid":%s,"ownerGuid":"%s","bootEnabled":%s}\n' "$owner_name" "$owner_uid" "$owner_guid" "$enabled" > "$root_stage/installation.json"
install -m 644 -o root -g wheel "$root_stage/installation.json" "$root/installation.json"
if [[ "$legacy" == true ]]; then mv "$public_app" "$old";
elif [[ -e "$app" ]]; then protected_parent "$app"; mv "$app" "$old"; fi
mv "$new_app" "$app"
chown -R root:wheel "$app"; chmod -R go-w "$app"
protected_parent "$app/Contents/MacOS/MonitorMaintenance"
"$app/Contents/MacOS/MonitorMaintenance" installLink
sed "s/__OWNER_NAME__/$owner_name/g" "$app/Contents/Resources/LaunchDaemons/org.cloudmacmonitor.agent.plist" > "$root_stage/agent.plist"
plutil -lint "$root_stage/agent.plist"
install -m 644 -o root -g wheel "$root_stage/agent.plist" "$plist"
if [[ "$enabled" == true ]]; then launchctl enable "$job"; else launchctl disable "$job"; fi
if [[ "$restart" == true ]]; then
  if ! launchctl bootstrap system "$plist"; then
    launchctl disable "$job"
    echo 'Start failed. Service remains disabled. Previous app preserved for reviewed recovery.' >&2
    exit 1
  fi
fi
rm -rf "$old"
echo 'Installed. Open /Applications/Cloud Mac Monitor.app; approve Gatekeeper when prompted.'
ROOT
