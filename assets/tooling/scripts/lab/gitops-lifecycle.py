#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Execute only the reviewed Application scope of an environment lifecycle job."""
import argparse,datetime,json,os,re,subprocess
from pathlib import Path
from validate_lifecycle_request import verify_source

def run(cmd):return subprocess.run(cmd,check=True,text=True,capture_output=True)

def argo_command(context,operation,name):
 # --core uses the same Kubernetes API checked by preflight; no cached Argo server.
 return ['argocd','--core','--kube-context',context,'app',operation,name,'--app-namespace','argocd']

def current_approval(path, baseline, env, context, profile, repo, hook, name):
 current=json.loads(Path(path).read_text())
 if current!=baseline:raise ValueError('lifecycle approval payload changed; stop and obtain a new reviewed request')
 if current.get('environment')!=env or current.get('context')!=context:raise ValueError('current lifecycle environment/context differs')
 if not current.get('change_request') or not current.get('reviewer'):raise ValueError('current reviewed lifecycle approval required')
 expires=datetime.datetime.fromisoformat(current['expires_at'].replace('Z','+00:00'))
 if not expires.tzinfo or datetime.datetime.now(datetime.timezone.utc)>=expires:raise ValueError('current lifecycle approval expired')
 if name not in current.get('hooks',{}).get(hook,[]):raise ValueError('Application absent from current reviewed hook scope')
 if current.get('data_decision') not in ['retain','delete-reviewed']:raise ValueError('current data decision required')
 actual=run(['aws','--profile',profile,'sts','get-caller-identity','--query','Account','--output','text']).stdout.strip()
 if actual!=current['account_id']:raise ValueError('current lifecycle execution account differs')
 revision=verify_source(repo,current.get('approved_revision'))
 if revision!=baseline['approved_revision']:raise ValueError('current source differs from approved lifecycle revision')
 return current


def verify_current_application(before, context, name):
 # This fresh read detects replacement/configuration changes; it is not an
 # atomic UID precondition on the following name-based Argo command. Keep
 # the approved exclusive execution window until the operation completes.
 current=json.loads(run(['kubectl','--context',context,'-n','argocd','get','application',name,'-o','json']).stdout)
 uid=before.get('metadata',{}).get('uid')
 if not uid or current.get('metadata',{}).get('uid')!=uid:raise ValueError('current Application UID differs')
 original=before.get('spec',{}); actual=current.get('spec',{})
 for field in ['source','sources','syncPolicy']:
  if actual.get(field)!=original.get(field):raise ValueError('current Application source/sync policy differs')
 return current


def approved_revisions(sources, revision):
 for source in sources:
  if source.get("chart") and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?",str(source.get("targetRevision",""))):
   raise ValueError("lifecycle chart must use a pinned version")
 return [source["targetRevision"] if source.get("chart") else revision for source in sources]


def verify_completed(before, after, revision):
 if after.get('metadata',{}).get('uid')!=before.get('metadata',{}).get('uid') or not before.get('metadata',{}).get('uid'):
  raise ValueError('completed Application UID differs')
 sources=before['spec'].get('sources') or [before['spec']['source']]
 current_sources=after['spec'].get('sources') or [after['spec']['source']]
 if current_sources!=sources:raise ValueError('completed Application source configuration differs')
 expected=approved_revisions(sources,revision)
 operation=after.get('status',{}).get('operationState',{})
 if operation.get('phase')!='Succeeded':raise ValueError('approved Application operation did not succeed')
 result=operation.get('syncResult',{})
 actual=result.get('revisions') if len(sources)>1 else [result.get('revision')]
 if actual!=expected:raise ValueError('completed operation revision differs from approved source')
 if after.get('status',{}).get('health',{}).get('status')!='Healthy':raise ValueError('completed Application is not Healthy')
 # Current sync.status may be OutOfSync after main advances. It is not the
 # completion evidence for the exact approved operation checked above.


