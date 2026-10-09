#!/usr/bin/env python3
"""Explicit pinned downloads; weights stay in Application Support, outside Git."""
import hashlib, json, os, pathlib, sys, urllib.request
manifest = json.loads((pathlib.Path(__file__).resolve().parents[1] / 'Resources/asr-manifest.json').read_text())
base = pathlib.Path(os.environ.get('TALKIE_DATA_ROOT', str(pathlib.Path.home() / 'Library/Application Support/talkie'))) / 'models' / manifest['model']
base.mkdir(parents=True, exist_ok=True, mode=0o700)
for index, f in enumerate(manifest['files']):
    target = base / f['path']; target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if target.exists() and (not f['size'] or target.stat().st_size == f['size']):
        if not f['sha256'] or hashlib.sha256(target.read_bytes()).hexdigest() == f['sha256']: continue
    print(f"[{index+1}/{len(manifest['files'])}] {f['path']}", flush=True)
    temporary = target.with_name(target.name + '.download')
    digest = hashlib.sha256()
    with urllib.request.urlopen(f['url'], timeout=120) as response, temporary.open('wb') as dest:
        while chunk := response.read(1024*1024): digest.update(chunk); dest.write(chunk)
        dest.flush(); os.fsync(dest.fileno())
    if f['sha256'] and digest.hexdigest() != f['sha256']: raise RuntimeError('Model checksum mismatch')
    if f['size'] and temporary.stat().st_size != f['size']: raise RuntimeError('Model size mismatch')
    temporary.chmod(0o600); temporary.replace(target)
(base / 'installed.json').write_text(json.dumps(manifest)); (base / 'installed.json').chmod(0o600)
print(f"Installed pinned multilingual ASR: {base}")
