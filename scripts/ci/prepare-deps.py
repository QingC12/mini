#!/usr/bin/env python3
"""Recover archive-lost gitlinks by checking the original upstream Git tree."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
LOCK = json.loads((ROOT / 'scripts/ci/deps-lock.json').read_text())
OUT = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci')) / 'reports'
OUT.mkdir(parents=True, exist_ok=True)
# Explicitly no credential helper, token or remote branch tracking.
ENV = {**os.environ, 'GIT_TERMINAL_PROMPT': '0'}
def git(*args, cwd=ROOT):
    command = ['git', '-c', 'credential.helper=', '-c', 'protocol.allow=never',
               '-c', 'protocol.https.allow=always', *args]
    print('+ ' + ' '.join(command), flush=True)
    return subprocess.check_output(command, cwd=cwd, env=ENV, text=True).rstrip('\n')

def modules(cwd, text=None):
    args = ['config', '--file', '.gitmodules', '--get-regexp', r'^submodule\..*\.url$']
    if not (Path(cwd) / '.gitmodules').exists():
        return
    for line in git(*args, cwd=cwd).splitlines():
        key, url = line.split(None, 1)
        # No SSH credentials, local-path submodules or URL options are allowed.
        if not re.fullmatch(r'https://[A-Za-z0-9.-]+/[A-Za-z0-9_./-]+', url):
            raise SystemExit('Unsafe recursive submodule URL: ' + url)

with tempfile.TemporaryDirectory(prefix='minis-upstream-tree-') as tmp:
    tmp = Path(tmp)
    git('init', '--quiet', cwd=tmp)
    upstream = LOCK['upstream']
    git('fetch', '--depth=1', upstream['url'], upstream['commit'], cwd=tmp)
    assert git('rev-parse', 'FETCH_HEAD', cwd=tmp) == upstream['commit']
    original_modules = git('show', 'FETCH_HEAD:.gitmodules', cwd=tmp)
    assert (ROOT / '.gitmodules').read_text().strip() == original_modules.strip(), 'Changed .gitmodules requires lock review'
    evidence = []
    for spec in LOCK['submodules']:
        path, commit, url = spec['path'], spec['commit'], spec['url']
        assert re.fullmatch(r'[0-9a-f]{40}', commit)
        tree = git('ls-tree', 'FETCH_HEAD', '--', path, cwd=tmp)
        assert tree == f'160000 commit {commit}\t{path}', 'Upstream gitlink mismatch: ' + tree
        assert git('config', '--file', str(ROOT / '.gitmodules'), '--get', f'submodule.{path}.url') == url
        index = git('ls-files', '--stage', '--', path)
        if index:
            assert index == f'160000 {commit} 0\t{path}', 'Repository gitlink differs from reviewed lock: ' + index
        destination = ROOT / path
        destination.mkdir(parents=True, exist_ok=True)
        if not (destination / '.git').exists():
            assert not list(destination.iterdir()), f'Refuse to overwrite unversioned source: {path}'
            git('init', '--quiet', cwd=destination)
        git('fetch', '--depth=1', url, commit, cwd=destination)
        git('checkout', '--detach', '--force', commit, cwd=destination)
        assert git('rev-parse', 'HEAD', cwd=destination) == commit
        modules(destination)
        git('submodule', 'update', '--init', '--recursive', '--depth=1', cwd=destination)
        recursive = git('submodule', 'status', '--recursive', cwd=destination)
        for line in recursive.splitlines():
            # The reviewed iSH .gitmodules marks Linux update=none: it is not
            # needed by the iOS kernel/fakefs build and must not clone a huge
            # optional Linux tree. Every materialized submodule must be exact.
            skipped_linux = path == 'deps/ish' and line.startswith('-') and line.split()[1] == 'deps/linux'
            assert line.startswith(' ') or skipped_linux, recursive
        # Audit all materialized nested .gitmodules, not just the first level.
        for manifest in destination.rglob('.gitmodules'):
            if '.git' not in manifest.relative_to(destination).parts:
                modules(manifest.parent)
        evidence.append({**spec, 'source_tree': tree, 'repository_gitlink_present': bool(index),
                         'recursive_submodules': recursive.splitlines()})
(OUT / 'source-provenance.json').write_text(json.dumps({'upstream': upstream, 'submodules': evidence}, indent=2) + '\n')
# Download only the reviewed source release and base OS rootfs. curl -f + hash
# prevents an HTML error page or changed remote tarball entering the build.
for item in LOCK['downloads']:
    dest = ROOT / item['path']
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        temp = dest.with_suffix(dest.suffix + '.partial')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--proto', '=https',
                        '--tlsv1.2', item['url'], '-o', str(temp)], check=True)
        temp.replace(dest)
    digest = hashlib.sha256(dest.read_bytes()).hexdigest()
    assert digest == item['sha256'], f'Checksum mismatch: {dest}: {digest}'
    print(digest, item['path'], flush=True)
(OUT / 'download-provenance.json').write_text(json.dumps(LOCK['downloads'], indent=2) + '\n')
print('Fixed upstream commit, exact gitlinks, nested gitlinks and download hashes verified.')
