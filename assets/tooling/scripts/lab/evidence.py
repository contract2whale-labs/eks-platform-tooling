#!/usr/bin/env python3
"""Attempt storage and integrity checks. Never infer live success from a seal."""
import datetime, hashlib, json, os, re, subprocess, sys, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REGISTRY = json.loads((HERE / 'cases.json').read_text())
KNOWN = {entry['case_id'] for entry in REGISTRY['cases']}
ALIASES = {entry['legacy_case']:entry['case_id'] for entry in REGISTRY['cases']}
ROOT = Path(os.environ.get('EVIDENCE_ROOT', str(Path(os.environ.get('TOOLING_ROOT', HERE.parents[1])) / 'work/incidents'))).absolute()
RESULTS = {'PASS','FAIL','INVALID','BLOCKED','UNKNOWN'}
IDENTITY = {'attempt_id','case','started_utc','sealed_utc','infra_commit','kube_context'}

def fail(message, code=2):
    print(message, file=sys.stderr)
    raise SystemExit(code)

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def safe_case(value):
    if not re.fullmatch(r'[a-z][a-z0-9-]*', value) or value not in KNOWN:
        fail('EVIDENCE_ERROR unknown case; use evidence.sh cases')
    return value

def case_root(value):
    path = ROOT / safe_case(value)
    if path.is_symlink() or ROOT.is_symlink():
        fail('EVIDENCE_ERROR evidence root may not be a symlink')
    return path

def read_run(path):
    data = {}
    for line in (path / 'run.tsv').read_text().splitlines():
        key,value = line.split('\t',1)
        if key in data:
            fail('EVIDENCE_ERROR duplicate run key')
        data[key] = value
    return data

def write_run(path,data):
    temporary = path / 'run.tsv.tmp'
    temporary.write_text(''.join(f'{k}\t{v}\n' for k,v in data.items()))
    temporary.replace(path / 'run.tsv')

def active(value, mutable=False):
    case = case_root(value)
    link = case / 'current'
    if not link.is_symlink():
        fail('EVIDENCE_ERROR no active attempt; start first')
    path = link.resolve()
    try:
        path.relative_to((case / 'attempts').resolve())
    except ValueError:
        fail('EVIDENCE_ERROR current link escapes attempts')
    if not (path / 'run.tsv').is_file():
        fail('EVIDENCE_ERROR missing run.tsv')
    data = read_run(path)
    if data.get('case') != value or data.get('attempt_id') != path.name:
        fail('EVIDENCE_ERROR identity mismatch')
    if mutable and data.get('sealed_utc'):
        fail(f'EVIDENCE_SEALED_ALREADY case={value}',1)
    return path,data

def record_problem(path):
    if not path.is_file():
        return 'missing'
    chunks = re.split(r'^## ([1-7]) [^\n]+\n',path.read_text(),flags=re.M)
    if chunks[1::2] != list('1234567'):
        return 'headings'
    for number,body in zip(chunks[1::2],chunks[2::2]):
        body = re.sub(r'<!--.*?-->','',body,flags=re.S)
        if not body.strip() or re.search(r'TODO|PLACEHOLDER|<작성|<입력|미작성',body,re.I):
            return 'empty-'+number
    return None

def files_for_manifest(path):
    paths = []
    for item in sorted(path.rglob('*')):
        if item.is_symlink():
            fail('EVIDENCE_ERROR symlinks inside attempts are prohibited')
        if item.is_file() and item.name not in {'manifest.sha256','manifest.sha256.tmp'}:
            relative = item.relative_to(path).as_posix()
            if '\n' in relative or '\r' in relative:
                fail('EVIDENCE_ERROR invalid evidence filename')
            paths.append((relative,item))
    return paths

def manifest_problems(path, legacy=False):
    manifest = path / 'manifest.sha256'
    if not manifest.is_file():
        return ['manifest=none']
    expected = {}
    for line in manifest.read_text().splitlines():
        match = re.fullmatch(r'([a-f0-9]{64})  (?:\./)?(.+)',line)
        if not match:
            return ['manifest=invalid']
        hash_value, name = match.groups()
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or name in expected:
            return ['manifest=unsafe']
        target = path / relative
        if target.is_symlink() or not target.is_file() or digest(target) != hash_value:
            return ['manifest=mismatch']
        expected[name] = hash_value
    # Legacy attempts exclude nested historical attempts from their own manifest.
    actual = {name for name,item in files_for_manifest(path)
              if not (legacy and name.startswith('attempts/'))}
    if actual != set(expected):
        return ['manifest=file-set-mismatch']
    return []

def check_one(value,path,legacy=False):
    problems = []
    try:
        data = read_run(path)
    except (OSError,ValueError):
        data = {}
        problems.append('keys=no-run.tsv')
    for key in ['attempt_id','case','started_utc','result','sealed_utc']:
        if not data.get(key):
            problems.append('missing-'+key)
    if data.get('result') not in RESULTS:
        problems.append('result=invalid')
    if not legacy and (data.get('case') != value or data.get('attempt_id') != path.name):
        problems.append('identity=mismatch')
    problems.extend(manifest_problems(path,legacy))
    record = 'abandoned' if data.get('abandoned_reason') else record_problem(path/'record.md')
    if record and record != 'abandoned':
        problems.append('record='+record)
    print('\t'.join([value,data.get('attempt_id',path.name),
                     'yes' if data.get('sealed_utc') else 'no',
                     'ok' if not any('manifest' in p for p in problems) else 'mismatch',
                     'abandoned' if record == 'abandoned' else ('7' if not record else record),
                     'ok' if not any(p.startswith(('keys','missing','identity')) for p in problems) else ','.join(problems),
                     data.get('result','-')]))
    return bool(problems)

