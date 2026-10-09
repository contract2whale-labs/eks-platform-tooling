"""Current query failures and diagnostic ownership; fake CLIs only."""
import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:];case=os.environ['MESH_TEST_CASE']
with Path(os.environ['MESH_TEST_CALLS']).open('a') as output:output.write(json.dumps(a)+'\n')
def respond(text='',failed=False):
 print(text) if text else None
 sys.exit(7 if failed else 0)
if 'delete' in a:respond()
if 'create' in a:respond(failed=case=='create-failed')
if 'rollout' in a:respond()
if 'version' in a:respond('Server Version: v1.36.3-eks-example',case=='version-failed')
if 'get' in a:
 i=a.index('get');kind=a[i+1];tail=a[i+2:]
 if kind=='daemonset':
  if '-A' in a:respond('kube-system/aws-node',case=='daemonsets-failed')
  respond('platform-istio-cni-dev:apps/DaemonSet:istio-system/istio-cni-node',case=='owner-failed')
 if kind=='crd':respond()
 if kind=='namespace':
  if '-l' in a:respond('team-mesh-check')
  if tail and tail[0]=='team-mesh-outside' and 'jsonpath=' in ' '.join(a):respond('ambient' if case=='outside-ambient' else '',case=='outside-query-failed')
  respond('namespace/team-mesh-check\nnamespace/team-mesh-outside')
 if kind=='peerauthentication':respond('default\t\tSTRICT\t')
 if kind=='svc':respond('10.100.12.34',case=='service-query-failed')
 if kind.startswith('deployment/'):
  if '--ignore-not-found' in a:respond(kind if case=='existing' else '',case=='existing-lookup-failed')
  respond('1',case=='readiness-query-failed')
 if kind=='nodes':respond('node/node-a' if 'node/' in ' '.join(a) else 'node-a')
 if kind=='pods':respond('node-a\t\tTrue')
if 'exec' in a:
 if case=='allowed-probe-failed' and 'team-mesh-outside' not in a:respond('partial response',True)
 if 'team-mesh-outside' in a:print('CLOSED: EOF without response; inspect receiver ztunnel logs');sys.exit(1)
 respond('REACHED: HTTP/1.0 200 OK src=10.0.1.5:40000')
