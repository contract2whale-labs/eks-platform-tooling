#!/usr/bin/env python3
import json,os,re,subprocess
from importlib.metadata import version
from pathlib import Path

COMMANDS={
 'gh':['gh','--version'],
 'session-manager-plugin':['session-manager-plugin','--version'],
 'terraform':['terraform','version','-json'], 'helm':['helm','version','--short'],
 'kubectl':['kubectl','version','--client','-o','json'],'kustomize':['kustomize','version'],
 'awscli':['aws','--version'],'argocd':['argocd','version','--client','--short'],
 'argo-rollouts':['kubectl-argo-rollouts','version','--short'],'kubeconform':['kubeconform','-v'],
 'cosign':['cosign','version'],'syft':['syft','version'],'trivy':['trivy','--version'],
 'istioctl':['istioctl','version','--remote=false'],'nodejs':['node','--version'],'golang':['go','version'],
 'kyverno':['kyverno','version'],'actionlint':['actionlint','-version'],'tflint':['tflint','--version'],'zizmor':['zizmor','--version'],'yq':['yq','--version'],'promtool':['promtool','--version']}

def main():
 if os.environ.get("GITHUB_ACTIONS")=="true" and not re.fullmatch(r"ghcr\.io/[a-z0-9._-]+/platform-toolchain@sha256:[0-9a-f]{64}",os.environ.get("TOOLCHAIN_IMAGE","")):
  raise SystemExit("CI toolchain must use the reviewed immutable image digest")
 lock=json.loads((Path(__file__).resolve().parents[1]/'tooling/toolchain.lock.json').read_text())
 for tool in lock['tools']:
  result=subprocess.run(COMMANDS[tool['name']],capture_output=True,text=True,check=True)
  if not re.search(r'(?<![0-9])'+re.escape(tool['version'])+r'(?![0-9])',result.stdout+result.stderr):
   raise SystemExit('wrong tool version: '+tool['name'])
  print(tool['name']+' '+tool['version'])
 for name,want in re.findall(r'^([A-Za-z0-9._-]+)==([^\s\\]+)',(Path(__file__).resolve().parents[1]/'tooling/requirements.lock').read_text(),re.M):
  if version(name)!=want:raise SystemExit('wrong Python dependency version: '+name)
  print('python-library '+name+' '+want)

if __name__=='__main__':main()