def seal(value,reason=None):
    path,data = active(value,True)
    if reason is not None:
        if not reason.strip():
            fail('EVIDENCE_ERROR abandon requires a reason')
        data.update(result='INVALID',abandoned_reason=reason)
    else:
        problem = record_problem(path/'record.md')
        if problem:
            fail(f'EVIDENCE_RECORD_INCOMPLETE case={value} problem={problem}',1)
        if data.get('result') not in RESULTS:
            fail('EVIDENCE_ERROR set observed result before seal',1)
        validation = subprocess.run([sys.executable,str(HERE/'incident-record.py'),
                                     'finalize',value,'--directory',str(path)],
                                    capture_output=True,text=True)
        if validation.returncode:
            fail(validation.stderr.strip() or 'EVIDENCE_ERROR observation validation failed',1)
    # Raw observations are never deleted as part of sealing.
    data['sealed_utc'] = now()
    write_run(path,data)
    files = files_for_manifest(path)
    manifest = path/'manifest.sha256'
    manifest.write_text(''.join(f'{digest(item)}  ./{name}\n' for name,item in files))
    print(f'EVIDENCE_{"ABANDONED" if reason is not None else "SEALED"} case={value} attempt={path.name} files={len(files)}')

def main(argv):
    if not argv:
        fail('EVIDENCE_ERROR start|set|get|path|seal|abandon|check|legacy-check|cases')
    command,*args = argv
    if command == 'cases' and not args:
        print('\n'.join(sorted(KNOWN)))
    elif command == 'start' and len(args)==1:
        value=args[0]; case=case_root(value)
        case.mkdir(parents=True,exist_ok=True)
        if (case/'current').exists():
            previous,data=active(value)
            if not data.get('sealed_utc'):
                fail(f'EVIDENCE_OPEN_ATTEMPT case={value} attempt={previous.name}',1)
            archived=previous.name
        else:
            archived='none'
        attempt=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
        path=case/'attempts'/attempt
        path.mkdir(parents=True)
        infra=os.environ.get('INFRA_ROOT','/nonexistent')
        proc=subprocess.run(['git','-C',infra,'rev-parse','HEAD'],capture_output=True,text=True)
        write_run(path,{'attempt_id':attempt,'case':value,'started_utc':now(),
                       'kube_context':os.environ.get('EVIDENCE_KUBE_CONTEXT',os.environ.get('DEV_KUBE_CONTEXT','unknown')),
                       'infra_commit':proc.stdout.strip() if proc.returncode==0 else 'unknown'})
        (path/'scratch').mkdir()
        temporary=case/'current.tmp'
        temporary.symlink_to(Path('attempts')/attempt)
        temporary.replace(case/'current')
        print(f'EVIDENCE_START case={value} attempt={attempt} archived={archived}')
    elif command in {'path','current-dir','get'} and len(args)==(2 if command=='get' else 1):
        path,data=active(args[0])
        print(data.get(args[1],'') if command=='get' else path)
    elif command=='set' and len(args)>=2:
        path,data=active(args[0],True)
        additions={}
        for pair in args[1:]:
            if '=' not in pair:
                fail('EVIDENCE_ERROR key=value required')
            key,value=pair.split('=',1)
            if not re.fullmatch(r'[a-z][a-z0-9_]*',key) or key in IDENTITY:
                fail('EVIDENCE_ERROR reserved or invalid key')
            if key=='result' and value not in RESULTS:
                fail('EVIDENCE_ERROR invalid result')
            additions[key]=re.sub(r'[\t\r\n]',' ',value)
        data.update(additions); write_run(path,data)
        for key,value in additions.items():
            print(f'EVIDENCE_SET case={args[0]} {key}={value}')
    elif command=='seal' and len(args)==1:
        seal(args[0])
    elif command=='abandon' and len(args)>=2:
        seal(args[0],' '.join(args[1:]))
    elif command in {'check','legacy-check'}:
        print('case\tattempt\tsealed\tmanifest\trecord\tkeys\tresult')
        problems=attempts=cases=0
        if command=='legacy-check':
            # An explicitly supplied directory is read only. Original identities/hashes stay intact.
            if len(args)!=1:
                fail('EVIDENCE_ERROR legacy-check DIRECTORY')
            directory=Path(args[0])
            selected=[(p.name,p) for p in sorted(directory.iterdir()) if p.is_dir() and not p.is_symlink()]
        else:
            values=args or [p.name for p in sorted(ROOT.iterdir()) if p.is_dir() and p.name in KNOWN] if ROOT.exists() else args
            selected=[(value,case_root(value)) for value in values]
        for value,path in selected:
            if command=='legacy-check':
                records=([path] if (path/'run.tsv').is_file() else [])+list((path/'attempts').glob('*'))
            else:
                records=[p for p in sorted((path/'attempts').glob('*')) if p.is_dir() and not p.is_symlink()]
            if not records:
                if command=='legacy-check':
                    continue
                print(f'{value}\t-\tno\tnone\tnone\tno-folder\t-'); problems+=1
            else:
                cases+=1
            for record in records:
                attempts+=1
                problems+=check_one(value,record,command=='legacy-check')
        if not attempts:
            problems+=1
        print(f'EVIDENCE_CHECK cases={cases} attempts={attempts} problems={problems}')
        if problems:
            raise SystemExit(1)
    else:
        fail('EVIDENCE_ERROR invalid arguments')

if __name__=='__main__':
    try:
        main(sys.argv[1:])
    except (OSError,ValueError) as error:
        fail('EVIDENCE_ERROR '+str(error))
