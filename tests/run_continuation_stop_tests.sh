#!/bin/sh
# Real Coordinator + Fence + Store + exact Cancel + COMPLETE PromptQueue bodies.
# Only UIKit/OS/provider edges are adapters; no fake cancel implementation.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER=${SWIFTC:-$(command -v swiftc 2>/dev/null || true)}
if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
    COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: no Swift compiler; stop tests were not compiled or run.'
    exit 77
fi
if [ "$(uname -s)" != Darwin ]; then
    echo 'SKIP: real coordinator imports Combine; use a macOS Swift runner.'
    exit 77
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-continuation-stop.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP/modules" "$TMP/home"
python3 "$ROOT/tests/continuation-stop/extract_methods.py" "$ROOT" "$TMP"
python3 "$ROOT/tests/continuation-storage/extract.py" "$ROOT" "$TMP/lifecycle" --shared-logger
"$COMPILER" -swift-version 5 -D CONTINUATION_STOP_TESTS -parse-as-library -module-cache-path "$TMP/modules" \
    "$ROOT/tests/continuation-reliability/Fixtures.swift" \
    "$ROOT/tests/continuation-stop/Adapters.swift" \
    "$ROOT/tests/continuation-stop/LifecycleAdapters.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationStorageBindings.swift" \
    "$ROOT/src/ios/Agent/Chat/SessionDeletionSupport.swift" \
    "$TMP/lifecycle/Workspace.swift" "$TMP/lifecycle/Restore.swift" "$TMP/lifecycle/Deletion.swift" \
    "$ROOT/src/ios/Providers/ConversationTurnLimit.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationPolicy.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationRecord.swift" \
    "$ROOT/src/ios/Agent/Chat/ChatStore+Continuation.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationQueueFence.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationCoordinator.swift" \
    "$TMP/ProductionCancel.swift" "$TMP/ProductionPromptQueue.swift" "$TMP/ProductionPostCompact.swift" \
    "$TMP/ProductionAgentContentPart.swift" "$TMP/ProductionRerun.swift" \
    "$ROOT/tests/continuation-stop/Tests.swift" "$ROOT/tests/continuation-stop/RerunTests.swift" \
    "$ROOT/tests/continuation-stop/LifecycleTests.swift" -o "$TMP/ContinuationStopTests"
HOME="$TMP/home" "$TMP/ContinuationStopTests"
