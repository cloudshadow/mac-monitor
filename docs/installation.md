# Install Cloud Mac Monitor

## Download and install

Use the [v0.1.6 prerelease](https://github.com/cloudshadow/mac-monitor/releases/tag/v0.1.6) and the complete commands in [README: Install the prerelease](../README.md#install-the-prerelease). They download `install-0.1.6.sh`, verify its checksum, select the archive for the current architecture, and verify the archive before installation. Apple Silicon is the target platform; the Intel archive is provided for development diagnostics. macOS 14 or later is required.

Run the commands as the ordinary account that will own the monitoring service. Do not run the entire installer with `sudo`; it requests administrator authorization for its installation phase. Terminal does not show characters while you enter the password. Node, Homebrew, and development tools are not required for the installed app.

The download script must finish with:

```text
Installed. Open /Applications/Cloud Mac Monitor.app; approve Gatekeeper when prompted.
```

Then open the app:

```bash
open "/Applications/Cloud Mac Monitor.app"
```

Open the web interface from the control window. If no account exists, the local page shows the account creation form directly; you do not need a separate setup action in the control window. For phone access, continue with [mobile setup](mobile-setup.md). Installation success does not establish that mobile pairing, reboot behavior, sensors, or long-running performance have passed hardware acceptance.

## Installed paths

| Purpose | Path |
| --- | --- |
| App entry in Applications | `/Applications/Cloud Mac Monitor.app` (managed symbolic link) |
| Protected app bundle | `/Library/Application Support/CloudMacMonitor/Cloud Mac Monitor.app` |
| Account, history, and runtime data | `/Library/Application Support/CloudMacMonitor/data` |
| System LaunchDaemon | `/Library/LaunchDaemons/org.cloudmacmonitor.agent.plist` |

The service and administrator helper execute directly from the protected bundle. The installer accepts the normal root:admin `775` permissions on `/Applications` without changing them. Other installation parents must remain protected. Upgrades preserve account/history data and service-start preferences.

## Offline installation

Download the matching `CloudMacMonitor-0.1.6-arm64.tar.gz` or `CloudMacMonitor-0.1.6-x86_64.tar.gz`, its `.sha256` file, and `install.sh` from the same release. Copy them into one directory on the target Mac, review the installer, and run from that directory:

```bash
(
  set -e
  echo "e6d3d3272573ae88b3226b28b3a7dcc69a2e055007f954f0ceb2c032fbf9e57e  install.sh" | shasum -a 256 -c -
  package="CloudMacMonitor-0.1.6-$(uname -m).tar.gz"
  expected="$(awk '{print $1}' "$package.sha256")"
  bash install.sh 0.1.6 --local "$package" "$expected"
)
```

The installer checks that the archive matches the version and architecture and verifies its digest again inside protected staging before extraction.

## Troubleshooting

### `Writable installation parent: /Applications`

The v0.1.0 installer treated the normal administrator-group write permission on `/Applications` as unsafe and exited before copying the app. Download and run the v0.1.6 installer using the README commands, even if you already have a file named `install.sh`. Do not use `chmod` on `/Applications` to bypass the check.

If the error persists with the verified v0.1.6 script, an existing legacy app may have triggered the protected-path migration check. Do not delete the app or installation data as a workaround. Collect the full installer output and these read-only diagnostics for review:

```bash
shasum -a 256 "$HOME/install-0.1.6.sh"
ls -ld /Applications "/Applications/Cloud Mac Monitor.app" "/Library/Application Support/CloudMacMonitor/Cloud Mac Monitor.app"
```

The expected installer digest is `e6d3d3272573ae88b3226b28b3a7dcc69a2e055007f954f0ceb2c032fbf9e57e`. An unsafe or unmanaged legacy entry is refused rather than executing its helper.

### The app or installer file is missing

`No such file or directory` for `install-0.1.6.sh` means that file is not in the specified directory. The README commands download it into your home directory and run it there. A missing app after an installer error means installation did not complete; the error line is not a success message.

### Missing old MonitorMaintenance after uninstall

Uninstalling while preserving data leaves installation.json but removes the app. Installers through v0.1.5 mistake this for an upgrade and fail with a missing old MonitorMaintenance and Unsafe path. Use the verified v0.1.6 installer above to reinstall with the same owner. It preserves account/history data and restores the removed app and service. Do not delete the saved-data directory. A partial bundle is a separate state and remains refused for review.

### Checksum mismatch or installation/start failure

Do not continue after a checksum mismatch. Download the files again from the same release and use the matching architecture and version. For other failures, save the complete terminal output. A start failure can leave the service disabled and the previous app retained for recovery; do not assume it is running simply because the app exists.

### macOS blocks the first launch

The prerelease uses ad-hoc signing and is not notarized. Follow the approval options offered by macOS for this app; managed-device policies may prevent approval. Record the actual message for troubleshooting. Do not disable Gatekeeper globally.

For detailed administrator, launchd, recovery, and hardware checks, see [installation validation](install-validation.md).

## Temperature readings and control-window actions

Temperature uses named readings in °C and CPU/graphics/drive peak summaries. Unassigned sensor IDs remain in the list and details; an unavailable sensor is not shown as zero. Connected storage is listed as internal or external, and the Agent reads available ATA/NVMe SMART temperature interfaces once per minute. A drive or enclosure that does not expose this interface may have no readable temperature. Permission failures are shown separately. See Apple's [ATA SMART interface documentation](https://developer.apple.com/documentation/iokit/ioatasmartinterface) for the read interface used by ATA devices.

The control window displays the app version and build; the web header displays its packaged version. Service errors show diagnostic codes, and an unavailable service clears the previous address.

**Refresh status** rechecks the local monitoring address, network interfaces, and recording state. It does not restart the service or force a new temperature sample. **Local network interface** selects the address used for LAN access; choose an interface, enable LAN, and generate a pairing code to connect a phone or another computer on the same network. Local monitoring does not require LAN access to be enabled.

## Quit and stop behavior

Closing the control window keeps background monitoring active. Explicit Quit (⌘Q) asks the owner-bound Agent to shut down, waits for its PID to exit, and then exits the control app. If stopping fails, the app displays the specific error and allows the control window to close; the Agent may still be running. This stops the current session while preserving the boot preference; use **Start service** to resume, or **Open monitor** to start an available installed service and open the page after IPC is ready. Starting the system service requests administrator authorization. Logging out closes the UI without issuing this owner stop, so the system-domain service can continue.

The LaunchDaemon restarts abnormal exits, including `SIGKILL`. A changed PID after a force kill therefore indicates a new process, not an unkillable original process. Normal owner shutdown exits successfully and is not restarted by `KeepAlive/SuccessfulExit=false`. **Stop service** performs administrator-authorized disable/bootout and also disables automatic startup, as before.

For an older version that cannot be stopped through the UI, the following administrator commands target only Cloud Mac Monitor:

```bash
sudo launchctl disable system/org.cloudmacmonitor.agent
sudo launchctl bootout system/org.cloudmacmonitor.agent
```

After updating, choose **Enable at boot** to restore the disabled service. These commands preserve account and history data. Do not repeatedly force-kill the Agent while its job remains enabled.

Normal sampling now runs once every 10 seconds for system metrics, process rankings, temperatures, and GPU metrics. Low-power or serious thermal conditions use 20 seconds. Drive SMART readings remain cached for 60 seconds. SMC queries share a single connection per batch and cache readable keys; core-cluster rows show their highest reading, with individual IDs available in details.
