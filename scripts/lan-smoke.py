#!/usr/bin/env python3
"""Developer LAN TLS integration; creates a temporary CA, no trust-store changes."""
import http.client,json,pathlib,socket,ssl,subprocess,tempfile,time,urllib.parse
project=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='cmm-lan.',dir='/private/tmp') as root:
 p=subprocess.Popen([str(project/'.build/debug/MonitorAgent'),'--data-root',root,'--web-root',str(project/'web/dist'),'--port','0'],stderr=subprocess.PIPE,text=True)
 try:
  ready=p.stderr.readline();local=ready.split('ready at ')[1].strip();port=urllib.parse.urlsplit(local).port
  def control(command,**kwargs):
   with socket.socket(socket.AF_UNIX) as c:
    c.settimeout(10);c.connect(root+'/run/control.sock');c.sendall(json.dumps({'command':command,**kwargs}).encode()+b'\n');raw=b''
    while not raw.endswith(b'\n'):raw+=c.recv(65536)
    value=json.loads(raw);assert not isinstance(value,dict) or value.get('error') is None,value;return value
  token=urllib.parse.parse_qs(urllib.parse.urlsplit(control('setup')['url']).fragment)['setup'][0]
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=5);c.request('POST','/api/v1/auth/setup',json.dumps({'setupTicket':token,'username':'lan-owner','password':'lan-password-12345'}),{'Origin':local,'Content-Type':'application/json'});r=c.getresponse();assert r.status==201,r.read();r.read();c.close()
  status=control('status');assert status['interfaces'],'No physical LAN interface available'
  lan=control('lan',enabled=True,interface=status['interfaces'][0]['name'])['address'];address=urllib.parse.urlsplit(lan)
  context=ssl.create_default_context(cafile=root+'/secrets/ca.pem');cookies={};csrf=''
  def request(route,method='GET',body=None,expected=200):
   c=http.client.HTTPSConnection(address.hostname,address.port,timeout=7,context=context);h={'Origin':lan,'Cookie':'; '.join(k+'='+v for k,v in cookies.items())}
   if method!='GET':h.update({'Content-Type':'application/json','X-CSRF-Token':csrf})
   c.request(method,route,json.dumps(body) if body is not None else None,h);r=c.getresponse();raw=r.read();assert r.status==expected,(r.status,raw)
   for name,value in r.getheaders():
    if name.lower()=='set-cookie': assert 'Secure' in value and 'HttpOnly' in value; key,token=value.split(';')[0].split('=',1);cookies[key]=token
   c.close();return json.loads(raw) if raw else None
  request('/api/v1/auth/setup','POST',{'username':'remote','password':'remote-password-12345'},expected=403)
  request('/api/v1/snapshot',expected=403)
  ticket=urllib.parse.parse_qs(urllib.parse.urlsplit(control('pair')['url']).fragment)['pair'][0]
  request('/api/v1/pairing/exchange','POST',{'ticket':ticket,'deviceLabel':'integration-device'})
  request('/api/v1/snapshot',expected=401)
  result=request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'lan-password-12345'});csrf=result['csrfToken'];request('/api/v1/snapshot')
  streams=[];viewer_ids=[]
  for _ in range(3):
   viewer=request('/api/v1/viewers','POST',{'channels':['system']},expected=201)['viewerId'];viewer_ids.append(viewer)
   connection=http.client.HTTPSConnection(address.hostname,address.port,timeout=5,context=context);connection.request('GET','/api/v1/events?viewerId='+viewer,headers={'Cookie':'; '.join(k+'='+v for k,v in cookies.items())});response=connection.getresponse();assert response.status==200,(response.status,response.read());streams.append((connection,response))
  fourth=request('/api/v1/viewers','POST',{'channels':['system']},expected=201)['viewerId'];request('/api/v1/events?viewerId='+fourth,expected=429)
  result=request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'lan-password-12345'});csrf=result['csrfToken'];request('/api/v1/events?viewerId='+viewer_ids[0],expected=404)
  started=time.monotonic();device=control('devices')[0];control('revokeDevice',id=device['id']);request('/api/v1/snapshot',expected=403)
  for connection,response in streams:
   try: response.read()
   except http.client.IncompleteRead: pass
   connection.close()
  assert time.monotonic()-started<5,'Revocation exceeded five seconds'

  ticket=urllib.parse.parse_qs(urllib.parse.urlsplit(control('pair')['url']).fragment)['pair'][0]
  request('/api/v1/pairing/exchange','POST',{'ticket':ticket,'deviceLabel':'shutdown-device'})
  csrf=request('/api/v1/auth/login','POST',{'username':'lan-owner','password':'lan-password-12345'})['csrfToken']
  viewer=request('/api/v1/viewers','POST',{'channels':['system']},expected=201)['viewerId']
  connection=http.client.HTTPSConnection(address.hostname,address.port,timeout=5,context=context)
  connection.request('GET','/api/v1/events?viewerId='+viewer,headers={'Cookie':'; '.join(k+'='+v for k,v in cookies.items())})
  response=connection.getresponse();assert response.status==200,(response.status,response.read())
  started=time.monotonic();control('lan',enabled=False)
  try: response.read()
  except http.client.IncompleteRead: pass
  connection.close();assert time.monotonic()-started<5,'LAN shutdown exceeded IPC deadline'
  assert control('status')['lanAddress']=='', 'LAN address remained after disable'

  print(json.dumps({'lanSmoke':'passed','checks':['CA chain and SAN verification','unpaired rejected','pairing does not log in','combined device/account authentication','Secure HttpOnly cookies','3-stream limit','cross-session viewer rejected','device revocation closes streams within 5s','LAN disable closes active TLS stream within 5s']}))
 finally:
  p.terminate()
  try:p.wait(timeout=7)
  except subprocess.TimeoutExpired:p.kill();p.wait()
