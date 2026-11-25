#!/bin/sh
# Native continuation: compile and run the REAL Foundation-only policy tests.
# Usage (repository root): sh tests/run_native_continuation_tests.sh
# Optional: SWIFTC=/absolute/path/to/swiftc (a single executable, not flags).
# Exit: 0 = compiled tests passed; 1 = compile/test failure; 77 = no compiler.
#
# Source-branch feature, NOT a claim about the user's installed Minis version:
# after integration/rebuild, chat.autoContinueOnTurnLimit is a read/write bool,
# default false, backed by the same UserDefaults key. Settings > Appearance
# exposes "会话轮次上限后自动新建并续接任务". Failure-chain cap: 3.
#
# No packages, networking, app launch, credentials, real app storage, or Xcode
# signing are needed. Tests use a disposable named defaults suite, removed at
# exit. Compiler/module-cache/binary output stays in a cleaned temporary dir.
# This only covers policy + config/UI source wiring, not provider/coordinator
# integration or an iOS build; add other Foundation-only sources explicitly
# below when their dedicated integration tests are ready. Never count a SKIP
# or a Python simulation as a Swift test pass.
#
# Existing macOS infrastructure: scripts/ios-unit-tests.sh --no-xctest
# --standalone NativeContinuationPolicyTests runs the Standalone adapter.
# Full XCTest uses the isolated MinisUnitTests/MinisTestHost scheme. Do NOT
# substitute `xcodebuild test -scheme Minis`: that may launch the real app.
set -eu

case "${1:-}" in
    -h|--help)
        echo 'Usage: sh tests/run_native_continuation_tests.sh'
        echo 'Requires Swift 6 + Foundation. SWIFTC may name a compiler executable.'
        echo 'Exit 0: PASS; exit 1: FAIL; exit 77: SKIP (compiler missing).'
        exit 0 ;;
    '') ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'ERROR: too many arguments' >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER=${SWIFTC:-}
if [ -z "$COMPILER" ]; then
    COMPILER=$(command -v swiftc 2>/dev/null || true)
    if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
        COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
    fi
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: Swift compiler (swiftc) not found; no Swift tests were compiled or executed.'
    exit 77
fi
"$COMPILER" --version || { echo 'FAIL: Swift compiler is present but unusable' >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-native-continuation.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP/modules"
echo 'Compiling real ContinuationPolicy.swift + dedicated Swift tests (Swift 6)...'
if ! "$COMPILER" -swift-version 6 -parse-as-library \
    -D NATIVE_CONTINUATION_TEST_EXECUTABLE -module-cache-path "$TMP/modules" \
    "$ROOT/src/ios/Agent/Chat/ContinuationPolicy.swift" \
    "$ROOT/src/ios/MinisTests/Standalone/NativeContinuationPolicyTests.swift" \
    -o "$TMP/native-continuation-tests"; then
    echo 'FAIL: Swift compilation failed' >&2
    exit 1
fi
if ! "$TMP/native-continuation-tests" "$ROOT"; then
    echo 'FAIL: native continuation policy tests failed' >&2
    exit 1
fi
echo 'PASS: real Swift policy tests completed; provider/coordinator and iOS build remain separate.'
