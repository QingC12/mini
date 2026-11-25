#!/usr/bin/env python3
"""Always-run summary and supplemental configure diagnostics."""
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci'))
(OUT / 'logs').mkdir(parents=True, exist_ok=True)
(OUT / 'reports').mkdir(parents=True, exist_ok=True)
for path in (ROOT / 'deps/lame-3.100/config.log', ROOT / 'deps/ffmpeg-6.1.2/ffbuild/config.log',
             ROOT / 'deps/ish/build-ios/meson-logs/meson-log.txt',
             ROOT / 'deps/ish/build-native/meson-logs/meson-log.txt'):
    if path.is_file():
        shutil.copy2(path, OUT / 'logs' / str(path.relative_to(ROOT)).replace('/', '_'))
lines = ['## Minis iOS unsigned device build', '',
         '- Job status: **' + os.environ.get('BUILD_JOB_STATUS', 'unknown') + '**',
         '- Destination: real iOS device arm64; deployment target 26.2.',
         '- No Apple signing identity, certificate, private key, or provisioning profile.',
         '- **The IPA is unsigned and is not directly installable.**',
         '- Existing VAD SwiftPM binary target is source/checksum-pinned and documented; not a 100% all-source claim.', '']
report = OUT / 'reports/standalone-tests.json'
if report.is_file():
    lines += ['### Real Swift checks', '']
    for item in json.loads(report.read_text()):
        lines.append(f"- {item['name']}: {'PASS' if item['exit_code'] == 0 else 'FAIL'} (exit {item['exit_code']})")
    lines += ['', 'Production `-parse` is syntax checking, not app type checking or a device runtime test.', '']
sums = OUT / 'artifacts/SHA256SUMS'
if sums.is_file():
    lines += ['### SHA256', '', '```text', sums.read_text().strip(), '```', '']
lines += ['Artifacts: verified IPA + SHA256/BUILD-INFO on success; reports/logs/Xcode result bundle on success or failure.',
          'The standalone tests do not prove coordinator integration or real-device behavior.']
text = '\n'.join(lines) + '\n'
(OUT / 'reports/build-summary.md').write_text(text)
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
        stream.write(text)
print(text)
