#!/usr/bin/env python3
"""Fail on incomplete cached artifacts or silently reduced native features."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
OUT = Path(os.environ.get('CI_OUTPUT_DIR', ROOT / 'build/ci')) / 'reports'
OUT.mkdir(parents=True, exist_ok=True)
files = [Path('deps/lame-build/lib/libmp3lame.a'),
         *[Path('deps/libs') / name for name in ('libish.a', 'libish_emu.a', 'libfakefs.a', 'libish_aot.a')],
         Path('deps/include/ish/ish.h'), Path('deps/resources/libvdso.so.elf'),
         Path('deps/resources/alpine-rootfs.zip')]
assert Path('deps/resources/RootfsPatch.bundle').is_dir(), 'Missing rootfs overlay'
assert Path('deps/resources/libvdso.so.elf').read_bytes()[:4] == b'\x7fELF', 'Missing guest ELF VDSO'
with zipfile.ZipFile('deps/resources/alpine-rootfs.zip') as archive:
    assert archive.testzip() is None
    names = archive.namelist()
    assert any(n.endswith('meta.db') for n in names), 'Missing fakefs metadata'
    assert any('/data/' in n or n.startswith('data/') for n in names), 'Missing fakefs data'
for name in ('FFmpeg', 'libavcodec', 'libavformat', 'libavutil', 'libavfilter', 'libswresample', 'libswscale', 'Rclone'):
    xc = Path('deps/frameworks') / (name + '.xcframework')
    info = plistlib.loads((xc / 'Info.plist').read_bytes())
    slices = [s for s in info['AvailableLibraries'] if s['SupportedPlatform'] == 'ios'
              and not s.get('SupportedPlatformVariant') and s['SupportedArchitectures'] == ['arm64']]
    assert len(slices) == 1, f'Expected exactly one device arm64 slice: {xc}'
    spec = slices[0]
    binary = xc / spec['LibraryIdentifier'] / spec['LibraryPath']
    if binary.suffix == '.framework':
        binary /= name
    assert binary.is_file() and binary.stat().st_size > 0, binary
    arches = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).strip()
    assert arches == 'arm64', f'Wrong architecture: {binary}: {arches}'
    files.append(binary)
for path in files[:5]:
    assert subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).strip() == 'arm64', path
# FFmpeg advertises its compiled-in filters and encoders with avfilter's
# description strings. Checking config.h is stronger but unavailable on hits;
# preserve the build-time feature manifest in the cached output instead.
manifest = Path('deps/resources/ci-native-build.json')
if Path('deps/ffmpeg-6.1.2/config.h').is_file():
    config = Path('deps/ffmpeg-6.1.2/config.h').read_text()
    features = Path('deps/ffmpeg-6.1.2/config_components.h').read_text()
    import re
    for macro in ('CONFIG_LIBMP3LAME', 'CONFIG_METAL'):
        assert re.search(r'^#define ' + macro + r' 1$', config, re.M), 'Missing ' + macro
    assert re.search(r'^#define CONFIG_YADIF_VIDEOTOOLBOX_FILTER 1$', features, re.M), 'Missing Metal yadif filter'
    for macro in ('CONFIG_GPL', 'CONFIG_NONFREE'):
        assert re.search(r'^#define ' + macro + r' 0$', config, re.M), 'Unexpected license mode: ' + macro
    manifest.write_text(json.dumps({'ffmpeg': '6.1.2', 'lame': '3.100', 'alpine': '3.21.0',
                                   'mp3lame': True, 'metal': True, 'yadif_videotoolbox': True,
                                   'gpl': False, 'nonfree': False}, indent=2) + '\n')
assert manifest.is_file(), 'Cache has no source-build feature manifest'
files.append(manifest)
evidence = {}
for path in files:
    assert path.is_file() and path.stat().st_size > 0, path
    evidence[str(path)] = {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
(OUT / 'native-artifacts.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('Validated source-built device arm64 native dependencies, rootfs, VDSO and LGPL/Metal/MP3 features.')
