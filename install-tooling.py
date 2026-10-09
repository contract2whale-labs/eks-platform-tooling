#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Install reviewed supporting tools under an exclusive maintenance window.
Course resources are authored per lesson. Existing-file compare/replace is not
a concurrent-writer lock; stop other writers before --replace-reviewed.
"""
import argparse, hashlib, json, os, stat, tempfile
from pathlib import Path

PACKAGE=Path(__file__).resolve().parent
SUPPORT=('automation/','schemas/','tooling/','.devcontainer/','.github/','tests/platform-inputs/','tests/platform-contracts/','tests/bootstrap/','tests/lifecycle/','tests/incidents/','tests/observability/','bootstrap/')

def safe(root,relative):
    p=Path(relative)
    if p.is_absolute() or '..' in p.parts:raise ValueError('unsafe package path')
    target=root/p
    if target.is_symlink() or any(x.is_symlink() for x in target.parents if x!=root.parent):raise ValueError('symlink path is forbidden')
    return target

def digest(data):
    return hashlib.sha256(data).hexdigest()

def exclusive_file(path, data, mode):
    # O_EXCL rejects regular files and even dangling symlinks. Never truncate them.
    fd=os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, 'wb') as output:
        os.fchmod(output.fileno(), mode)
        output.write(data)

def install_write(source, target, data, mode, previous):
    # Revalidate the sealed source and target after preflight. The caller must
    # hold an exclusive maintenance window: replacement of an existing file
    # has a non-atomic compare/replace interval and is not a concurrent writer lock.
    if source.is_symlink() or digest(source.read_bytes()) != digest(data):
        raise ValueError('package source changed after preflight: '+str(source))
    safe(target.parent, target.name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if previous is None:
        if target.exists() or target.is_symlink():
            raise ValueError('new target appeared after preflight: '+str(target))
    else:
        if not target.is_file() or target.is_symlink() or digest(target.read_bytes()) != digest(previous):
            raise ValueError('reviewed target changed after preflight: '+str(target))
        old_mode=stat.S_IMODE(target.stat().st_mode)
        backup=target.with_name(target.name+'.before-course-update')
        exclusive_file(backup, previous, old_mode)
    tmp=None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
            output.write(data)
            tmp=Path(output.name)
        tmp.chmod(mode)
        safe(target.parent, target.name)
        if previous is None:
            # link is atomic create-only, so a late collision cannot be replaced.
            os.link(tmp, target)
        else:
            if not target.is_file() or target.is_symlink() or digest(target.read_bytes()) != digest(previous):
                raise ValueError('reviewed target changed before replacement: '+str(target))
            os.replace(tmp, target)
    finally:
        if tmp is not None and tmp.exists():tmp.unlink()

def main():
    p=argparse.ArgumentParser();p.add_argument('--tooling-root',type=Path,required=True);p.add_argument('--infra-root',type=Path);p.add_argument('--replace-reviewed',action='store_true');a=p.parse_args()
    manifest=json.loads((PACKAGE/'assets-manifest.json').read_text())
    actual={str(x.relative_to(PACKAGE)) for x in (PACKAGE/'assets').rglob('*') if x.is_file()}
    if actual!=set(manifest['files']):raise ValueError('package file set differs from sealed manifest')
    snapshots={}
    for name,expected_digest in manifest['files'].items():
        source=safe(PACKAGE,name)
        data=source.read_bytes()
        if digest(data)!=expected_digest:raise ValueError('package integrity differs: '+name)
        snapshots[name]=data
    writes=[]
    for group,dest in [('tooling',a.tooling_root),('infrastructure',a.infra_root)]:
        if dest is None:continue
        dest=dest.expanduser().absolute()
        if group=='infrastructure' and not (dest/'.git').exists():raise ValueError('create the infrastructure Git repository before installing support files')
        for source in sorted((PACKAGE/'assets'/group).rglob('*')):
            if not source.is_file():continue
            relative=str(source.relative_to(PACKAGE/'assets'/group))
            if group=='infrastructure' and not (relative.startswith(SUPPORT) or relative=='.dockerignore'):continue
            if group=='infrastructure' and relative=='automation/platform-input-mappings.json':continue
            target=safe(dest,relative)
            data=snapshots[str(source.relative_to(PACKAGE))]
            previous=target.read_bytes() if target.exists() else None
            if previous is not None and previous==data:continue
            if target.exists() and not a.replace_reviewed:raise ValueError('existing file differs; inspect diff before --replace-reviewed: '+str(target))
            backup=target.with_name(target.name+'.before-course-update')
            if target.exists() and (backup.exists() or backup.is_symlink()):raise ValueError('previous backup needs review: '+str(target))
            writes.append((source,target,data,previous))
    # Full preflight before writes. Stop on any collision/change; preserve partial
    # results and backups for review instead of retrying replacements automatically.
    for source,target,data,previous in writes:
        install_write(source,target,data,manifest['modes'][str(source.relative_to(PACKAGE))],previous)
    if a.infra_root:
        registry=safe(a.infra_root.expanduser().absolute(),'automation/platform-input-mappings.json')
        if not registry.exists() and not registry.is_symlink():exclusive_file(registry,b'[]\n',0o600)
    print('Supporting files installed: '+str(len(writes))+'. Inspect Git diff before committing.')

if __name__=='__main__':main()
