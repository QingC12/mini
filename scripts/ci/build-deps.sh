#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${CI_OUTPUT_DIR:-$PWD/build/ci}"
mkdir -p "$OUT/logs" "$OUT/reports"
# prepare-deps.py has already checked SHA256. Reject an unexpected extraction
# destination, then use the baseline scripts without silently downloading a
# different FFmpeg tree. LAME sources are already vendored in this repository.
[[ -f deps/.cache/ffmpeg-6.1.2.tar.xz && -f deps/lame-3.100/configure ]]
[[ ! -d deps/ffmpeg-6.1.2 ]] || {
  echo 'ERROR: refusing an unverified existing FFmpeg source tree.' >&2; exit 1;
}
tar -xf deps/.cache/ffmpeg-6.1.2.tar.xz -C deps
run_dep() {
  local name="$1"; shift
  echo "::group::$name"
  "$@" 2>&1 | tee "$OUT/logs/$name.log"
  echo '::endgroup::'
}
# Device libraries only. Rclone's baseline builder also emits its simulator
# slice to retain the upstream XCFramework layout; no simulator app is built.
run_dep lame bash deps/build_lame.sh
run_dep ffmpeg bash deps/build_ffmpeg.sh
run_dep ish bash deps/build_ish.sh release
run_dep alpine-rootfs bash deps/prepare_alpine_rootfs.sh 3.21
run_dep rclone bash deps/build_rclone_ios.sh
# Preserve configure and Meson diagnostics without caching intermediate source
# trees (absolute build paths and host tools cannot safely be reused).
python3 - <<'PY'
import os, shutil
from pathlib import Path
out = Path(os.environ.get('CI_OUTPUT_DIR', 'build/ci')) / 'logs'
for path in (Path('deps/lame-3.100/config.log'), Path('deps/ffmpeg-6.1.2/ffbuild/config.log'),
             Path('deps/ish/build-ios/meson-logs/meson-log.txt'),
             Path('deps/ish/build-native/meson-logs/meson-log.txt')):
    if path.is_file():
        shutil.copy2(path, out / str(path).replace('/', '_'))
PY
