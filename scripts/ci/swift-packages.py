#!/usr/bin/env python3
"""Pin and audit the existing upstream SwiftPM graph; no unknown binaries."""
import json
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci'))
REPORT = OUT / 'reports'
REPORT.mkdir(parents=True, exist_ok=True)
LOCK = json.loads((ROOT / 'scripts/ci/deps-lock.json').read_text())
RESOLVED = ROOT / 'src/ios/Minis.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
if sys.argv[1] == 'seed':
    if not RESOLVED.exists():
        RESOLVED.parent.mkdir(parents=True, exist_ok=True)
        RESOLVED.write_text(json.dumps({'version': 2, 'pins': [
            {'identity': p['identity'], 'kind': 'remoteSourceControl', 'location': p['url'],
             'state': {'version': p['version'], 'revision': p['revision']}}
            for p in LOCK['swift_packages']]}, indent=2) + '\n')
    sys.exit(0)
assert sys.argv[1] == 'verify'
pins = json.loads(RESOLVED.read_text())['pins']
by_id = {p['identity']: p for p in pins}
for expected in LOCK['swift_packages']:
    pin = by_id[expected['identity']]
    assert pin['state']['revision'] == expected['revision'], f'Unreviewed direct package revision: {pin}'
    assert pin['state'].get('version') == expected['version'], f'Unreviewed direct package version: {pin}'
checkouts = OUT / 'SourcePackages/checkouts'
vad = [p for p in checkouts.iterdir() if p.name.lower() == 'realtimecutvadlibrary']
assert len(vad) == 1, 'Missing pinned VAD package checkout'
manifest = (vad[0] / 'Package.swift').read_text()
binary = LOCK['audited_upstream_binary']
assert binary['url'] in manifest and binary['sha256'] in manifest, 'Unexpected VAD binary source or checksum'
# Fail closed if any other package introduces an unreviewed binary target.
for package in checkouts.iterdir():
    for path in package.glob('Package*.swift'):
        text = path.read_text()
        if re.search(r'\.binaryTarget\s*\(', text):
            assert package == vad[0] and text.count('.binaryTarget') == 1, f'Unknown binary target: {path}'
shutil.copy2(RESOLVED, REPORT / 'Package.resolved')
(REPORT / 'swift-package-provenance.json').write_text(json.dumps({
    'direct_pins': LOCK['swift_packages'], 'resolved_pins': pins,
    'known_upstream_binary_exception': binary,
    'note': 'SwiftPM validates the pinned binary checksum. Native deps/ libraries are built from source. '
            'The original VAD binaryTarget means this app is not claimed to be 100% all-source. '
            'Commit the complete generated Package.resolved for fixed transitive source pins across clean builds.'
}, indent=2) + '\n')
print('Verified direct source pins and sole checksum-pinned upstream VAD binary exception; recorded full graph.')
