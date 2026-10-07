#!/usr/bin/env python3
"""Check the installer's GUI authorization wrapper without requesting elevation."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

source = (Path(__file__).resolve().parent / "install.sh").read_text()
wrapper = source[source.index("run_privileged() {"):source.index('\nrun_privileged "$stage/archive.tar.gz"')]
with tempfile.TemporaryDirectory(prefix="cmm-installer-gui.", dir="/private/tmp") as folder:
    root = Path(folder)
    # Run the real AppleScript quoting and bash handoff, omitting only elevation.
    unprivileged = wrapper.replace(" with administrator privileges", "")
    output = root / "arguments"
    arguments = ["path with spaces", "owner's name", "$(touch unexpected)"]
    body = 'printf "%s\\n" "$@" > ' + shlex.quote(str(output))
    invoke = "run_privileged " + " ".join(map(shlex.quote, arguments)) + " <<'TEST_SCRIPT'\n" + body + "\nTEST_SCRIPT\n"
    preamble = "set -euo pipefail\nstage=" + shlex.quote(folder) + "\n"
    for gui in ("0", "1"):
        env = {**os.environ, "CMM_INSTALL_GUI": gui}
        # The CLI branch uses the same fixed script on stdin.
        subprocess.run(["/bin/bash"], input=preamble + "sudo() { \"$@\"; }\n" + unprivileged + "\n" + invoke, text=True, env=env, check=True, capture_output=True)
        assert output.read_text().splitlines() == arguments
        assert not (root / "unexpected").exists()
        output.unlink()
    # A rejected authorization must not run the privileged installation script.
    denied = wrapper.replace("/usr/bin/osascript", "deny_authorization")
    result = subprocess.run(["/bin/bash"], input=preamble + "deny_authorization() { return 1; }\n" + denied + "\n" + invoke, text=True, env={**os.environ, "CMM_INSTALL_GUI": "1"}, capture_output=True)
    assert result.returncode != 0 and not output.exists()
    archive = root / ("MacMonitor-0.1.12-" + os.uname().machine + ".tar.gz")
    archive.write_bytes(b"incorrect archive")
    result = subprocess.run(["/bin/bash", str(Path(__file__).resolve().parent / "install.sh"), "0.1.12", "--local", str(archive), "a" * 64], env={**os.environ, "CMM_INSTALL_GUI": "1"}, text=True, capture_output=True)
    assert result.returncode != 0 and "Checksum mismatch; nothing installed." in result.stderr
print("GUI/CLI handoff, argument quoting, canceled authorization, and checksum rejection: passed")
