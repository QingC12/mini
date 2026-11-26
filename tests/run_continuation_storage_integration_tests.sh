#!/bin/sh
# Real production ChatStore function bodies + real SQLite + ownership registry.
# Only app/UIKit surroundings are adapters. No live storage or credentials.
# Exit 77 = unexecuted, NEVER a test pass. Called by the existing storage suite.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER=${SWIFTC:-$(command -v swiftc 2>/dev/null || true)}
if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
    COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: Swift compiler unavailable; SQL storage integration tests not compiled or run.'
    exit 77
fi
if [ "$(uname -s)" != Darwin ]; then
    echo 'SKIP: run SQLite3 Swift integration tests on macOS.'
    exit 77
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-continuation-storage-sql.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP/modules"
python3 "$ROOT/tests/continuation-storage/extract.py" "$ROOT" "$TMP/source"
"$COMPILER" -swift-version 5 -parse-as-library -module-cache-path "$TMP/modules" \
    "$ROOT/tests/continuation-storage/Fixtures.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationStorageBindings.swift" \
    "$ROOT/src/ios/Agent/Chat/SessionDeletionSupport.swift" \
    "$TMP/source/Workspace.swift" "$TMP/source/Restore.swift" "$TMP/source/Deletion.swift" \
    "$ROOT/tests/continuation-storage/Tests.swift" \
    -o "$TMP/storage-sql-tests"
"$TMP/storage-sql-tests"
