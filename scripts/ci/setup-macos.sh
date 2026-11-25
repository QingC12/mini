#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'ERROR: requires an Apple Silicon macOS runner (macos-26).' >&2; exit 1;
}
[[ -d "${DEVELOPER_DIR:?}/Platforms/iPhoneOS.platform" ]] || {
  echo 'ERROR: required Xcode_26.2.app is not installed on this runner image.' >&2; exit 1;
}
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
