#!/bin/sh
# Compile the REAL storage registry, settings checkpoint and cleanup helpers.
# No app launch, live storage, credentials or signing. Swift 6 + Foundation.
# Exit 77 explicitly means SKIP, never a Swift test pass.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER=${SWIFTC:-}
if [ -z "$COMPILER" ]; then
    COMPILER=$(command -v swiftc 2>/dev/null || true)
    if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
        COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
    fi
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: swiftc unavailable; no Swift storage/settings tests compiled or executed.'
    exit 77
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-continuation-storage.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP/modules"
"$COMPILER" --version
"$COMPILER" -swift-version 6 -parse-as-library \
    -D CONTINUATION_STORAGE_STANDALONE -D CONTINUATION_STORAGE_TEST_EXECUTABLE \
    -module-cache-path "$TMP/modules" \
    "$ROOT/src/ios/Agent/Chat/ContinuationStorageBindings.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationWorkspace.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationSettings.swift" \
    "$ROOT/src/ios/Agent/Chat/SessionDeletionSupport.swift" \
    "$ROOT/src/ios/MinisTests/Standalone/ContinuationStorageTests.swift" \
    -o "$TMP/storage-tests"
"$TMP/storage-tests"
echo 'PASS: compiled real Foundation storage/settings-core tests. iOS integrations remain separate.'