if 'logs' in a and case=='partial-log-failed':respond('OLD-PARTIAL-LOG',True)
if 'logs' in a:respond('direction="outbound" src.addr=10.0.1.5:40000 dst.service=mesh-server.team-mesh-check.svc.cluster.local src.identity="spiffe://cluster.local/ns/team-mesh-check/sa/mesh-client" dst.identity="spiffe://cluster.local/ns/team-mesh-check/sa/mesh-server"')
print('Unsupported fake kubectl query',file=sys.stderr);sys.exit(88)
'''
class CurrentQueries(unittest.TestCase):
 def run_case(self,script,case,args=(),extra_env=None):
  with tempfile.TemporaryDirectory(prefix='mesh-local-fixture-') as folder:
   work=Path(folder);mesh=work/'mesh';shutil.copytree(ROOT,mesh,ignore=shutil.ignore_patterns('local-inputs','tests'))
   bindir=work/'bin';bindir.mkdir();fake=bindir/'kubectl';fake.write_text(FAKE);fake.chmod(0o700)
   kustomize=bindir/'kustomize';kustomize.write_text('#!/bin/sh\nexit 0\n');kustomize.chmod(0o700)
   calls=work/'calls.jsonl'
   inputs=mesh/'local-inputs';inputs.mkdir()
   (inputs/'mesh-proxy.log').write_text('STALE-PRIOR-RUN')
   (inputs/'mesh-mtls-evidence.json').write_text('{"stale":true}')
   env=dict(os.environ,PATH=str(bindir)+':'+os.environ['PATH'],MESH_TEST_CASE=case,MESH_TEST_CALLS=str(calls),KUBE_CONTEXT='fixture',PROBE_IMAGE='example.invalid/probe@sha256:'+'a'*64)
   env.update(extra_env or {})
   self.assertTrue(os.access(fake,os.X_OK))
   run=subprocess.run(['bash',str(mesh/'scripts'/script),*args],env=env,capture_output=True,text=True)
   run.evidence_text=(inputs/'mesh-mtls-evidence.json').read_text()
   run.proxy_log=(inputs/'mesh-proxy.log').read_text()
   return run,[json.loads(line) for line in calls.read_text().splitlines()]
 def test_compatibility_partial_output_failures_are_inconclusive(self):
  for case in ['version-failed','daemonsets-failed']:
   with self.subTest(case=case):
    result,_=self.run_case('check-mesh-compat.sh',case,['--context','fixture']);self.assertEqual(result.returncode,2,result.stdout+result.stderr);self.assertIn('MESH_COMPAT_INCONCLUSIVE',result.stdout)
 def test_probe_partial_service_output_failure_is_inconclusive(self):
  result,calls=self.run_case('probe-connect.sh','service-query-failed',['team-mesh-outside','mesh-outside'])
  self.assertEqual(result.returncode,2,result.stdout+result.stderr);self.assertFalse(any('exec' in call for call in calls))
 def test_mtls_valid_plaintext_control(self):
  result,_=self.run_case('check-mesh-mtls.sh','valid');self.assertEqual(result.returncode,0,result.stdout+result.stderr)
 def test_enrolled_outside_is_not_a_plaintext_control(self):
  result,_=self.run_case('check-mesh-mtls.sh','outside-ambient');self.assertEqual(result.returncode,1,result.stdout+result.stderr);self.assertIn('this is not a plaintext control',result.stdout)
 def test_mtls_partial_query_failures_cannot_pass(self):
  for case in ['service-query-failed','readiness-query-failed','outside-query-failed']:
   with self.subTest(case=case):
    result,_=self.run_case('check-mesh-mtls.sh',case);self.assertEqual(result.returncode,2,result.stdout+result.stderr)
 def test_failed_allowed_probe_cannot_reuse_prior_log(self):
  result,calls=self.run_case('check-mesh-mtls.sh','allowed-probe-failed')
  self.assertEqual(result.returncode,2,result.stdout+result.stderr)
  evidence=json.loads(result.evidence_text)
  self.assertEqual(evidence['proxy_log']['status'],'NOT_COLLECTED')
  self.assertEqual(result.proxy_log,'')
  self.assertFalse(any('logs' in call for call in calls))
  self.assertNotIn('stale',evidence)
 def test_partial_failed_log_query_cannot_be_evidence(self):
  result,_=self.run_case('check-mesh-mtls.sh','partial-log-failed')
  self.assertEqual(result.returncode,2,result.stdout+result.stderr)
  self.assertEqual(json.loads(result.evidence_text)['proxy_log']['status'],'QUERY_FAILED')
  self.assertEqual(result.proxy_log,'')
 def test_evidence_json_escapes_external_fields_and_preserves_tuples(self):
  value='fixture"\\line\nwith|pipe'
  result,_=self.run_case('check-mesh-mtls.sh','valid',extra_env={'MESH_NAMESPACE':value,'ENROLLED_NAMESPACES':'missing"\\name|part'})
  evidence=json.loads(result.evidence_text)
  self.assertEqual(evidence['mesh_namespace'],value)
  self.assertEqual(len(evidence['checks']),5)
  enrolled=next(row for row in evidence['checks'] if row['name']=='enrolled-ns')
  self.assertIn('missing"\\name|part',enrolled['detail'])
  self.assertEqual(evidence['verdict'],'FAIL')
 def test_existing_or_failed_probe_lookup_never_mutates(self):
  for case in ['existing','existing-lookup-failed']:
   with self.subTest(case=case):
    result,calls=self.run_case('deploy-probes.sh',case);self.assertEqual(result.returncode,2,result.stdout+result.stderr)
    self.assertFalse(any('create' in call or 'delete' in call or 'apply' in call for call in calls))
 def test_partial_creation_cleans_only_this_run(self):
  result,calls=self.run_case('deploy-probes.sh','create-failed');self.assertEqual(result.returncode,7,result.stdout+result.stderr)
  deletes=[call for call in calls if 'delete' in call];self.assertEqual(len(deletes),2)
  selectors=[call[call.index('-l')+1] for call in deletes];self.assertEqual(len(set(selectors)),1)
  self.assertRegex(selectors[0],r'^platform[.]example/mesh-probe-run=[0-9a-f]{32}$')
  self.assertFalse(any('-f' in call for call in deletes))
if __name__=='__main__':unittest.main()
