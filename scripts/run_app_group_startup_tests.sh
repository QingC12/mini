#!/bin/sh
# Compile the actual production Foundation helper, not a string replacement or
# a test-only implementation. Exit 77 means runtime validation was NOT run.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-app-group-startup.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 "$ROOT/tests/app-group-startup/source_guard.py" "$ROOT"
COMPILER=${SWIFTC:-$(command -v swiftc 2>/dev/null || true)}
if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
    COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: no Swift compiler; app-group-startup was NOT compiled or run.'
    exit 77
fi
mkdir -p "$TMP/modules" "$TMP/home"
"$COMPILER" -swift-version 5 -parse-as-library -module-cache-path "$TMP/modules" \
    "$ROOT/src/ios/Shared/AppGroupStoragePaths.swift" \
    "$ROOT/tests/app-group-startup/Tests.swift" -o "$TMP/AppGroupStartupTests"
HOME="$TMP/home" "$TMP/AppGroupStartupTests"
