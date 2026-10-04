#!/usr/bin/env python3
"""Exercise the installer's real old-installation decision block using temporary paths.
Privilege/path policy is covered separately; no system job or production data is changed.
"""
import json, os, pwd, pathlib, shlex, subprocess, tempfile
project = pathlib.Path(__file__).resolve().parent.parent
source = (project / 'scripts/install.sh').read_text()
block = source[source.index('restart=false; enabled=true; legacy=false'):source.index("printf '{\"ownerName\"")]

def check(name, app_state, loaded=False, unsafe_data=False, expected_failure=False, boot_enabled=True):
    with tempfile.TemporaryDirectory(prefix='cmm-reinstall.', dir='/private/tmp') as folder:
        root = pathlib.Path(folder); app = root / 'App.app'; data = root / 'data'
        data.mkdir(mode=0o700); sentinel = data / 'history.sqlite'; sentinel.write_bytes(b'preserve-history')
        if unsafe_data: data.chmod(0o755)
        config = {'ownerUid': os.getuid(), 'ownerGuid': 'fixture-guid', 'bootEnabled': False}
        (root / 'installation.json').write_text(json.dumps(config))
        stage = root / 'stage'; stage.mkdir()
        if app_state == 'healthy':
            helper = app / 'Contents/MacOS/MonitorMaintenance'; helper.parent.mkdir(parents=True)
            helper.write_text('''#!/bin/bash
if [[ "$1" == status ]]; then echo '{"bootEnabled":true,"systemEnabled":true,"running":true}'; fi
if [[ "$1" == stop ]]; then echo stopped > "${fixture_root}/stopped"; fi
'''.replace('\"bootEnabled\":true,\"systemEnabled\":true', '\"bootEnabled\":'+str(boot_enabled).lower()+',\"systemEnabled\":'+str(boot_enabled).lower())); helper.chmod(0o755)
        elif app_state == 'partial': app.mkdir()
        elif app_state == 'symlink': app.symlink_to(root / 'missing')
        values = {'root': str(root), 'fixture_root': str(root), 'app': str(app), 'public_app': str(root / 'Public.app'), 'root_stage': str(stage), 'job': 'system/org.cloudmacmonitor.agent', 'plist': str(root / 'agent.plist'), 'owner_uid': str(os.getuid()), 'owner_name': pwd.getpwuid(os.getuid()).pw_name, 'owner_guid': 'fixture-guid'}
        preamble = 'set -euo pipefail\n' + '\n'.join('export '+k+'='+shlex.quote(v) for k,v in values.items()) + '\n'
        # Stub only privileged policy and launchctl; execute the release decision block unchanged.
        preamble += '''protected_parent() { [[ -e "$1" && ! -L "$1" ]] || { echo 'Unsafe path' >&2; exit 1; }; }
launchctl() { echo "$*" >> "$root/launchctl-calls"; if [[ "$1" == print ]]; then return '''+('0' if loaded else '1')+'''; fi; }
'''
        result = subprocess.run(['/bin/bash'], input=preamble+block+'\nprintf "%s %s" "$enabled" "$restart"\n', text=True, capture_output=True)
        assert (result.returncode != 0) == expected_failure, (name, result.stdout, result.stderr)
        assert sentinel.read_bytes() == b'preserve-history'
        if unsafe_data: assert not (root / 'launchctl-calls').exists()
        if not expected_failure:
            assert result.stdout.endswith(('true' if app_state != 'healthy' or boot_enabled else 'false')+' true'), (name, result.stdout)
            if app_state == 'healthy': assert (root / 'stopped').exists()
            else:
                calls = (root / 'launchctl-calls').read_text()
                assert 'disable system/org.cloudmacmonitor.agent' in calls
                assert ('bootout' in calls) == loaded
        print(name + ': passed')

check('uninstalled app with saved data', 'missing')
check('missing app with stale loaded job', 'missing', loaded=True)
check('healthy upgrade keeps existing path', 'healthy')
check('partial app remains refused', 'partial', expected_failure=True)
check('dangling app link remains refused', 'symlink', expected_failure=True)
check('unsafe data remains refused', 'missing', unsafe_data=True, expected_failure=True)

check('running upgrade preserves disabled boot preference', 'healthy', boot_enabled=False)
