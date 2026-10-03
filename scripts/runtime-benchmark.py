#!/usr/bin/env python3
"""Measure the actual Release Agent. Developer tool; does not install a daemon."""
import argparse,http.client,json,pathlib,platform,re,resource,socket,subprocess,tempfile,time,urllib.parse
p=argparse.ArgumentParser();p.add_argument('--duration',type=int,default=1800);p.add_argument('--warmup',type=int,default=300);p.add_argument('--clients',type=int,choices=[0,1,3],default=0);p.add_argument('--agent',default='.build/'+platform.machine()+'-apple-macosx/release/MonitorAgent');args=p.parse_args()
assert 1<=args.duration<=86400 and 0<=args.warmup<=3600
project=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='cmm-benchmark.',dir='/private/tmp') as root:
 streams=[];agent=subprocess.Popen([str(project/args.agent),'--data-root',root,'--web-root',str(project/'web/dist'),'--port','0'],stderr=subprocess.PIPE,text=True)
 try:
  line=agent.stderr.readline();base=line.split('ready at ')[1].strip();port=urllib.parse.urlsplit(base).port
  def control(command,**kw):
   with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(5);s.connect(root+'/run/control.sock');s.sendall(json.dumps({'command':command,**kw}).encode()+b'\n');value=b''
    while not value.endswith(b'\n'):value+=s.recv(65536)
    return json.loads(value)
  ticket=urllib.parse.parse_qs(urllib.parse.urlsplit(control('setup')['url']).fragment)['setup'][0]
  cookies={};csrf=''
  def request(path,method='GET',body=None):
   c=http.client.HTTPConnection('127.0.0.1',port,timeout=5);headers={'Origin':base,'Cookie':'; '.join(k+'='+v for k,v in cookies.items()),'Content-Type':'application/json','X-CSRF-Token':csrf};c.request(method,'/api/v1'+path,json.dumps(body) if body else None,headers);r=c.getresponse();data=r.read();assert r.status in [200,201,204],data
   for name,value in r.getheaders():
    if name.lower()=='set-cookie':key,token=value.split(';')[0].split('=',1);cookies[key]=token
   c.close();return json.loads(data) if data else None
  csrf=request('/auth/setup','POST',{'setupTicket':ticket,'username':'benchmark','password':'benchmark-password-12345'})['csrfToken']
  ids=[]
  for _ in range(args.clients):
   viewer=request('/viewers','POST',{'channels':['system','apps']})['viewerId'];ids.append(viewer);streams.append(subprocess.Popen(['/usr/bin/curl','--silent','--no-buffer','--cookie','; '.join(k+'='+v for k,v in cookies.items()),base+'/api/v1/events?viewerId='+viewer],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
  samples=[];started=time.monotonic();previous=time.monotonic();sequence_start=None;initial_usage=None;last_renew=started
  while time.monotonic()-started<args.warmup+args.duration:
   now=time.monotonic()
   if now-last_renew>=15:
    for viewer in ids:request('/viewers/'+viewer,'PATCH',{'visible':True,'channels':['system','apps']})
    last_renew=now
   if now-started>=args.warmup:
    snapshot=request('/snapshot');apps=request('/apps?limit=1')
    if sequence_start is None:sequence_start=int(apps['scanSequence'])
    output=subprocess.check_output(['/bin/ps','-p',str(agent.pid),'-o','%cpu=,rss='],text=True).split()
    samples.append({'cpuCorePercent':snapshot.get('serviceOverhead',{}).get('cpuPercentCore',0),'rssBytes':int(output[1])*1024,'footprintBytes':snapshot.get('serviceOverhead',{}).get('physicalFootprintBytes'),'time':now-started,'scanSequence':int(apps['scanSequence'])})
   deadline=previous+1;time.sleep(max(0,deadline-time.monotonic()));previous=deadline
  def percentile(values,percent):values=sorted(v for v in values if v is not None);return values[min(len(values)-1,int((len(values)-1)*percent))]
  history=control('status')['history'];control('prepareStop');report={'scenario':'actualAgent-'+str(args.clients)+'-loopback-viewers','build':'Release','durationSeconds':args.duration,'warmupSeconds':args.warmup,'cpuMeanCorePercent':sum(s['cpuCorePercent'] for s in samples)/len(samples),'cpuP95CorePercent':percentile([s['cpuCorePercent'] for s in samples],.95),'footprintP95Bytes':percentile([s['footprintBytes'] for s in samples],.95),'rssP95Bytes':percentile([s['rssBytes'] for s in samples],.95),'processScansObserved':samples[-1]['scanSequence']-sequence_start,'history':history,'gateStatus':'notValidated','limitations':['Measurement issues one authenticated snapshot/apps request per second; this is additional observer traffic','No browser baseline, mobile hardware or physical write amplification is measured','M1 reference-machine three-run and 24h gates remain user acceptance']};print(json.dumps(report))
 finally:
  for stream in streams:stream.terminate()
  agent.terminate()
  try:agent.wait(timeout=7)
  except subprocess.TimeoutExpired:agent.kill();agent.wait()
