#!/usr/bin/env python3
"""Supplementary wiring guard; NEVER counted as the Swift runtime test."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
ios = root / "src/ios"
def read(name):
    return (ios / name).read_text()
def require(value, message):
    if not value:
        raise SystemExit("FAIL source wiring: " + message)

budget = read("Agent/Chat/AIChatViewModel+RequestBudget.swift")
require("nonisolated static let minisStoragePaths: AppGroupStoragePaths" in budget,
        "main storage selection must be cached for the process")
require("appGroupContainer: SharedContainerStore.appGroupContainer" in budget,
        "main storage and share authorization must use one cached resolution")
for property_name, expression in [("minisAppGroupRoot", "minisStoragePaths.providerRoot"),
                                  ("minisConfigRoot", "minisStoragePaths.privateConfigRoot")]:
    match = re.search(r"static var " + property_name + r": URL\s*\{([^}]+)", budget)
    require(match and expression in match[1], property_name + " bypassed common storage policy")
for name in ["shared", "memory", "skills"]:
    require('minisAppGroupRoot.appendingPathComponent("' + name + '"' in budget,
            name + " must use the common provider root")
for swift in ios.rglob("*.swift"):
    # Ignore comments; allow checked if-let/guard-let but never containerURL(...)!.
    text = re.sub(r"//[^\n]*", "", swift.read_text())
    require(not re.search(r"containerURL\s*\([^)]*\)\s*!", text),
            str(swift.relative_to(root)) + " force-unwraps an optional group container")
app = read("MinisApp.swift")
require(app.index("Self.prepareSharedStorageForLaunch()") < app.index("SoulStore.refreshCache()"),
        "SOUL launch reads must follow storage selection/preparation")
require("shared-storage-recovery-notice" in app, "persistent user-visible storage notice missing")
require("guard AIChatViewModel.minisStoragePaths.appGroupContainer != nil" in app,
        "FileProvider registration must refuse local fallback")
store = read("Shared/SharedContainerStore.swift")
require("static let appGroupContainer: URL?" in store, "share group resolution not stable")
require("guard sharedFileDirectory != nil else { return nil }" in store,
        "suite defaults cannot prove transport authorization")
share = read("ShareExtension/ShareViewController.swift")
require("guard SharedContainerStore.appGroupContainer != nil" in share and "code: 2" in share,
        "missing group must cancel share with a storage error")
for name in ["FileProviderExtension.swift", "FileProviderEnumerator.swift"]:
    text = read("FileProvider/" + name)
    for call in re.finditer(r"FileProviderItem\(([^\n]+)", text):
        require("providerRoot:" in call[1], name + " item call missing required providerRoot")
    if name == "FileProviderExtension.swift":
        for call in re.finditer(r"FileProviderEnumerator\(([^\n]+)", text):
            require("providerRoot:" in call[1], "enumerator call missing authorized root")
        require(text.count("NSFileProviderError(.notAuthenticated)") >= 6,
                "extension entry points must fail explicitly without a group")
print("PASS supplementary production storage/extension source wiring guards")
