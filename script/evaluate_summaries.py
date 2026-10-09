#!/usr/bin/env python3
import json,pathlib,re,time,urllib.request
root=pathlib.Path(__file__).resolve().parents[1]
prior=json.loads((root/'.local-data/model-evaluation.json').read_text())
source=(root/'Sources/TalkieCore/EditingPolicy.swift').read_text()
prompt='\n'.join(x.strip() for x in re.findall(r'public static let prompt = """\n(.*?)\n    """',source,re.S)[1].splitlines())
item={'type':'object','properties':{'text':{'type':'string'},'references':{'type':'array','items':{'type':'string'}},'owner':{'type':['string','null']},'deadline':{'type':['string','null']}},'required':['text','references','owner','deadline'],'additionalProperties':False}
keys=['overview','discussion','decisions','actions','questions']
schema={'type':'object','properties':{k:{'type':'array','items':item} for k in keys},'required':keys,'additionalProperties':False}
results=[]
for model in prior['models']:
    body={'model':model['name'],'stream':False,'think':False,'keep_alive':0,'format':schema,'options':{'temperature':0,'seed':42,'num_ctx':8192,'num_predict':2048},'messages':[{'role':'system','content':prompt},{'role':'user','content':json.dumps(model['summary']['input'],ensure_ascii=False)}]}
    request=urllib.request.Request('http://127.0.0.1:11434/api/chat',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    start=time.monotonic()
    with urllib.request.urlopen(request,timeout=240) as response: out=json.load(response)
    results.append({'model':model['name'],'digest':model['digest'],'prompt_version':'grounded-summary-v2','latency':time.monotonic()-start,'response':out})
    (root/'.local-data/summary-v2-evaluation.json').write_text(json.dumps(results,indent=2,ensure_ascii=False)+'\n')
    print(model['name'],out['message']['content'],flush=True)
