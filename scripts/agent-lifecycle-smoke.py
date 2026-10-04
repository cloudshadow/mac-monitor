#!/usr/bin/env python3
"""Temporary per-user launchd fixture; never changes the production system job."""
import json, os, pathlib, plistlib, signal, socket, subprocess, tempfile, time, uuid
project = pathlib.Path(__file__).resolve().parent.parent
agent = project / '.build/debug/MonitorAgent'
label = 'org.cloudmacmonitor.lifecycle-test.' + uuid.uuid4().hex
domain = 'gui/' + str(os.getuid())
job = domain + '/' + label

def wait(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(0.1)
    raise AssertionError('Lifecycle condition timed out')

with tempfile.TemporaryDirectory(prefix='cmm-lifecycle.', dir='/private/tmp') as root:
    data = pathlib.Path(root) / 'data'
    config = {'Label': label, 'ProgramArguments': [str(agent), '--data-root', str(data), '--web-root', str(project / 'web/dist'), '--port', '0'],
              'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 1,
              'StandardErrorPath': root + '/stderr.log', 'StandardOutPath': root + '/stdout.log'}
    path = pathlib.Path(root) / 'agent.plist'; path.write_bytes(plistlib.dumps(config))
    def control(command):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(7); s.connect(str(data / 'run/control.sock'))
            s.sendall(json.dumps({'command': command}).encode() + b'\n')
            body = b''
            while not body.endswith(b'\n'):
                chunk = s.recv(65536)
                assert chunk, 'Control socket closed without acknowledgement'
                body += chunk
            result = json.loads(body); assert 'error' not in result, result
            return result
    def pid():
        output = subprocess.run(['/bin/launchctl', 'print', job], text=True, capture_output=True).stdout
        for line in output.splitlines():
            if line.strip().startswith('pid = '): return int(line.split('=')[1])
        return None
    def ready():
        if not (data / 'run/control.sock').exists(): return False
        try: return control('status')['address'].startswith('http://')
        except (OSError, AssertionError): return False
    try:
        subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(path)], check=True, capture_output=True)
        wait(ready); first = pid(); assert first
        response = control('shutdown'); assert response['pid'] == first
        wait(lambda: pid() is None)
        time.sleep(3); assert pid() is None, 'Successful owner stop was restarted by KeepAlive'
        subprocess.run(['/bin/launchctl', 'kickstart', job], check=True, capture_output=True)
        wait(ready); second = pid(); assert second and second != first
        os.kill(second, signal.SIGTERM)
        wait(lambda: pid() is None)
        time.sleep(3)
        if pid() is not None:
            print(subprocess.run(['/bin/launchctl', 'print', job], text=True, capture_output=True).stdout, flush=True)
            print((pathlib.Path(root) / 'stderr.log').read_text(), flush=True)
            raise AssertionError('SIGTERM was ignored or restarted')
        subprocess.run(['/bin/launchctl', 'kickstart', job], check=True, capture_output=True)
        wait(ready); second = pid(); assert second
        os.kill(second, signal.SIGKILL)
        wait(lambda: pid() not in (None, second)); wait(ready)
        restarted = pid(); assert restarted
        control('shutdown'); wait(lambda: pid() is None)
        time.sleep(3); assert pid() is None
        assert 'shutdown deadline reached' not in (pathlib.Path(root) / 'stderr.log').read_text(), 'Shutdown did not flush within deadline'
        # A disabled boot override does not stop an already running session.
        subprocess.run(['/bin/launchctl', 'bootout', job], check=True, capture_output=True)
        subprocess.run(['/bin/launchctl', 'enable', job], check=True, capture_output=True)
        subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(path)], check=True, capture_output=True)
        wait(ready); running = pid(); assert running
        subprocess.run(['/bin/launchctl', 'disable', job], check=True, capture_output=True)
        time.sleep(1); assert pid() == running; assert ready()
        control('prepareStop')
        subprocess.run(['/bin/launchctl', 'bootout', job], check=True, capture_output=True)
        wait(lambda: pid() is None)
        overrides = subprocess.run(['/bin/launchctl', 'print-disabled', domain], text=True, capture_output=True, check=True).stdout
        assert any(label in line and ('disabled' in line or 'true' in line) for line in overrides.splitlines())
        # Temporary enable for Start followed by disable keeps the session alive.
        subprocess.run(['/bin/launchctl', 'enable', job], check=True, capture_output=True)
        subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(path)], check=True, capture_output=True)
        subprocess.run(['/bin/launchctl', 'kickstart', job], check=True, capture_output=True)
        subprocess.run(['/bin/launchctl', 'disable', job], check=True, capture_output=True)
        wait(ready); assert pid(); control('shutdown'); wait(lambda: pid() is None)
        print(json.dumps({'agentLifecycle': 'passed', 'scope': 'temporary user-domain fixture', 'checks': ['owner shutdown exits actual PID', 'successful stop does not respawn', 'explicit restart works', 'SIGTERM stops without respawn', 'SIGKILL respawns under KeepAlive', 'restarted Agent can stop normally', 'boot disable leaves running session alive', 'session stop preserves disabled override', 'temporary enable-start-disable runs with boot disabled']}))
    finally:
        subprocess.run(['/bin/launchctl', 'bootout', job], capture_output=True)
        subprocess.run(['/bin/launchctl', 'enable', job], capture_output=True)
