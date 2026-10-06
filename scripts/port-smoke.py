#!/usr/bin/env python3
"""Local port configuration/IPC smoke test using disposable data; no installed service changes."""
import http.client
import os
import json
import pathlib
import select
import socket
import subprocess
import tempfile
import time
import urllib.parse

project = pathlib.Path(__file__).resolve().parent.parent


def occupy(host='127.0.0.1', port=0):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind((host, port))
        listener.listen(1)
        return listener
    except Exception:
        listener.close()
        raise


with tempfile.TemporaryDirectory(prefix='cmm-port.', dir='/private/tmp') as root:
    process = None

    def start(random_port=False):
        global process
        arguments = [os.environ.get('CMM_TEST_AGENT', str(project / '.build/debug/MonitorAgent')), '--data-root', root,
                     '--web-root', str(project / 'web/dist')]
        if random_port:
            arguments += ['--port', '0']
        process = subprocess.Popen(arguments, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if select.select([process.stderr], [], [], 1)[0]:
                line = process.stderr.readline()
                assert line, ('Agent exited before readiness', process.poll())
                assert 'could not start' not in line, line
                if 'ready at ' in line:
                    return
        raise AssertionError('Agent readiness timed out')

    def stop():
        global process
        if process is not None:
            process.terminate()
            try:
                _, stderr = process.communicate(timeout=10)
                assert process.returncode == 0, (process.returncode, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process = None

    def control(command, expected_error=None, **arguments):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(root + '/run/control.sock')
            connection.sendall(json.dumps({'command': command, **arguments}).encode() + b'\n')
            raw = b''
            while not raw.endswith(b'\n'):
                chunk = connection.recv(16384)
                assert chunk, 'IPC closed without response'
                raw += chunk
        result = json.loads(raw)
        if expected_error:
            assert result['error']['code'] == expected_error, result
        else:
            assert result.get('error') is None, result
        return result

    def healthy(address):
        parsed = urllib.parse.urlsplit(address)
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=5)
        try:
            connection.request('GET', '/healthz')
            response = connection.getresponse()
            assert response.status == 200, (response.status, response.read())
            assert json.loads(response.read())['status'] == 'ok'
        finally:
            connection.close()

    try:
        start(random_port=True)
        original = control('status')
        for invalid in [0, -1, 65536, 12.5, '9000']:
            control('setPort', 'invalidPort', port=invalid)
        with occupy() as collision:
            control('setPort', 'localPortInUse', port=collision.getsockname()[1])
            assert control('status')['address'] == original['address']
            healthy(original['address'])
        with occupy() as reservation:
            desired = reservation.getsockname()[1]
        result = control('setPort', port=desired)
        assert result['configuredPort'] == result['actualPort'] == desired, result
        assert not result['portFallback'], result
        healthy(result['address'])
        if result['lanAddress']:
            assert urllib.parse.urlsplit(result['lanAddress']).port == desired, result
        chosen = next((item for item in result['interfaces'] if item['name'] == 'en0'), None)
        if chosen:
            with occupy(chosen['address']) as collision:
                control('setPort', 'lanPortInUse', port=collision.getsockname()[1])
                assert control('status')['address'] == result['address']
                healthy(result['address'])
        stop()
        start()
        persisted = control('status')
        assert persisted['configuredPort'] == persisted['actualPort'] == desired, persisted
        healthy(persisted['address'])
        stop()
        with occupy(port=desired):
            start()
            fallback = control('status')
            assert fallback['configuredPort'] == desired and fallback['actualPort'] != desired, fallback
            assert fallback['portFallback'], fallback
            healthy(fallback['address'])
            stop()
        print(json.dumps({'portSmoke': 'passed', 'persistence': 'passed',
                          'localConflict': 'passed', 'lanConflict': 'passed' if chosen else 'skipped: en0 unavailable',
                          'startupFallbackWarning': 'passed', 'invalidInput': 'passed'}))
    finally:
        stop()
