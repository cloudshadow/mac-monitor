#!/bin/bash
# Local G4 prototype installer. This is not the public release installer.
set -euo pipefail
if [ "$EUID" -ne 0 ] || [ -z "${SUDO_UID:-}" ] || [ "$SUDO_UID" -eq 0 ]; then
  printf '%s\n' 'Run explicitly with sudo from a normal local account after reviewing this script.' >&2
  exit 1
fi
if [ "$#" -ne 1 ]; then
  printf '%s\n' 'Usage: sudo bash scripts/install-maintenance-probe.sh "/absolute/path/Cloud Mac Monitor Probe.app"' >&2
  exit 1
fi
probe_source="$1"
case "$probe_source" in /*) ;; *) printf '%s\n' 'An absolute source bundle path is required.' >&2; exit 1 ;; esac
probe_owner=$(/usr/bin/id -nu "$SUDO_UID")
case "$probe_owner" in ''|*[!a-zA-Z0-9._-]*) printf '%s\n' 'Unsupported local account name.' >&2; exit 1 ;; esac
probe_guid=$(/usr/bin/dscl . -read "/Users/$probe_owner" GeneratedUID | /usr/bin/awk '{print $2}')
if [ -z "$probe_guid" ]; then printf '%s\n' 'Local account identity could not be verified.' >&2; exit 1; fi
probe_app='/Applications/Cloud Mac Monitor Probe.app'
probe_root='/Library/Application Support/CloudMacMonitorProbe'
probe_plist='/Library/LaunchDaemons/org.cloudmacmonitor.probe.plist'
if [ -e "$probe_app" ] || [ -L "$probe_app" ] || [ -e "$probe_root" ] || [ -L "$probe_root" ] || [ -e "$probe_plist" ] || [ -L "$probe_plist" ]; then
  printf '%s\n' 'Existing probe paths detected. Prototype installation is fresh-install only; inspect and clean up explicitly.' >&2
  exit 1
fi
# Copy first to root-owned staging; validation and all execution refer to this protected copy.
umask 077
probe_stage=$(/usr/bin/mktemp -d /private/var/tmp/cloudmacmonitor-probe.XXXXXXXX)
trap '/bin/rm -rf "$probe_stage"' EXIT
/usr/bin/ditto "$probe_source" "$probe_stage/Probe.app"
if [ -n "$(/usr/bin/find "$probe_stage/Probe.app" -type l -print -quit)" ]; then
  printf '%s\n' 'Symlinks are not accepted in the prototype bundle.' >&2; exit 1
fi
if [ -n "$(/usr/bin/find "$probe_stage/Probe.app" ! -type f ! -type d -print -quit)" ]; then
  printf '%s\n' 'Special files are not accepted in the prototype bundle.' >&2; exit 1
fi
/usr/sbin/chown -R root:wheel "$probe_stage/Probe.app"
/bin/chmod -R go-w "$probe_stage/Probe.app"
/usr/bin/codesign --verify --strict --deep "$probe_stage/Probe.app"
probe_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$probe_stage/Probe.app/Contents/Info.plist")
if [ "$probe_identifier" != 'org.cloudmacmonitor.probe.control' ]; then printf '%s\n' 'Unexpected bundle identity.' >&2; exit 1; fi
for probe_executable in MaintenanceProbe MaintenanceProbeHelper Benchmark CapabilityProbe; do
  if [ ! -f "$probe_stage/Probe.app/Contents/MacOS/$probe_executable" ] || [ ! -x "$probe_stage/Probe.app/Contents/MacOS/$probe_executable" ]; then
    printf 'Missing executable: %s\n' "$probe_executable" >&2; exit 1
  fi
done
/bin/mkdir -m 755 "$probe_root"
/bin/mkdir -m 700 "$probe_root/data"
/usr/sbin/chown "$SUDO_UID" "$probe_root/data"
/usr/bin/printf '%s\n' "ownerUid=$SUDO_UID" "ownerGeneratedUid=$probe_guid" > "$probe_root/owner.txt"
/bin/mv "$probe_stage/Probe.app" "$probe_app"
/bin/cat > "$probe_stage/probe.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.cloudmacmonitor.probe</string>
<key>UserName</key><string>$probe_owner</string>
<key>ProgramArguments</key><array>
<string>/Applications/Cloud Mac Monitor Probe.app/Contents/MacOS/Benchmark</string>
<string>--duration</string><string>86400</string>
<string>--warmup</string><string>300</string>
<string>--database</string><string>/Library/Application Support/CloudMacMonitorProbe/data/probe.sqlite</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>30</integer>
<key>ProcessType</key><string>Background</string>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>/Library/Application Support/CloudMacMonitorProbe/data/benchmark.json</string>
<key>StandardErrorPath</key><string>/Library/Application Support/CloudMacMonitorProbe/data/probe-error.log</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$probe_stage/probe.plist"
/usr/bin/install -o root -g wheel -m 644 "$probe_stage/probe.plist" "$probe_plist"
printf '%s\n' 'Probe installed without loading a system task. Open the installed probe app and explicitly choose enable to begin G4 testing.'
printf '%s\n' 'The prototype runs for 24 hours; stop it after testing. Uninstall removes only the launchd registration; app/data cleanup is manual.'
