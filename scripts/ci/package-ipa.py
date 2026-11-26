#!/usr/bin/env python3
"""Verify real iOS output; emit separate unsigned and TrollStore ad-hoc IPAs."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
OUT = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci'))
ART = OUT / 'artifacts'
ART.mkdir(parents=True, exist_ok=True)
app = Path(sys.argv[1]).resolve()
assert app.is_dir() and app.name == 'Minis.app', 'Real xcodebuild app output missing'

def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()

# This is a real deployment target, not an Info.plist-only compatibility edit.
MINIMUM_IOS = '17.0'
REQUIRED_DEVICE_IOS = (17, 3, 1)

def ios_version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return (parts + (0, 0, 0))[:3]

def binary_compatibility(path):
    data = path.read_bytes()
    assert data[:4] == b'\xcf\xfa\xed\xfe', f'Not thin arm64 Mach-O: {path}'
    _, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', data)
    assert cpu == 0x0100000c and 32 + size <= len(data), path
    pos = 32
    versions = []
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, pos)
        assert length >= 8 and pos + length <= 32 + size, path
        if cmd == 0x32:  # LC_BUILD_VERSION; SDK version is NOT the minimum OS.
            platform, minimum, _, _ = struct.unpack_from('<4I', data, pos + 8)
            version = (minimum >> 16, (minimum >> 8) & 255, minimum & 255)
            assert platform == 2, f'Not iOS device: {path}'
            assert version <= REQUIRED_DEVICE_IOS, f'Binary requires newer iOS {version}: {path}'
            versions.append('.'.join(map(str, version)))
        pos += length
    assert pos == 32 + size and versions, f'Missing/invalid build version: {path}'
    return {'path': str(path.relative_to(app)), 'minimum_ios': versions}

def bundle(path):
    info = plistlib.loads((path / 'Info.plist').read_bytes())
    if info.get('MinimumOSVersion'):
        assert ios_version(info['MinimumOSVersion']) <= REQUIRED_DEVICE_IOS, f'Bundle requires newer iOS: {path}'
    executable = path / info['CFBundleExecutable']
    assert executable.is_file() and os.access(executable, os.X_OK), executable
    assert command('xcrun', 'lipo', '-archs', str(executable)) == 'arm64', executable
    loads = command('xcrun', 'otool', '-l', str(executable))
    import re
    assert re.search(r'\bplatform\s+(?:2|IOS)\s', loads), f'Not an iOS device binary: {executable}'
    assert info.get('CFBundleIdentifier'), path
    return {'bundle': str(path.relative_to(app.parent)), 'bundle_id': info['CFBundleIdentifier'],
            'executable': info['CFBundleExecutable'], 'architectures': ['arm64']}

bundles = [bundle(app)]
assert plistlib.loads((app / 'Info.plist').read_bytes()).get('MinimumOSVersion') == MINIMUM_IOS
compatibility_images = []
for path in sorted(app.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        compatibility_images.append(binary_compatibility(path))
assert len(compatibility_images) >= 12, 'Incomplete iOS device executable set'
(OUT / 'reports/ios17-compatibility.json').write_text(json.dumps({
    'required_device_ios': '17.3.1', 'deployment_target': MINIMUM_IOS,
    'images': compatibility_images, 'device_tested': False,
}, indent=2) + '\n')
for name in ('MinisShare.appex', 'MinisFileProvider.appex', 'AgentWidgetExtension.appex'):
    bundles.append(bundle(app / 'PlugIns' / name))
for name in ('FFmpeg', 'libavcodec', 'libavformat', 'libavutil', 'libavfilter', 'libswresample', 'libswscale', 'RealTimeCutVADCXXLibrary'):
    bundles.append(bundle(app / 'Frameworks' / (name + '.framework')))
assert (app / 'alpine-rootfs.zip').is_file(), 'Packaged Alpine rootfs missing'
assert (app / 'RootfsPatch.bundle').is_dir(), 'Packaged rootfs patches missing'
# Confirm linked dylibs do not accidentally reference build-machine locations.
for path in [app / 'Minis', *app.glob('Frameworks/*.framework/*')]:
    if not path.is_file() or path.suffix or path.name in ('Info.plist',):
        continue
    result = subprocess.run(['xcrun', 'otool', '-L', str(path)], text=True, capture_output=True)
    for line in result.stdout.splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        assert not dependency.startswith(('/opt/homebrew/', '/Users/', '/private/', '/var/folders/')), dependency
stage = OUT / 'ipa-stage'
if stage.exists():
    shutil.rmtree(stage)
payload = stage / 'Payload'
payload.mkdir(parents=True)
shutil.copytree(app, payload / app.name, symlinks=True)
# Some Go/native frameworks are ad-hoc signed by their source-build scripts.
# Strip those signatures inside the staging copy so the IPA has one clear
# unsigned status; do NOT infer installation eligibility from an ad-hoc seal.
for directory in sorted([p for p in stage.rglob('_CodeSignature') if p.is_dir()], reverse=True):
    shutil.rmtree(directory)
for path in (payload / app.name).rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        subprocess.run(['codesign', '--remove-signature', str(path)], check=True)
assert not list(stage.rglob('embedded.mobileprovision')), 'Unsigned artifact must not contain provisioning profiles'
ipa = ART / 'Minis-unsigned.ipa'
if ipa.exists():
    ipa.unlink()
subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc', str(payload), str(ipa)], check=True)
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    names = archive.namelist()
    assert 'Payload/Minis.app/Info.plist' in names and 'Payload/Minis.app/Minis' in names
    assert not any('_CodeSignature/' in p or p.endswith('embedded.mobileprovision') for p in names)
info = {
    'source_commit': command('git', 'rev-parse', 'HEAD'),
    'xcode': command('xcodebuild', '-version'),
    'sdk': command('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
    'go': command('go', 'version'), 'configuration': 'Release',
    'destination': 'generic/platform=iOS', 'architecture': 'arm64', 'minimum_ios': '17.0',
    'signing': 'unsigned; no Apple identity or provisioning profile',
    'installable_as_is': False, 'bundles': bundles,
    'dependency_lock': json.loads((ROOT / 'scripts/ci/deps-lock.json').read_text()),
}
(ART / 'BUILD-INFO.json').write_text(json.dumps(info, indent=2) + '\n')
(ART / 'UNSIGNED-NOT-INSTALLABLE.txt').write_text(
    'Unsigned iOS device arm64 build for validation and later authorized signing.\n'
    'Not App Store, TestFlight, Apple ad-hoc distribution, or directly installable.\n'
    'No certificate, private key, Apple team, or provisioning profile was used.\n'
    'Device installation requires suitable signing/provisioning and entitlements.\n'
    'See reports/swift-package-provenance.json for the existing checksum-pinned VAD binary exception.\n')
with (ART / 'SHA256SUMS').open('w') as sums:
    for path in (ipa, ART / 'BUILD-INFO.json', ART / 'UNSIGNED-NOT-INSTALLABLE.txt'):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        sums.write(f'{digest}  {path.name}\n')
(OUT / 'reports/ipa-validation.json').write_text(json.dumps({'valid': True, **info}, indent=2) + '\n')
print(f'Validated unsigned iOS arm64 IPA: {ipa.name} ({ipa.stat().st_size} bytes); NOT directly installable.')
# Keep the deliberately unsigned channel untouched. The distinct TrollStore
# channel MUST contain real ad-hoc seals and per-target embedded entitlements.
subprocess.run([sys.executable, str(ROOT / 'scripts/ci/trollstore-package.py'),
                str(payload / app.name), '--output', str(OUT),
                '--source-root', str(ROOT)], check=True)
