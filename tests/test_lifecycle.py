import datetime,importlib.util,json,sys,unittest
from unittest.mock import patch
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts/lab'))
def load(name,file):
 spec=importlib.util.spec_from_file_location(name,ROOT/'scripts/lab'/file);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
guard=load('request_guard','validate_lifecycle_request.py');validate=guard.validate
lifecycle=load('lifecycle','gitops-lifecycle.py')
class LifecycleBoundaryTests(unittest.TestCase):
 def request(self):return {'environment':'dev','account_id':'111111111111','context':'dev-private-api','approved_revision':'a'*40,'change_request':'CHANGE-123','reviewer':'reviewer','expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).isoformat(),'data_decision':'retain','delete_volume_ids':[],'terraform_roots':['dev/eks']}
 def test_other_environment_or_account_rejected(self):
  for key,value in [('environment','prod'),('account_id','222222222222'),('context','prod-private-api')]:
   request=self.request();request[key]=value
   with self.assertRaises(ValueError):validate(request,'dev','111111111111','dev-private-api','a'*40,'dev/eks')
 def test_unreviewed_root_rejected(self):
  with self.assertRaises(ValueError):validate(self.request(),'dev','111111111111','dev-private-api','a'*40,'dev/data')
 def test_retain_cannot_delete_volume(self):
  request=self.request();request['delete_volume_ids']=['vol-0123456789abcdef0']
  with self.assertRaises(ValueError):validate(request,'dev','111111111111','dev-private-api','a'*40)
 def test_expired_request_rejected(self):
  request=self.request();request['expires_at']='2020-01-01T00:00:00Z'
  with self.assertRaises(ValueError):validate(request,'dev','111111111111','dev-private-api','a'*40)
 def test_all_argo_mutations_use_checked_kubernetes_context(self):
  for operation in ['delete','sync','wait']:
   cmd=lifecycle.argo_command('dev-private-api',operation,'platform-gateway-dev')
   self.assertIn('--core',cmd);self.assertEqual(cmd[cmd.index('--kube-context')+1],'dev-private-api');self.assertEqual(cmd[cmd.index('--app-namespace')+1],'argocd');self.assertNotIn('--server',cmd)
 def test_context_name_alone_cannot_hide_wrong_cluster_endpoint(self):
  request=self.request();request['cluster_name']='dev-eks'
  answers=['https://expected-dev-eks',json.dumps({'clusters':[{'cluster':{'server':'https://wrong-prod-eks','certificate-authority-data':'fixture'}}]})]
  with patch.object(guard.subprocess,'check_output',side_effect=answers),self.assertRaises(ValueError):guard.verify_cluster(request,'dev-sso')
 def test_cleanup_runs_after_hooks_before_core_and_cluster_deletion(self):
  rows=[l.split('\t') for l in (ROOT/'scripts/lab/steps.tsv').read_text().splitlines() if l and not l.startswith('#')]
  for environment in ['dev','prod']:
   cleanup=next(float(r[0]) for r in rows if r[2]=='k8s-clean' and r[4]==environment)
   self.assertGreater(cleanup,next(float(r[0]) for r in rows if r[3]==environment+'/platform/core'))
   self.assertLess(cleanup,min(float(r[0]) for r in rows if r[2]=='hook' and r[4]==environment))
   self.assertGreater(cleanup,next(float(r[0]) for r in rows if r[3]==environment+'/eks'))
if __name__=='__main__':unittest.main()
