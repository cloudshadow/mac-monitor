#!/usr/bin/env python3
"""Exercise the installer's real old-installation decision block using temporary paths.
Privilege/path policy is covered separately; no system job or production data is changed.
"""
import json, os, pwd, pathlib, plistlib, shlex, subprocess, tempfile
project = pathlib.Path(__file__).resolve().parent.parent
source = (project / 'scripts/install.sh').read_text()
block = source[source.index('restart=false; enabled=true; legacy=false'):source.index("printf '{\"ownerName\"")]

block = block.replace("renamed_launcher='/Applications/Cloud Mac Monitor.app'", 'renamed_launcher="$root/OldPublic.app"')

def check(name, app_state, loaded=False, unsafe_data=False, expected_failure=False, boot_enabled=True):
    with tempfile.TemporaryDirectory(prefix='cmm-reinstall.', dir='/private/tmp') as folder:
        root = pathlib.Path(folder); app = root / 'App.app'; data = root / 'data'
        data.mkdir(mode=0o700); sentinel = data / 'history.sqlite'; sentinel.write_bytes(b'preserve-history')
        if unsafe_data: data.chmod(0o755)
        config = {'ownerUid': os.getuid(), 'ownerGuid': 'fixture-guid', 'bootEnabled': False}
        (root / 'installation.json').write_text(json.dumps(config))
        stage = root / 'stage'; stage.mkdir()
        if app_state in ('healthy', 'renamed'):
            installed = root / 'Cloud Mac Monitor.app' if app_state == 'renamed' else app
            helper = installed / 'Contents/MacOS/MonitorMaintenance'; helper.parent.mkdir(parents=True)
            helper.write_text('''#!/bin/bash
if [[ "$1" == status ]]; then echo '{"bootEnabled":true,"systemEnabled":true,"running":true}'; fi
if [[ "$1" == stop ]]; then echo stopped > "${fixture_root}/stopped"; fi
'''.replace('\"bootEnabled\":true,\"systemEnabled\":true', '\"bootEnabled\":'+str(boot_enabled).lower()+',\"systemEnabled\":'+str(boot_enabled).lower())); helper.chmod(0o755)
            if app_state == 'renamed':
                (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.cloudmacmonitor.control'}))
        elif app_state == 'partial': app.mkdir()
        elif app_state == 'symlink': app.symlink_to(root / 'missing')
        values = {'root': str(root), 'fixture_root': str(root), 'app': str(app), 'public_app': str(root / 'Public.app'), 'root_stage': str(stage), 'job': 'system/org.cloudmacmonitor.agent', 'plist': str(root / 'agent.plist'), 'owner_uid': str(os.getuid()), 'owner_name': pwd.getpwuid(os.getuid()).pw_name, 'owner_guid': 'fixture-guid'}
        preamble = 'set -euo pipefail\nmigrating=false\n' + '\n'.join('export '+k+'='+shlex.quote(v) for k,v in values.items()) + '\n'
        # Stub only privileged policy and launchctl; execute the release decision block unchanged.
        preamble += '''protected_parent() { [[ -e "$1" && ! -L "$1" ]] || { echo 'Unsafe path' >&2; exit 1; }; }
launchctl() { echo "$*" >> "$root/launchctl-calls"; if [[ "$1" == print ]]; then return '''+('0' if loaded else '1')+'''; fi; }
'''
        result = subprocess.run(['/bin/bash'], input=preamble+block+'\nprintf "%s %s" "$enabled" "$restart"\n', text=True, capture_output=True)
        assert (result.returncode != 0) == expected_failure, (name, result.stdout, result.stderr)
        assert sentinel.read_bytes() == b'preserve-history'
        if unsafe_data: assert not (root / 'launchctl-calls').exists()
        if not expected_failure:
            assert result.stdout.endswith(('true' if app_state not in ('healthy', 'renamed') or boot_enabled else 'false')+' true'), (name, result.stdout)
            if app_state in ('healthy', 'renamed'): assert (root / 'stopped').exists()
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

check('renamed product preserves existing service and data', 'renamed')
check('renamed product preserves disabled boot preference', 'renamed', boot_enabled=False)

# Exercise the real one-time directory migration using temporary installations.
migration_setup = source[source.index('staging_root="$root"'):source.index('\nlock="$staging_root/install.lock"')]
def check_directory_migration(boot, running, failure=None, removed=False):
    with tempfile.TemporaryDirectory(prefix='cmm-directory-migration.', dir='/private/tmp') as folder:
        outer = pathlib.Path(folder); old = outer / 'CloudMacMonitor'; new = outer / 'MacMonitor'
        old.mkdir(); data = old / 'data'; data.mkdir(mode=0o700)
        for name in ['state.sqlite', 'history.sqlite', 'ca.pem']:
            (data / name).write_bytes(('preserve-'+name).encode())
        config = {'ownerUid': os.getuid() + (1 if failure == 'owner' else 0), 'ownerGuid': 'fixture-guid', 'bootEnabled': boot}
        (old / 'installation.json').write_text(json.dumps(config))
        helper = old / 'Mac Monitor.app/Contents/MacOS/MonitorMaintenance'; helper.parent.mkdir(parents=True)
        status = json.dumps({'bootEnabled': boot, 'systemEnabled': boot, 'running': running})
        helper.write_text('#!/bin/bash\nset -euo pipefail\n[[ -d "$old_root" && ! -e "$root" ]]\nif [[ "$1" == status ]]; then\ncat <<\'STATUS\'\n'+status+'\nSTATUS\nelse\nprintf stopped > "$fixture_root/stopped"\nfi\n'); helper.chmod(0o755)
        if removed: __import__('shutil').rmtree(old / 'Mac Monitor.app')
        public = outer / 'Public.app'; public.symlink_to(str(old / 'Mac Monitor.app') if failure != 'launcher' else str(outer / 'Unrelated.app'))
        if failure == 'conflict': new.mkdir(); (new / 'keep.txt').write_text('keep')
        if failure == 'data': data.chmod(0o755)
        if failure == 'recovery': (old / 'previous.app').mkdir()
        values = {'fixture_root': folder, 'root': str(new), 'old_root': str(old), 'app': str(new / 'Mac Monitor.app'), 'public_app': str(public), 'job': 'system/org.cloudmacmonitor.agent', 'plist': str(outer / 'agent.plist'), 'owner_uid': str(os.getuid()), 'owner_guid': 'fixture-guid', 'owner_name': pwd.getpwuid(os.getuid()).pw_name}
        preamble = 'set -euo pipefail\n'+'\n'.join('export '+k+'='+shlex.quote(v) for k,v in values.items())+'\n'
        preamble += '''protected_parent() { [[ -e "$1" && ! -L "$1" ]] || exit 1; }
# Only emulate root ownership of the managed entry; no real system paths are used.
stat() { if [[ "$1" == -f && "$2" == %u && "$3" == "$public_app" ]]; then echo 0; else /usr/bin/stat "$@"; fi; }
launchctl() { echo "$*" >> "$fixture_root/launchctl-calls"; }
'''
        prepare = '''
lock="$staging_root/install.lock"; mkdir "$lock"
root_stage="$staging_root/staging.fixture"; mkdir -p "$root_stage/extract/Mac Monitor.app"
new_app="$root_stage/extract/Mac Monitor.app"
'''
        result = subprocess.run(['/bin/bash'], input=preamble+migration_setup+prepare+block+'\n[[ -d "$new_app" && -d "$lock" ]]\nprintf "%s %s" "$enabled" "$restart"\n', text=True, capture_output=True)
        assert (result.returncode != 0) == (failure is not None), (failure, result.stdout, result.stderr)
        stored = old if failure else new
        for name in ['state.sqlite', 'history.sqlite', 'ca.pem']:
            assert (stored / 'data' / name).read_bytes() == ('preserve-'+name).encode()
        if failure:
            assert old.exists() and not (outer / 'stopped').exists() and public.is_symlink()
            if failure == 'conflict': assert (new / 'keep.txt').read_text() == 'keep'
        else:
            assert not old.exists() and not public.is_symlink()
            if removed:
                calls = (outer / 'launchctl-calls').read_text()
                assert 'bootout system/org.cloudmacmonitor.agent' in calls
                assert result.stdout.endswith('true true'), result.stdout
            else:
                assert (outer / 'stopped').exists()
                assert result.stdout.endswith(str(boot).lower()+' '+str(running).lower()), result.stdout
        print('directory migration '+str((boot, running, failure, removed))+': passed')
for boot in (True, False):
    for running in (True, False): check_directory_migration(boot, running)
for failure in ('conflict', 'owner', 'launcher', 'data', 'recovery'):
    check_directory_migration(False, True, failure)

check_directory_migration(False, True, removed=True)
