#!/usr/bin/env python3
"""Developer-only HTTP/Unix socket integration test; no installation or root operations."""
import http.client,json,os,pathlib,socket,subprocess,tempfile,time,urllib.parse
project=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='cmm-smoke.',dir='/private/tmp') as data:
    process=subprocess.Popen([str(project/'.build/debug/MonitorAgent'),'--data-root',data,'--web-root',str(project/'web/dist'),'--port','0'],stderr=subprocess.PIPE,text=True)
    try:
        ready=process.stderr.readline().strip()
        assert 'ready at http://' in ready,ready
        base=ready.split('ready at ')[1]; parsed=urllib.parse.urlsplit(base); port=parsed.port; cookies={};csrf=''
        def control(command,**args):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5);connection.connect(data+'/run/control.sock');connection.sendall(json.dumps({'command':command,**args}).encode()+b'\n');raw=b''
                while not raw.endswith(b'\n'):raw+=connection.recv(16384)
                value=json.loads(raw);assert value.get('error') is None,value;return value
        def request(path,method='GET',body=None,origin=True,headers=None,expected=200):
            connection=http.client.HTTPConnection('127.0.0.1',port,timeout=7)
            h={'Cookie':'; '.join(k+'='+v for k,v in cookies.items())}
            if method!='GET':h.update({'Content-Type':'application/json','X-CSRF-Token':csrf})
            if origin:h['Origin']=base
            if headers:h.update(headers)
            connection.request(method,path,json.dumps(body) if body is not None else None,h);response=connection.getresponse();raw=response.read()
            for name,value in response.getheaders():
                if name.lower()=='set-cookie':key,value=value.split(';')[0].split('=',1);cookies[key]=value
            assert response.status==expected,(path,response.status,raw[:300]);connection.close()
            return json.loads(raw) if raw else None
        request('/healthz',origin=False)
        assert request('/api/v1/auth/status',origin=False)['status']=='setupRequired'
        request('/api/v1/snapshot',expected=401,origin=False)
        request('/healthz',headers={'Host':'evil.test'},expected=403)
        request('/api/v1/auth/login','POST',{'username':'owner','password':'not-a-valid-password'},origin=False,expected=403)
        request('/api/v1/auth/login','POST',{},headers={'Origin':'null'},expected=403)
        ticket=urllib.parse.parse_qs(urllib.parse.urlsplit(control('setup')['url']).fragment)['setup'][0]
        result=request('/api/v1/auth/setup','POST',{'setupTicket':ticket,'username':'owner','password':'test-password-12345'},expected=201);csrf=result['csrfToken']
        assert request('/api/v1/auth/session',origin=False)['csrfToken']==csrf
        time.sleep(5)
        snapshot=request('/api/v1/snapshot',origin=False);assert snapshot['cpu']['status']=='ok',snapshot
        apps=request('/api/v1/apps?limit=2',origin=False);assert apps['rows'],apps
        if apps['nextCursor']:request('/api/v1/apps?limit=2&cursor='+urllib.parse.quote(apps['nextCursor']),origin=False)
        request('/api/v1/viewers','POST',{'channels':['system']},headers={'X-CSRF-Token':'invalid'},expected=403)
        viewer=request('/api/v1/viewers','POST',{'channels':['system','apps']},expected=201)
        stream=http.client.HTTPConnection('127.0.0.1',port,timeout=5);stream.request('GET','/api/v1/events?viewerId='+viewer['viewerId'],headers={'Cookie':'; '.join(k+'='+v for k,v in cookies.items())});response=stream.getresponse();assert response.status==200
        lines=[response.fp.readline().decode() for _ in range(5)];assert any('event: system' in line for line in lines),lines;stream.close()
        now=time.time();history=request('/api/v1/recent/system?from='+str(now-300)+'&to='+str(now)+'&seriesIds=cpu.total&maxPoints=300',origin=False);assert history['series']['cpu.total'],history
        old_epoch=history['recordingEpoch'];cleared=control('history',action='clear');assert cleared['recordingEpoch']!=old_epoch
        control('resetPassword',password='changed-password-12345')
        request('/api/v1/snapshot',expected=401,origin=False)
        result=request('/api/v1/auth/login','POST',{'username':'owner','password':'changed-password-12345'});csrf=result['csrfToken']
        request('/api/v1/auth/logout','POST',{},expected=204)
        request('/api/v1/snapshot',expected=401,origin=False)
        assert control('prepareStop')['ready']
        print(json.dumps({'httpSmoke':'passed','checks':['setup','origin matrix','session restore','apps pagination','csrf','SSE','recent history','epoch clear','password revocation','logout','prepareStop'],'systemCPUStatus':snapshot['cpu']['status'],'readableProcesses':apps['coverage']['readable']}))
    finally:
        process.terminate()
        try:process.wait(timeout=7)
        except subprocess.TimeoutExpired:process.kill();process.wait()
