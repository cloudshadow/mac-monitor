#!/usr/bin/env python3
"""Automatic en0 TLS and password-only LAN integration; no trust-store changes."""
import http.client,json,pathlib,socket,ssl,subprocess,tempfile,time,urllib.parse
project=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='cmm-lan.',dir='/private/tmp') as root:
 p=subprocess.Popen([str(project/'.build/debug/MonitorAgent'),'--data-root',root,'--web-root',str(project/'web/dist'),'--port','0'],stderr=subprocess.PIPE,text=True)
 streams=[]
 try:
  ready=p.stderr.readline();assert 'ready at ' in ready,ready
  local=ready.split('ready at ')[1].strip();port=urllib.parse.urlsplit(local).port
  def control(command,expected_error=None,**kwargs):
   with socket.socket(socket.AF_UNIX) as c:
    c.settimeout(10);c.connect(root+'/run/control.sock');c.sendall(json.dumps({'command':command,**kwargs}).encode()+b'\n');raw=b''
    while not raw.endswith(b'\n'):
     chunk=c.recv(65536);assert chunk,'IPC closed without response';raw+=chunk
    value=json.loads(raw)
    if expected_error:assert value['error']['code']==expected_error,value
    else:assert not isinstance(value,dict) or value.get('error') is None,value
    return value
  status=control('status');assert status['lanInterface']=='en0'
  if not any(i['name']=='en0' for i in status['interfaces']):
   assert status['lanAddress']==''
   print(json.dumps({'lanSmoke':'skipped','reason':'en0 has no active IPv4 address','localService':'ready'}))
  else:
   deadline=time.monotonic()+10
   while not status['lanAddress'] and time.monotonic()<deadline:
    time.sleep(.1);status=control('status')
   lan=status['lanAddress'];assert lan,status
   address=urllib.parse.urlsplit(lan)
   assert address.hostname==next(i['address'] for i in status['interfaces'] if i['name']=='en0')
   context=ssl.create_default_context(cafile=root+'/secrets/ca.pem');cookies={};csrf=''
   def request(route,method='GET',body=None,expected=200):
    c=http.client.HTTPSConnection(address.hostname,address.port,timeout=7,context=context)
    h={'Origin':lan,'Cookie':'; '.join(k+'='+v for k,v in cookies.items())}
    if method!='GET':h.update({'Content-Type':'application/json','X-CSRF-Token':csrf})
    c.request(method,route,json.dumps(body) if body is not None else None,h);r=c.getresponse();raw=r.read();assert r.status==expected,(r.status,raw)
    for name,value in r.getheaders():
     if name.lower()=='set-cookie':
      assert 'Secure' in value and 'HttpOnly' in value and 'SameSite=Strict' in value
      key,token=value.split(';')[0].split('=',1);cookies[key]=token
    c.close();return json.loads(raw) if raw else None
   assert request('/api/v1/auth/status')['status']=='returnToMac'
   request('/api/v1/auth/setup','POST',{'username':'remote','password':'remote-password-12345'},expected=403)
   c=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
   c.request('POST','/api/v1/auth/setup',json.dumps({'username':'lan-owner','password':'lan-password-12345'}),{'Origin':local,'Content-Type':'application/json'})
   r=c.getresponse();assert r.status==201,r.read();r.read();c.close()
   assert request('/api/v1/auth/status')['status']=='loginRequired'
   request('/api/v1/snapshot',expected=401)
   request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'bad-password'},expected=401)
   csrf=request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'lan-password-12345'})['csrfToken']
   assert set(cookies)=={'cmm_lan_session'};request('/api/v1/snapshot')
   request('/api/v1/pairing/exchange','POST',{'ticket':'retired','deviceLabel':'retired'},expected=404)
   for command in ['pair','devices','revokeDevice','lan']:control(command,expected_error='invalidCommand')
   # A LAN session cannot be relabeled as a loopback session.
   c=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
   c.request('GET','/api/v1/snapshot',headers={'Cookie':'cmm_session='+cookies['cmm_lan_session']})
   r=c.getresponse();assert r.status==401,r.read();r.read();c.close()
   viewer_ids=[]
   for _ in range(3):
    viewer=request('/api/v1/viewers','POST',{'channels':['system']},expected=201)['viewerId'];viewer_ids.append(viewer)
    connection=http.client.HTTPSConnection(address.hostname,address.port,timeout=5,context=context)
    connection.request('GET','/api/v1/events?viewerId='+viewer,headers={'Cookie':'; '.join(k+'='+v for k,v in cookies.items())})
    response=connection.getresponse();assert response.status==200,(response.status,response.read());streams.append((connection,response))
   fourth=request('/api/v1/viewers','POST',{'channels':['system']},expected=201)['viewerId'];request('/api/v1/events?viewerId='+fourth,expected=429)
   csrf=request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'lan-password-12345'})['csrfToken']
   request('/api/v1/events?viewerId='+viewer_ids[0],expected=404)
   started=time.monotonic();control('resetPassword',password='changed-lan-password-12345');request('/api/v1/snapshot',expected=401)
   for connection,response in streams:
    try: response.read()
    except http.client.IncompleteRead: pass
    connection.close()
   streams=[];assert time.monotonic()-started<5,'Password reset did not close old streams within 5s'
   csrf=request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'changed-lan-password-12345'})['csrfToken']
   request('/api/v1/snapshot')
   request('/api/v1/auth/logout','POST',expected=204);request('/api/v1/snapshot',expected=401)
   print(json.dumps({'lanSmoke':'passed','checks':['automatic en0 TLS before setup','remote setup denied','password login without pairing','incorrect password rejected','Secure HttpOnly cookies','retired pairing controls unavailable','loopback/LAN session isolation','3-stream limit','cross-session viewer rejected','password reset revokes sessions/streams','logout revokes session']}))
 finally:
  for connection,_ in streams:connection.close()
  p.terminate()
  try:p.wait(timeout=7)
  except subprocess.TimeoutExpired:p.kill();p.wait()
  assert p.returncode==0,('Agent did not exit normally',p.returncode)
