# -*- coding: utf-8 -*-
"""Local regressions: every AWS command is replaced by a shell fixture."""
import datetime, importlib.util, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('guard',ROOT/'scripts/lab/validate_lifecycle_request.py')
guard=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(guard)
VOLUME='vol-0123456789abcdef0'
class CurrentApprovalTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.home=Path(self.tmp.name)
  self.repo=self.home/'repo';self.repo.mkdir()
  for cmd in [['init','-q'],['config','user.email','fixture@example.invalid'],['config','user.name','Fixture'],['commit','--allow-empty','-qm','fixture']]:subprocess.run(['git','-C',str(self.repo)]+cmd,check=True,capture_output=True)
  self.revision=subprocess.check_output(['git','-C',str(self.repo),'rev-parse','HEAD'],text=True).strip()
  self.request={'environment':'dev','account_id':'111111111111','context':'dev-private-api','approved_revision':self.revision,'change_request':'CHANGE-123','reviewer':'fixture','expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).isoformat(),'data_decision':'delete-reviewed','delete_volume_ids':[VOLUME],'terraform_roots':['dev/eks']}
  self.path=self.home/'request.json';self.path.write_text(json.dumps(self.request))
 def shell(self,mode):
  (self.home/'volumes-dev.txt').write_text(VOLUME+'\n')
  # Source definitions only; main and preflight never run.
  source=(ROOT/'scripts/lab/lab.sh').read_text().rsplit('main "$@"',1)[0]
  script=self.home/'fixture.sh';script.write_text(source+'''\n
LAB_DIR="$FIXTURE_LAB_DIR"
LAB_HOME="$FIXTURE_HOME"
INFRA_ROOT="$FIXTURE_REPO"
DEV_ACCOUNT_ID=111111111111
DEV_KUBE_CONTEXT=dev-private-api
AWS_REGION=ap-northeast-2
LAB_LIFECYCLE_REQUEST="$FIXTURE_REQUEST"
log() { :; }
run() { "$@"; }
sleep() { :; }
aws() {
  printf '%s\\n' "$*" >> "$FIXTURE_HOME/aws-calls.txt"
  if [ "$2" = describe-volumes ]; then
    case "$FIXTURE_MODE" in
      missing) echo 'InvalidVolume.NotFound' >&2; return 1 ;;
      error) echo 'AccessDenied' >&2; return 1 ;;
      revoke-during-query) python3 -c 'import json,os; p=os.environ["FIXTURE_REQUEST"]; r=json.load(open(p)); r["delete_volume_ids"]=[]; json.dump(r,open(p,"w"))' ;;
    esac
    printf 'available\\n'
  fi
}
step_vol_clean dev
''')
  env=dict(os.environ,FIXTURE_HOME=str(self.home),FIXTURE_REPO=str(self.repo),FIXTURE_REQUEST=str(self.path),FIXTURE_MODE=mode,FIXTURE_LAB_DIR=str(ROOT/"scripts/lab"),PATH=str(Path(sys.executable).parent)+":"+os.environ["PATH"])
  return subprocess.run(['bash',str(script)],env=env,text=True,capture_output=True)
 def test_saved_inventory_rejected_after_scope_shrink_or_retain(self):
  for decision in ['delete-reviewed','retain']:
   with self.subTest(decision=decision):
    self.request.update(data_decision=decision,delete_volume_ids=[]);self.path.write_text(json.dumps(self.request))
    result=self.shell('available');self.assertNotEqual(result.returncode,0);self.assertTrue((self.home/'volumes-dev.txt').exists());self.assertFalse((self.home/'aws-calls.txt').exists())
 def test_revocation_during_query_stops_before_delete(self):
  result=self.shell('revoke-during-query');self.assertNotEqual(result.returncode,0);self.assertNotIn('delete-volume',(self.home/'aws-calls.txt').read_text());self.assertTrue((self.home/'volumes-dev.txt').exists())
 def test_approved_delete_and_already_absent_retry(self):
  for mode in ['available','missing']:
   with self.subTest(mode=mode):
    result=self.shell(mode);self.assertEqual(result.returncode,0,result.stderr);self.assertFalse((self.home/'volumes-dev.txt').exists())
 def test_query_failure_retains_inventory(self):
  result=self.shell('error');self.assertNotEqual(result.returncode,0);self.assertTrue((self.home/'volumes-dev.txt').exists());self.assertNotIn('delete-volume',(self.home/'aws-calls.txt').read_text())
 def test_query_error_evidence_is_preserved_across_retries(self):
  for attempt in [1,2]:
   result=self.shell('error');self.assertNotEqual(result.returncode,0)
   files=list(self.home.glob('volume-query-dev-*-attempt-*.??????'))
   self.assertEqual(len(files),attempt)
   for path in files:
    self.assertEqual(path.read_text(),'AccessDenied\n')
    self.assertEqual(path.stat().st_mode & 0o777,0o600)
 def test_reapproval_after_denial_allows_retry(self):
  self.request['delete_volume_ids']=[];self.path.write_text(json.dumps(self.request));self.assertNotEqual(self.shell('available').returncode,0)
  self.request['delete_volume_ids']=[VOLUME];self.path.write_text(json.dumps(self.request));self.assertEqual(self.shell('available').returncode,0)
 def test_untracked_apply_source_rejected(self):
  (self.repo/'modules').mkdir();(self.repo/'modules/addons.tf').write_text('# unreviewed source')
  with self.assertRaises(ValueError):guard.verify_source(self.repo,self.revision)
 def test_data_destroy_requires_current_delete_decision(self):
  for target in ['dev/data','prod/data']:
   with self.subTest(target=target):
    self.request['data_decision']='retain'
    with self.assertRaises(ValueError):guard.validate_destroy(self.request,target)
    self.request['data_decision']='delete-reviewed'
    guard.validate_destroy(self.request,target)
    self.request['data_decision']='retain'
    with self.assertRaises(ValueError):guard.validate_destroy(self.request,target)
  guard.validate_destroy(self.request,'dev/eks')
 def test_data_destroy_blocked_before_terraform_initialization(self):
  self.request.update(data_decision='retain',delete_volume_ids=[],terraform_roots=['dev/data'])
  self.path.write_text(json.dumps(self.request))
  source=(ROOT/'scripts/lab/lab.sh').read_text().rsplit('main "$@"',1)[0]
  script=self.home/'destroy-fixture.sh'
  script.write_text(source+'\n'+ '\n'.join([
   'LAB_DIR="$FIXTURE_LAB_DIR"','LAB_HOME="$FIXTURE_HOME"','INFRA_ROOT="$FIXTURE_REPO"',
   'DEV_ACCOUNT_ID=111111111111','LAB_ENVIRONMENT=dev','LAB_KUBE_CONTEXT=dev-private-api',
   'LAB_LIFECYCLE_REQUEST="$FIXTURE_REQUEST"','DRY_RUN=0',
   'tf_init() { touch "$FIXTURE_HOME/terraform-ran"; return 97; }',
   'step_tf_down dev/data supported'
  ])+'\n')
  env=dict(os.environ,FIXTURE_HOME=str(self.home),FIXTURE_REPO=str(self.repo),FIXTURE_REQUEST=str(self.path),FIXTURE_LAB_DIR=str(ROOT/'scripts/lab'))
  result=subprocess.run(['bash',str(script)],env=env,text=True,capture_output=True)
  self.assertNotEqual(result.returncode,0,result.stderr)
  self.assertIn('retention decision',result.stderr)
  self.assertFalse((self.home/'terraform-ran').exists())
 def test_expired_current_request_rejected_before_aws(self):
  self.request['expires_at']='2020-01-01T00:00:00Z';self.path.write_text(json.dumps(self.request))
  self.assertNotEqual(self.shell('available').returncode,0);self.assertFalse((self.home/'aws-calls.txt').exists())
 def execute_fixture(self,action,kind,completed=False):
  source=(ROOT/'scripts/lab/lab.sh').read_text().rsplit('main "$@"',1)[0]
  progress=self.home/('progress-'+action+'-control-plane.list')
  if completed:progress.write_text(kind+':dev:dev/eks\n')
  script=self.home/'execute-fixture.sh'
  script.write_text(source+"\n"+"\n".join([
   'LAB_DIR="$FIXTURE_LAB_DIR"', 'LAB_HOME="$FIXTURE_HOME"', 'INFRA_ROOT="$FIXTURE_REPO"',
   'DEV_ACCOUNT_ID=111111111111', 'DEV_KUBE_CONTEXT=dev-private-api', 'DEV_PROFILE=fixture',
   'AWS_REGION=ap-northeast-2', 'LAB_LIFECYCLE_REQUEST="$FIXTURE_REQUEST"',
   'ACTION="$FIXTURE_ACTION"', 'TARGET_CHAPTER=control-plane',
   'STEPS="$(printf \'1\\tcontrol-plane\\t%s\\tdev/eks\\tdev\\tsupported\\n\' "$FIXTURE_KIND")"',
   'log() { :; }', 'step_tf_down() { touch "$FIXTURE_HOME/step-ran"; }',
   'aws() { echo "unexpected aws" >&2; return 97; }', 'kubectl() { echo "unexpected kubectl" >&2; return 98; }',
   'execute'
  ])+"\n")
  env=dict(os.environ,FIXTURE_HOME=str(self.home),FIXTURE_REPO=str(self.repo),FIXTURE_REQUEST=str(self.path),FIXTURE_LAB_DIR=str(ROOT/'scripts/lab'),FIXTURE_ACTION=action,FIXTURE_KIND=kind,PATH=str(Path(sys.executable).parent)+":"+os.environ['PATH'])
  return subprocess.run(['bash',str(script)],env=env,text=True,capture_output=True)
 def test_completed_progress_still_rejects_expired_approval(self):
  self.request['expires_at']='2020-01-01T00:00:00Z';self.path.write_text(json.dumps(self.request))
  result=self.execute_fixture('down','tf',completed=True)
  self.assertNotEqual(result.returncode,0);self.assertIn('expired',result.stderr);self.assertFalse((self.home/'step-ran').exists())
 def test_completed_progress_with_current_approval_skips_step(self):
  result=self.execute_fixture('down','tf',completed=True)
  self.assertEqual(result.returncode,0,result.stderr);self.assertFalse((self.home/'step-ran').exists())
 def test_up_cleanup_noop_does_not_require_restored_cluster_or_request(self):
  self.path.unlink()
  for kind in ['k8s-clean','vol-clean']:
   result=self.execute_fixture('up',kind)
   self.assertEqual(result.returncode,0,result.stderr)
 def test_dirty_tracked_source_and_other_approved_head_rejected(self):
  f=self.repo/'approved.tf';f.write_text('# approved')
  subprocess.run(['git','-C',str(self.repo),'add','approved.tf'],check=True)
  subprocess.run(['git','-C',str(self.repo),'commit','-qm','approved source'],check=True)
  head=subprocess.check_output(['git','-C',str(self.repo),'rev-parse','HEAD'],text=True).strip()
  with self.assertRaises(ValueError):guard.verify_source(self.repo,self.revision)
  f.write_text('# unreviewed change')
  with self.assertRaises(subprocess.CalledProcessError):guard.verify_source(self.repo,head)
 def test_up_noop_precedes_validation_and_kubeconfig_precedes_api_verification(self):
  source=(ROOT/'scripts/lab/lab.sh').read_text();body=source[source.index('execute() {'):source.index('cmd_down() {')]
  self.assertLess(body.index('up:k8s-clean|up:vol-clean'),body.index('--verify-cluster'))
  self.assertLess(body.index('prepare_restored_kubeconfig'),body.index('--verify-cluster'))
  self.assertLess(body.index('validate_lifecycle_request.py'),body.index('건너뜀 (완료된 단계)'))
 def test_failed_plan_and_post_apply_retries_preserve_each_attempt(self):
  for action in ['up','down']:
   for failure in ['plan','post-apply']:
    with self.subTest(action=action,failure=failure):
     plans=self.home/'plans';plans.mkdir(exist_ok=True)
     legacy=plans/(action+'-dev_eks.tfplan');legacy.write_text('legacy reviewed plan')
     source=(ROOT/'scripts/lab/lab.sh').read_text().rsplit('main "$@"',1)[0]
     script=self.home/'plan-preservation-fixture.sh'
     script.write_text(source+'\n'+ '\n'.join([
      'LAB_HOME="$FIXTURE_HOME"','INFRA_ROOT="$FIXTURE_REPO"','DRY_RUN=0',
      'tf_init() { :; }','validate_lifecycle_for_root() { :; }',
      'plan_count() { printf "0\\n"; }','managed_count() { printf "1\\n"; }',
      'plan_exit_code() { printf "2\\n"; }',
      'git() { printf "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n"; }',
      'python3() { if [ "$1" = -c ]; then "$FIXTURE_PYTHON" "$@"; else printf "fixture approval" > "${@: -1}"; fi; }',
      'terraform() { if [ "$2" = plan ]; then for argument in "$@"; do case "$argument" in -out=*) printf "%s" "$FIXTURE_CONTENT" > "${argument#-out=}" ;; esac; done; [ "$FIXTURE_FAILURE" != plan ]; fi; }',
      'run() { "$@" || die "fixture command failure"; }','log() { :; }',
      'step_tf_'+action+' dev/eks supported','touch "$FIXTURE_HOME/unexpected-success"'
     ])+'\n')
     recorded={}
     for attempt in [1,2]:
      env=dict(os.environ,FIXTURE_HOME=str(self.home),FIXTURE_REPO=str(self.repo),FIXTURE_PYTHON=sys.executable,FIXTURE_FAILURE=failure,FIXTURE_CONTENT=f'{action}-{failure}-attempt-{attempt}')
      before=set(plans.glob(action+'-dev_eks-*.tfplan'))
      result=subprocess.run(['bash',str(script)],input='dev/eks\n',env=env,text=True,capture_output=True)
      self.assertNotEqual(result.returncode,0,result.stderr)
      added=set(plans.glob(action+'-dev_eks-*.tfplan'))-before
      self.assertEqual(len(added),1)
      current=added.pop();recorded[current]=env['FIXTURE_CONTENT']
      for path,content in recorded.items():self.assertEqual(path.read_text(),content)
      if failure=='post-apply':
       for path in recorded:self.assertEqual(Path(str(path)+'.approval.json').read_text(),'fixture approval')
      self.assertEqual(legacy.read_text(),'legacy reviewed plan')
      self.assertFalse((self.home/'unexpected-success').exists())
      if failure=='post-apply':self.assertTrue(Path(str(current)+'.approval.json').exists())
      else:self.assertFalse(Path(str(current)+'.approval.json').exists())
 def test_uuid_generation_failure_stops_before_plan(self):
  source=(ROOT/'scripts/lab/lab.sh').read_text().rsplit('main "$@"',1)[0]
  script=self.home/'uuid-failure.sh'
  script.write_text(source+'\n'+ '\n'.join([
   'LAB_HOME="$FIXTURE_HOME"','INFRA_ROOT="$FIXTURE_REPO"',
   'tf_init() { :; }','validate_lifecycle_for_root() { :; }','managed_count() { printf "1\\n"; }',
   'python3() { return 91; }','run() { touch "$FIXTURE_HOME/unexpected-plan"; }',
   'step_tf_"$FIXTURE_ACTION" dev/eks supported'
  ])+'\n')
  for action in ['up','down']:
   result=subprocess.run(['bash',str(script)],env=dict(os.environ,FIXTURE_HOME=str(self.home),FIXTURE_REPO=str(self.repo),FIXTURE_ACTION=action),text=True,capture_output=True)
   self.assertNotEqual(result.returncode,0)
   self.assertIn('attempt ID generation failed',result.stderr)
   self.assertFalse((self.home/'unexpected-plan').exists())
class IgnoredSourceApprovalTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.repo=Path(self.tmp.name)/'repo';self.repo.mkdir()
  for args in [['init','-q'],['config','user.email','fixture@example.invalid'],['config','user.name','Fixture']]:
   subprocess.run(['git','-C',str(self.repo)]+args,check=True,capture_output=True)
  (self.repo/'.gitignore').write_text('terraform/\nmodules/\ngitops/\nautomation/\nbootstrap/\n.github/\n')
  subprocess.run(['git','-C',str(self.repo),'add','.gitignore'],check=True,capture_output=True)
  subprocess.run(['git','-C',str(self.repo),'commit','-qm','approved ignore fixture'],check=True,capture_output=True)
  self.revision=subprocess.check_output(['git','-C',str(self.repo),'rev-parse','HEAD'],text=True).strip()
 def put(self,name):
  path=self.repo/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
  return path
 def test_ignored_parent_directory_cannot_hide_actual_source(self):
  for name in ['terraform/environments/dev/eks/main.tf','modules/nested/node-iam.tf','gitops/platform/policy.yaml','automation/nested/publish.py','bootstrap/argocd/bootstrap.py','.github/workflows/ci.yml']:
   with self.subTest(name=name):
    path=self.put(name)
    with self.assertRaisesRegex(ValueError,'ignored uncommitted source'):guard.verify_source(self.repo,self.revision)
    path.unlink()
 def test_private_inputs_and_cache_are_not_source(self):
  for name in ['terraform/environments/dev/eks/backend.hcl','terraform/environments/dev/eks/terraform.tfvars','terraform/environments/dev/eks/nodes.auto.tfvars','terraform/environments/dev/eks/terraform.tfvars.json','terraform/environments/dev/eks/terraform.tfstate','terraform/environments/dev/eks/terraform.tfstate.backup','terraform/environments/dev/eks/reviewed.tfplan','terraform/environments/dev/eks/.terraform/providers/plugin','automation/__pycache__/module.pyc']:
   self.put(name)
  self.assertEqual(guard.verify_source(self.repo,self.revision),self.revision)
 def test_private_input_alongside_ignored_source_does_not_allow_source(self):
  self.put('terraform/environments/dev/eks/backend.hcl')
  self.put('terraform/environments/dev/eks/nested/main.tf')
  with self.assertRaisesRegex(ValueError,'ignored uncommitted source'):guard.verify_source(self.repo,self.revision)
 def test_ignored_lockfile_and_example_inputs_require_approved_source(self):
  for name in ['terraform/environments/dev/eks/.terraform.lock.hcl','terraform/environments/dev/eks/backend.hcl.example','terraform/environments/dev/eks/terraform.tfvars.example','gitops/platform/backend.hcl','modules/ignored.tfvars']:
   with self.subTest(name=name):
    path=self.put(name)
    with self.assertRaisesRegex(ValueError,'ignored uncommitted source'):guard.verify_source(self.repo,self.revision)
    path.unlink()
if __name__=='__main__':unittest.main()
