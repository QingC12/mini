#!/bin/sh
# Compile the ACTUAL production Store/Record/Coordinator, not a copied algorithm
# or source-regex assertion. Only app/UIKit/kernel surroundings are doubles.
# Requires macOS Swift (Combine + SQLite3); no Xcode app launch or signing.
# Exit 77 is a SKIP, never a test pass. App source uses Swift 5 language mode.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER=${SWIFTC:-$(command -v swiftc 2>/dev/null || true)}
if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
    COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: no Swift compiler; reliability tests were not compiled or run.'
    exit 77
fi
if [ "$(uname -s)" != Darwin ]; then
    echo 'SKIP: real coordinator imports Combine; run on a macOS Swift runner.'
    exit 77
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-continuation-reliability.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP/modules" "$TMP/home"
"$COMPILER" -swift-version 5 -parse-as-library -module-cache-path "$TMP/modules" \
    "$ROOT/tests/continuation-reliability/Fixtures.swift" \
    "$ROOT/src/ios/Providers/ConversationTurnLimit.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationPolicy.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationRecord.swift" \
    "$ROOT/src/ios/Agent/Chat/ChatStore+Continuation.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationQueueFence.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationStorageBindings.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationCoordinator.swift" \
    "$ROOT/tests/continuation-reliability/Tests.swift" \
    -o "$TMP/ContinuationReliabilityTests"
HOME="$TMP/home" "$TMP/ContinuationReliabilityTests"
