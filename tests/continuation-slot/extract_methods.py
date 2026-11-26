#!/usr/bin/env python3
"""Extract the REAL slot helper/manager verbatim; replace only OS/UI edges."""
import hashlib
import json
import pathlib
import sys

root, output = map(pathlib.Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
chat = root / "src/ios/Agent/Chat"
send = (chat / "AIChatViewModel+Send.swift").read_text()
# This is the final extension. Keep its full text, including the helper's
# original await, success and catch bodies. Never replace an acquire call.
start = send.index("extension AIChatViewModel {\n    /// [T-limits-per-parent]")
helper = send[start:]
assert helper.count("func acquireSessionSlot(") == 1
assert helper.rstrip().endswith("}")
lifecycle = (chat / "ChatLifecycleSupport.swift").read_text()

def marked(name):
    start = lifecycle.index("// BEGIN " + name)
    end = lifecycle.index("// END " + name, start) + len("// END " + name)
    return lifecycle[start:end]

parts = {
    "ProductionAcquireSessionSlot.swift": ("import Foundation\n", helper),
    "ProductionSessionSlots.swift": ("import Foundation\nimport Combine\n", marked("SessionSlots")),
    "ProductionConcurrencyLimits.swift": ("import Foundation\n", marked("ConcurrencyLimits")),
}
manifest = {}
for name, (imports, body) in parts.items():
    (output / name).write_text(imports + body + "\n")
    manifest[name] = {"sha256_body": hashlib.sha256(body.encode()).hexdigest(),
                      "lines": len(body.splitlines())}
(output / "extraction-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Extracted verbatim production acquireSessionSlot, SessionSlots and ConcurrencyLimits.")
