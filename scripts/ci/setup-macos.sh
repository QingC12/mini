#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'ERROR: requires an Apple Silicon macOS runner.' >&2; exit 1;
}
# Prefer the baseline SDK when present, otherwise use the newest stable Xcode
# >=26.2 installed in the public hosted image; never accept a beta/RC fallback.
DEVELOPER_DIR="$(python3 - <<'PY'
from pathlib import Path
import plistlib, re
candidates = []
for app in Path('/Applications').glob('Xcode*.app'):
    if re.search(r'beta|(?:^|[_. -])rc(?:[_. -]|\d|$)', app.name + ' ' + app.resolve().name, re.I):
        continue
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        text = str(info['CFBundleShortVersionString'])
        if not re.fullmatch(r'\d+(?:\.\d+){1,2}', text):
            continue
        version = tuple(map(int, text.split('.')))
        developer = app.resolve() / 'Contents/Developer'
        if version[:2] >= (26, 2) and (developer / 'Platforms/iPhoneOS.platform').is_dir():
            candidates.append((app.name == 'Xcode_26.2.app', version, str(developer)))
    except (OSError, KeyError, ValueError):
        continue
assert candidates, 'No stable Xcode >=26.2 with iOS SDK is installed'
print(max(candidates)[2])
PY
)"
export DEVELOPER_DIR
printf 'Selected DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
python3 - <<'PY'
import re, subprocess
for command in (['xcodebuild', '-version'], ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version']):
    text = subprocess.check_output(command, text=True)
    match = re.search(r'(\d+)\.(\d+)', text)
    assert match and tuple(map(int, match.groups())) >= (26, 2), text
PY
brew install ninja llvm libarchive pkg-config meson
# Do not put Homebrew LLVM before Apple's clang: host libraries use Xcode clang;
# build_ish.sh explicitly finds Homebrew clang for the guest ELF VDSO.
ARCHIVE_PREFIX="$(brew --prefix libarchive)"
export PKG_CONFIG_PATH="$ARCHIVE_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'PKG_CONFIG_PATH=%s\n' "$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
  printf 'SWIFTC=%s\n' "$(xcrun --find swiftc)" >> "$GITHUB_ENV"
fi
if ! xcrun --sdk iphoneos metal --version; then
  xcodebuild -downloadComponent MetalToolchain
fi
# Fail instead of silently compiling FFmpeg without the Metal filter.
xcrun --sdk iphoneos metal --version
xcrun --find swiftc
xcrun swiftc --version
go version
meson --version
ninja --version
"$(brew --prefix llvm)/bin/clang" --version
pkg-config --modversion libarchive
python3 - <<'PY'
import subprocess
version = subprocess.check_output(['go', 'env', 'GOVERSION'], text=True).strip()
assert version == 'go1.25.5', f'Unexpected Go toolchain: {version}'
PY