def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['up','down']);p.add_argument('hook');a=p.parse_args()
 env=os.environ['LAB_ENVIRONMENT'];context=os.environ['LAB_KUBE_CONTEXT'];repo=Path(os.environ['INFRA_ROOT'])
 request_path=Path(os.environ['LAB_LIFECYCLE_REQUEST'])
 request=json.loads(request_path.read_text())
 if request['environment']!=env or request['context']!=context:raise ValueError('lifecycle request environment/context differs')
 config=json.loads(run(['kubectl','--context',context,'config','view','--minify','-o','json']).stdout)
 if config['contexts'][0]['context'].get('namespace')!='argocd':raise ValueError('lifecycle core-mode context namespace must be argocd')
 profile=os.environ['AWS_PROFILE'];actual=run(['aws','--profile',profile,'sts','get-caller-identity','--query','Account','--output','text']).stdout.strip()
 if actual!=request['account_id']:raise ValueError('lifecycle request account differs')
 head=verify_source(repo,request.get('approved_revision'))
 if head!=request['approved_revision'] or not re.fullmatch('[0-9a-f]{40}',head):raise ValueError('source differs from approved lifecycle revision')
 if not request.get('change_request') or not request.get('reviewer'):raise ValueError('reviewed lifecycle request required')
 if datetime.datetime.now(datetime.timezone.utc)>=datetime.datetime.fromisoformat(request['expires_at'].replace('Z','+00:00')):raise ValueError('lifecycle approval expired')
 selected=request['hooks'].get(a.hook)
 if selected is None:raise ValueError('hook absent from reviewed scope: '+a.hook)
 for name in selected:
  if not re.fullmatch('[a-z0-9][a-z0-9-]*',name):raise ValueError('invalid Application name')
  result=run(['kubectl','--context',context,'-n','argocd','get','application',name,'--ignore-not-found','-o','json'])
  if not result.stdout.strip():
   if a.action=='down':print(name+': already absent');continue
   raise ValueError('Application absent; bootstrap and register reviewed declaration before resume: '+name)
  app=json.loads(result.stdout)
  policy=app.get('spec',{}).get('syncPolicy',{});automated=policy.get('automated')
  if 'automated' in policy and automated is not None and automated.get('enabled',True) is not False:raise ValueError('automatic sync must be suspended in reviewed Git before lifecycle operation: '+name)
  sources=app['spec'].get('sources') or [app['spec']['source']]
  if any(source.get('chart')=='argo-cd' for source in sources):raise ValueError('retain the Argo controller until every dependent Application has retired; cluster teardown removes the final controller')
  if a.action=='down':
   if request.get('data_decision') not in ['retain','delete-reviewed']:raise ValueError('explicit data preservation decision required')
   timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
   current_approval(request_path,request,env,context,profile,repo,a.hook,name)
   verify_current_application(app,context,name)
   run(['kubectl','--context',context,'-n','argocd','annotate','application',name,'argocd.argoproj.io/deletion-approved='+timestamp,'--overwrite'])
   current_approval(request_path,request,env,context,profile,repo,a.hook,name)
   verify_current_application(app,context,name)
   run(argo_command(context,'delete',name)+['--cascade','--yes','--propagation-policy','foreground'])
  else:
   approved_revisions(sources,head)
   cmd=argo_command(context,'sync',name)
   if len(sources)>1:
    for index,source in enumerate(sources,1):cmd+=['--revisions',source['targetRevision'] if source.get('chart') else head,'--source-positions',str(index)]
   elif not sources[0].get('chart'):cmd+=['--revision',head]
   current_approval(request_path,request,env,context,profile,repo,a.hook,name)
   verify_current_application(app,context,name)
   run(cmd)
   run(argo_command(context,'wait',name)+['--operation','--health','--timeout','900'])
   completed=json.loads(run(['kubectl','--context',context,'-n','argocd','get','application',name,'-o','json']).stdout)
   verify_completed(app,completed,head)
  print(name+': '+a.action+' operation completed; verify actual component/data gates in the runbook')

if __name__=='__main__':main()
