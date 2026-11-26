#!/bin/sh
# Verbatim production acquireSessionSlot + real SessionConcurrencyManager.
# Adapters replace only UI/background/Coordinator; no slotHook or fake acquire.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-continuation-slot.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Run extraction even without Swift, so source drift always fails closed.
python3 "$ROOT/tests/continuation-slot/extract_methods.py" "$ROOT" "$TMP"
COMPILER=${SWIFTC:-$(command -v swiftc 2>/dev/null || true)}
if [ -z "$COMPILER" ] && command -v xcrun >/dev/null 2>&1; then
    COMPILER=$(xcrun --find swiftc 2>/dev/null || true)
fi
if [ -z "$COMPILER" ] || ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo 'SKIP: no Swift compiler; continuation-slot was NOT compiled or run.'
    exit 77
fi
if [ "$(uname -s)" != Darwin ]; then
    echo 'SKIP: real SessionConcurrencyManager imports Combine; use macOS Swift.'
    exit 77
fi
mkdir -p "$TMP/modules" "$TMP/home"
"$COMPILER" -swift-version 5 -parse-as-library -module-cache-path "$TMP/modules" \
    "$ROOT/tests/continuation-slot/Adapters.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationQueueFence.swift" \
    "$ROOT/src/ios/Agent/Chat/ContinuationStorageBindings.swift" \
    "$TMP/ProductionConcurrencyLimits.swift" "$TMP/ProductionSessionSlots.swift" \
    "$TMP/ProductionAcquireSessionSlot.swift" \
    "$ROOT/tests/continuation-slot/Tests.swift" -o "$TMP/ContinuationSlotTests"
HOME="$TMP/home" "$TMP/ContinuationSlotTests"
