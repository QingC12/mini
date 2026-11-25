#!/bin/sh
# Compile real routing/ownership code with only app/kernel types stubbed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER=${SWIFTC:-$(command -v swiftc 2>/dev/null || true)}
if [ -z "$COMPILER" ]; then
    echo 'SKIP: no Swift compiler; router tests were not run.'
    exit 77
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-continuation-router.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP/modules"
"$COMPILER" -swift-version 6 -parse-as-library -module-cache-path "$TMP/modules" \
  "$ROOT/tests/continuation-router/RouterTests.swift" \
  "$ROOT/src/ios/Agent/Chat/ContinuationStorageBindings.swift" \
  "$ROOT/src/ios/Agent/ISH/MinisFsRouter.swift" \
  -o "$TMP/RouterTests"
"$TMP/RouterTests" "$TMP/normal" normal
"$TMP/RouterTests" "$TMP/corrupt" corrupt
