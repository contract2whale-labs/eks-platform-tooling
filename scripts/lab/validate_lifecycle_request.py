#!/usr/bin/env python3
import argparse,datetime,json,os,re,subprocess
from pathlib import Path

def validate(request,environment,account,context,revision,target=None):
 for key,value in {'environment':environment,'account_id':account,'context':context,'approved_revision':revision}.items():
  if request.get(key)!=value:raise ValueError('lifecycle request differs from target '+key)
 if not re.fullmatch('[0-9a-f]{40}',revision):raise ValueError('approved source commit required')
 if not request.get('change_request') or not request.get('reviewer'):raise ValueError('reviewed change request required')
 expires=datetime.datetime.fromisoformat(request['expires_at'].replace('Z','+00:00'))
 if not expires.tzinfo or expires<=datetime.datetime.now(datetime.timezone.utc):raise ValueError('lifecycle approval expired')
 if request.get('data_decision') not in ('retain','delete-reviewed'):raise ValueError('explicit data decision required')
 if target and target not in request.get('terraform_roots',[]):raise ValueError('Terraform root absent from reviewed lifecycle scope: '+target)
 volumes=request.get('delete_volume_ids',[])
 if request['data_decision']=='retain' and volumes:raise ValueError('retain decision cannot approve EBS deletion')
 if not isinstance(volumes,list) or any(not re.fullmatch(r'vol-[0-9a-f]{8,17}',v) for v in volumes):raise ValueError('invalid reviewed volume identity')

def validate_volume(request,volume_id):
 # A saved inventory is evidence of observation, never a continuing deletion approval.
 if request.get('data_decision')!='delete-reviewed':raise ValueError('current approval must explicitly permit EBS deletion')
 if volume_id not in request.get('delete_volume_ids',[]):raise ValueError('volume absent from current reviewed deletion scope: '+volume_id)

def validate_destroy(request,target):
 # Stop a conflicting destroy; this does not implement selective retention.
 if target in ('dev/data','prod/data') and request.get('data_decision')!='delete-reviewed':
  raise ValueError('data root destroy conflicts with current retention decision')

def verify_source(repo,revision):
 head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
 if head!=revision:raise ValueError('source differs from approved lifecycle revision')
 subprocess.run(['git','-C',str(repo),'diff','--quiet','HEAD','--'],check=True)
 untracked=subprocess.check_output(['git','-C',str(repo),'ls-files','--others','--exclude-standard','--','terraform','modules','gitops','automation','bootstrap','.github'],text=True)
 if untracked.strip():raise ValueError('uncommitted source cannot be applied under approved HEAD')
 # ls-files emits individual files even when a parent directory is ignored.
 # Private execution inputs retain their separate approval contract; they are not source.
 ignored=subprocess.check_output(['git','-C',str(repo),'ls-files','--others','--ignored','--exclude-standard','-z','--','terraform','modules','gitops','automation','bootstrap','.github'],text=True)
 caches={'.terraform','__pycache__','.pytest_cache','.mypy_cache','.ruff_cache'}
 for name in ignored.split('\0'):
  if not name:continue
  path=Path(name)
  if any(part in caches for part in path.parts):continue
  if path.parts[0]=='terraform' and (path.name=='backend.hcl' or path.name.endswith(('.tfvars','.tfvars.json','.tfstate','.tfstate.backup','.tfplan'))):continue
  raise ValueError('ignored uncommitted source cannot be applied under approved HEAD: '+name)
 return head

def verify_cluster(request,profile):
 if not request.get('cluster_name'):raise ValueError('reviewed EKS cluster name required')
 endpoint=subprocess.check_output(['aws','--profile',profile,'--region',os.environ.get('AWS_REGION','ap-northeast-2'),'eks','describe-cluster','--name',request['cluster_name'],'--query','cluster.endpoint','--output','text'],text=True).strip()
 config=json.loads(subprocess.check_output(['kubectl','--context',request['context'],'config','view','--minify','-o','json'],text=True))
 cluster=config['clusters'][0]['cluster']
 if cluster.get('server')!=endpoint or cluster.get('insecure-skip-tls-verify') or not (cluster.get('certificate-authority-data') or cluster.get('certificate-authority')):
  raise ValueError('lifecycle Kubernetes API differs from the approved account EKS endpoint')

def main():
 p=argparse.ArgumentParser();p.add_argument('--request',type=Path,required=True);p.add_argument('--environment',required=True);p.add_argument('--account',required=True);p.add_argument('--context',required=True);p.add_argument('--repo',type=Path,required=True);p.add_argument('--target');p.add_argument('--destroy',action='store_true');p.add_argument('--verify-cluster',action='store_true');p.add_argument('--volume-id');a=p.parse_args()
 request=json.loads(a.request.read_text())
 revision=verify_source(a.repo,request.get('approved_revision'))
 validate(request,a.environment,a.account,a.context,revision,a.target)
 if a.destroy:validate_destroy(request,a.target)
 if a.volume_id:validate_volume(request,a.volume_id)
 if a.verify_cluster:
  import os
  verify_cluster(request,os.environ['AWS_PROFILE'])
if __name__=='__main__':main()
