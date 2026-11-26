#!/usr/bin/env python3
"""An exact artifact cache key, never a restore-prefix binary fallback."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
def output(*command):
    return subprocess.check_output(command, text=True).strip()
inputs = {}
for directory in ('deps/rclone-mobile', 'deps/ffmpeg-patch', 'deps/lame-3.100', 'deps/aot'):
    for path in sorted((ROOT / directory).rglob('*')):
        if path.is_file() and '.git' not in path.parts and '__pycache__' not in path.parts:
            inputs[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
native_scripts = ('setup-macos.sh', 'build-deps.sh', 'prepare-deps.py',
                  'verify-deps.py', 'deps-lock.json', 'cache-key.py')
for path in [ROOT / '.gitmodules',
             *(ROOT / 'scripts/ci' / name for name in native_scripts),
             *sorted((ROOT / 'deps').glob('*.sh'))]:
    inputs[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
tools = {name: output(*command) for name, command in {
    'xcode': ['xcodebuild', '-version'],
    'sdk': ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'],
    'metal': ['xcrun', '--sdk', 'iphoneos', 'metal', '--version'],
    'go': ['go', 'version'], 'meson': ['meson', '--version'],
    'ninja': ['ninja', '--version'],
    'brew': ['brew', 'list', '--versions', 'llvm', 'lld', 'libarchive', 'pkg-config', 'meson', 'ninja'],
    'lld': [str(Path(output('brew', '--prefix', 'lld')) / 'bin/ld.lld'), '--version'],
}.items()}
# Metal is mounted from a per-run cryptex path with a random suffix. Its
# InstalledDir is provenance, not a compiler version; hashing it guarantees
# misses between identical runners. Preserve raw output in the report only.
observed_metal = tools['metal']
tools['metal'] = '\n'.join(line for line in observed_metal.splitlines()
                           if not line.strip().startswith('InstalledDir:'))
refs = {spec['path']: output('git', '-C', spec['path'], 'rev-parse', 'HEAD')
        for spec in json.loads((ROOT / 'scripts/ci/deps-lock.json').read_text())['submodules']}
identity = {'schema': 1, 'arch': platform.machine(), 'macos': platform.mac_ver()[0],
            'tools': tools, 'refs': refs, 'source_inputs': inputs}
# Include recursive checked-out commits, including terminal/libapps dependencies.
identity['recursive_ish'] = output('git', '-C', 'deps/ish', 'submodule', 'status', '--recursive')
digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
key = f'ios-native-v1-{platform.machine()}-{digest}'
report = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci')) / 'reports'
report.mkdir(parents=True, exist_ok=True)
(report / 'cache-identity.json').write_text(json.dumps({**identity, 'key': key,
    'observed_metal_version_with_location': observed_metal}, indent=2) + '\n')
if os.environ.get('GITHUB_OUTPUT'):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write('key=' + key + '\n')
print(key)
