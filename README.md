# Cloud Mac Monitor

A native monitoring service and static React web interface for macOS 14+, implemented from the [feature specification](specs/001-hardware-monitor/spec.md). It includes account authentication, CPU/memory/disk/network monitoring, application rankings, persistent history, LAN access with TLS pairing, and local service management. The installed app does not require Node, Homebrew, or a separate SQLite service.

The software implementation and development-machine checks are complete. Apple Silicon system-domain operation, mobile access, administrator authorization, sensor compatibility, and long-running performance still require hardware acceptance testing. The current release is a prerelease for that testing, not a claim that all release gates have passed.

## Install the prerelease

Use [v0.1.2](https://github.com/cloudshadow/mac-monitor/releases/tag/v0.1.2). The v0.1.0 installer rejected normal `/Applications` permissions and could exit before installing anything. Run the following commands using the intended ordinary service-owner account. They select the archive for Apple Silicon or Intel and verify the installer and archive checksums:

```bash
(
  set -e
  cd "$HOME"
  curl -fL https://github.com/cloudshadow/mac-monitor/releases/download/v0.1.2/install.sh -o install-0.1.2.sh
  echo "a9ae11d1b5b3590756d3e77c1fa66e32d668f7fb2209c07283ee8a61685c0f13  install-0.1.2.sh" | shasum -a 256 -c -
  case "$(uname -m)" in
    arm64) checksum=0b2b4bbc3bd8db18271ac0db14d5792dbb5d1d0a0bd04dcd8d7af2fb20a76a39 ;;
    x86_64) checksum=96005a41dc565b13529874ddc808eb69cc7916a446fc4a1f477bc7ae8fdc4cbb ;;
    *) echo "Unsupported architecture"; exit 1 ;;
  esac
  bash install-0.1.2.sh 0.1.2 https://github.com/cloudshadow/mac-monitor/releases/download/v0.1.2 "$checksum"
)
```

Review the installer before running it. Downloads run without administrator privileges; installation requests an administrator password, which Terminal does not display as you type. Wait for `Installed. Open /Applications/Cloud Mac Monitor.app; approve Gatekeeper when prompted.` before opening the app:

```bash
open "/Applications/Cloud Mac Monitor.app"
```

Open the web interface from the control window. On first local access, the page shows the account creation form directly; no separate control-window setup action is required. The app uses free ad-hoc signing; first-launch macOS approval and policy restrictions remain part of hardware acceptance testing. See the [installation guide](docs/installation.md) for installed paths, offline installation, and troubleshooting. Do not change `/Applications` permissions to work around an installer error.

The release includes arm64 and x86_64 archives, individual checksum files, and `SHA256SUMS`. Apple Silicon is the target for this release; the Intel package is provided for development diagnostics.

## Build and test

Development requires Swift 6.1+ with Xcode or Command Line Tools, Node 22.12+, and Python 3 for the integration scripts:

```bash
npm --prefix web ci
npm --prefix web run build
bash scripts/swift.sh test -j 4
node --test scripts/i18n/validate.test.mjs
python3 scripts/smoke.py
python3 scripts/lan-smoke.py
```

HTTP/TLS smoke tests use temporary data directories. They do not install system tasks or change certificate trust. Run the browser end-to-end test with:

```bash
cd web
npx playwright test
```

The browser test uses local Google Chrome by default. Set `CMM_CHROME` to use a different browser executable.

## Run a development instance

```bash
mkdir -m 700 /private/tmp/cloudmacmonitor-dev
.build/debug/MonitorAgent --data-root /private/tmp/cloudmacmonitor-dev --web-root "$PWD/web/dist"
# In another terminal, open the control window to create an account and launch the web interface.
.build/debug/MonitorControl --data-root /private/tmp/cloudmacmonitor-dev
```

Production ownership is bound by the installer to an ordinary UID and its GeneratedUID, rather than inferred from the current desktop login. The Agent runs as that user in a system LaunchDaemon. LAN access cannot be enabled before an account exists. First account creation is allowed directly from the same-origin loopback web page while no account exists; the LAN listener cannot create accounts. The compatible native setup link and device pairing tickets use the owner's Unix control channel, URL fragments, and single-use five-minute tickets. Password changes and device revocation invalidate the relevant sessions.

## Package the app

```bash
bash scripts/package-app.sh 0.1.2
CMM_ARCH=arm64 bash scripts/package-app.sh 0.1.2
```

These commands produce `artifacts/CloudMacMonitor-0.1.2-<arch>.tar.gz`, its SHA-256 checksum file, and `artifacts/package/<arch>/Cloud Mac Monitor.app`. An Intel development machine can cross-compile the Apple Silicon package, but runtime compatibility still requires testing on the target hardware.

For offline installation, copy the matching archive, checksum file, and installer to the target Mac. Review the script and run it as the intended ordinary owner; the installer requests administrator authorization:

```bash
package="artifacts/CloudMacMonitor-0.1.2-$(uname -m).tar.gz"
expected="$(awk '{print $1}' "$package.sha256")"
bash scripts/install.sh 0.1.2 --local "$package" "$expected"
```

The download installer also accepts `scripts/install.sh VERSION HTTPS_RELEASE_BASE SHA256`. Its administrator phase rechecks the archive in a root-owned staging directory, rejects traversal and links, and installs the fixed app and LaunchDaemon paths. Upgrades preserve the account, history, and previous service-start preferences. The installer accepts the standard root:admin 775 permissions on `/Applications` without changing them. It stores the actual app in `/Library/Application Support/CloudMacMonitor/Cloud Mac Monitor.app` under root-owned, non-writable parents and creates a managed entry-point link at `/Applications/Cloud Mac Monitor.app`. The LaunchDaemon and administrator tool use the protected app path directly. Other installation parents remain strictly protected. The native update checker requires a configured `ReleaseRepository`; it is not configured in the current package.

## Monitoring and history

System sampling runs every second and application scans every four seconds, independently of connected viewers. Temperature and GPU sampling use ten- and five-second intervals. System history uses tiered retention for 30 days; application summaries retain the final CPU-average, observed-memory-peak, and disk-increment top-ten union for seven days. Pausing persistence keeps recent in-memory data available. Clearing history uses a recording-epoch barrier to invalidate previous data and queries.

Temperature appears as CPU/graphics/drive peak summaries and a list of named readings in °C, with raw IDs available in details. Drive discovery includes external storage, with read-only ATA/NVMe SMART queries once per minute when the driver exposes the interface; unsupported connections or denied permissions show an unavailable reading. Unverified model mappings are not presented as verified CPU temperatures. Read-only SMC/HID/GPU interfaces may be unavailable on some models or under particular permissions. English, Simplified Chinese, and Traditional Chinese are available in the app.

## Measure the actual Agent

Build the Release Agent for the host architecture before running:

```bash
python3 scripts/runtime-benchmark.py --clients 0 --warmup 300 --duration 1800
python3 scripts/runtime-benchmark.py --clients 1 --warmup 300 --duration 1800
python3 scripts/runtime-benchmark.py --clients 3 --warmup 300 --duration 1800
```

The benchmark includes additional authenticated observer requests and curl-based viewers. It does not replace browser, mobile, physical-write-amplification, reference-machine, or 24-hour acceptance testing.

See [performance](docs/performance.md), [mobile setup](docs/mobile-setup.md), [installation validation](docs/install-validation.md), the [release checklist](docs/release-checklist.md), and [implementation status](docs/implementation-status.md) for procedures and remaining acceptance work. These detailed project documents currently include Chinese text.

## Licensing

The project license and copyright holder still require confirmation by the owner; no project license has been granted by the prerelease. Dependency licenses and notices are included in the app and listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Contribution guidance is available in [CONTRIBUTING.md](CONTRIBUTING.md).
