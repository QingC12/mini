import Foundation

#if CONTINUATION_STORAGE_TEST_EXECUTABLE
private final class StorageTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class StorageRemovalProbe: FileManager, @unchecked Sendable {
    private let beforeRemoval: @Sendable () throws -> Void
    private var intercepted = false
    init(_ beforeRemoval: @escaping @Sendable () throws -> Void) {
        self.beforeRemoval = beforeRemoval
        super.init()
    }
    override func removeItem(at URL: URL) throws {
        if !intercepted { intercepted = true; try beforeRemoval() }
        try super.removeItem(at: URL)
    }
}

@main
struct ContinuationStorageTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("continuation-storage-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var checks = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw NSError(domain: "ContinuationStorageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1; print("PASS: " + name)
        }
        func refuses(_ name: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try check(name, rejected)
        }
        func fixture() throws -> (URL, String, String) {
            let base = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let source = UUID().uuidString
            let destination = UUID().uuidString
            for path in ["workspace/.git", "offloads", "attachments/uploads", "browser", "images", "future-bucket"] {
                try fm.createDirectory(at: base.appendingPathComponent(source + "/" + path), withIntermediateDirectories: true)
            }
            for path in ["workspace/.hidden", "workspace/.git/index", "workspace/dirty.swift", "workspace/untracked", "attachments/uploads/a.dat", "offloads/result", "images/photo", "future-bucket/new"] {
                try Data(("original:" + path).utf8).write(to: base.appendingPathComponent(source + "/" + path))
            }
            return (base, source, destination)
        }
        let (base, source, destination) = try fixture()
        let registry = ContinuationStorageBindings.registry(at: base)
        let commandFile = base.appendingPathComponent(source + "/workspace/dirty.swift")
        let runningWriter = try FileHandle(forWritingTo: commandFile) // open BEFORE handoff
        try check("bind publishes original owner", try registry.bind(source: source, destination: destination) == source)
        try check("destination is stable relative symlink", try fm.destinationOfSymbolicLink(atPath: base.appendingPathComponent(destination).path) == source)
        for path in ["workspace/.hidden", "workspace/.git/index", "workspace/dirty.swift", "workspace/untracked", "attachments/uploads/a.dat", "offloads/result", "images/photo", "future-bucket/new"] {
            try check("same original bytes: " + path, try Data(contentsOf: base.appendingPathComponent(destination + "/" + path)) == Data(("original:" + path).utf8))
        }
        try runningWriter.seekToEnd()
        try runningWriter.write(contentsOf: Data("-background-job-continues".utf8))
        try runningWriter.close()
        try check("existing open file writes appear in new conversation", String(decoding: try Data(contentsOf: base.appendingPathComponent(destination + "/workspace/dirty.swift")), as: UTF8.self).hasSuffix("-background-job-continues"))
        try check("retry is idempotent", try registry.bind(source: source, destination: destination) == source)
        let chain = UUID().uuidString
        try check("chain flattened to original physical owner", try registry.bind(source: destination, destination: chain) == source)
        try check("chain symlink is flat, not alias-to-alias", try fm.destinationOfSymbolicLink(atPath: base.appendingPathComponent(chain).path) == source)
        let restarted = ContinuationStorageBindings(base: base)
        try check("restart rebuilds ownership from manifest", restarted.memberIDs(forRoot: source).count == 3 && restarted.rootID(for: chain) == source)
        try check("clear-files refuses shared source", !SessionStorageCleanup.removeSessionDirectory(source, minisBase: base))
        try check("clear-files refuses continuation alias", !SessionStorageCleanup.removeSessionDirectory(destination, minisBase: base))
        _ = try SessionStorageCleanup.releaseDeletedSession(source, minisBase: base, liveSessionIDs: [destination, chain])
        try check("deleting source retains physical files", fm.fileExists(atPath: commandFile.path))
        let scan = SessionStorageCleanup.orphanedSessionDirectories(among: [source], minisBase: base, knownSessionIds: [destination, chain], now: Date().addingTimeInterval(10000), grace: 0)
        try check("orphan scan protects retired physical owner", scan.removable.isEmpty && scan.recentlyChanged.isEmpty)
        _ = try SessionStorageCleanup.releaseDeletedSession(destination, minisBase: base, liveSessionIDs: [chain])
        try check("deleting middle member removes only its link", !ContinuationStorageBindings.exists(base.appendingPathComponent(destination)) && fm.fileExists(atPath: commandFile.path))
        _ = try SessionStorageCleanup.releaseDeletedSession(chain, minisBase: base, liveSessionIDs: [])
        try check("last reference deletes physical root", !fm.fileExists(atPath: base.appendingPathComponent(source).path))
        try check("release is idempotent", try !SessionStorageCleanup.releaseDeletedSession(chain, minisBase: base, liveSessionIDs: []))

        let (occupiedBase, a, b) = try fixture()
        let occupied = ContinuationStorageBindings(base: occupiedBase)
        let destinationDir = occupiedBase.appendingPathComponent(b, isDirectory: true)
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: false)
        try Data("user-edited".utf8).write(to: destinationDir.appendingPathComponent("keep"))
        try refuses("never overwrite an existing destination") { _ = try occupied.bind(source: a, destination: b) }
        try check("occupied destination bytes untouched", try Data(contentsOf: destinationDir.appendingPathComponent("keep")) == Data("user-edited".utf8))
        try refuses("path traversal IDs rejected") { _ = try occupied.bind(source: a, destination: "../escape") }
        try refuses("case-only identical UUID rejected") { _ = try occupied.bind(source: a, destination: a.lowercased()) }
        let escaped = UUID().uuidString
        try fm.createSymbolicLink(atPath: occupiedBase.appendingPathComponent(escaped).path, withDestinationPath: temp.path)
        try refuses("outside destination symlink never followed") { _ = try occupied.bind(source: a, destination: escaped) }
        try refuses("outside source symlink never used as physical owner") { _ = try occupied.bind(source: escaped, destination: UUID().uuidString) }
        let (reverseBase, original, successor) = try fixture()
        let reverse = ContinuationStorageBindings(base: reverseBase)
        _ = try reverse.bind(source: original, destination: successor)
        _ = try reverse.releaseDeletedSession(successor, liveSessionIDs: [original])
        try check("deleting successor first preserves original", fm.fileExists(atPath: reverseBase.appendingPathComponent(original + "/workspace/.hidden").path))
        _ = try reverse.releaseDeletedSession(original, liveSessionIDs: [])
        try check("reverse deletion order reclaims final root", !fm.fileExists(atPath: reverseBase.appendingPathComponent(original).path))

        let (recoveryBase, old, new) = try fixture()
        var intent = ContinuationStorageBindings.State()
        intent.members = [old: old, new: old]
        try JSONEncoder().encode(intent).write(to: recoveryBase.appendingPathComponent(".continuation-storage-v1.json"), options: .atomic)
        let recovery = ContinuationStorageBindings(base: recoveryBase)
        try check("crash after manifest before alias publication reconciles", try recovery.bind(source: old, destination: new) == old)
        let last = UUID().uuidString
        _ = try recovery.bind(source: new, destination: last)
        try check("committed manifest reconstructs count instead of incrementing", recovery.memberIDs(forRoot: old).count == 3)
        let badBase = temp.appendingPathComponent("corrupt", isDirectory: true)
        try fm.createDirectory(at: badBase, withIntermediateDirectories: false)
        try Data("not-json".utf8).write(to: badBase.appendingPathComponent(".continuation-storage-v1.json"))
        let bad = ContinuationStorageBindings(base: badBase)
        try refuses("corrupt ownership manifest fails closed") { _ = try bad.bind(source: UUID().uuidString, destination: UUID().uuidString) }
        try check("corrupt manifest disables orphan deletion", bad.protectedRootIDs() == nil && bad.registered(UUID().uuidString))
        let tamperedAlias = recoveryBase.appendingPathComponent(new)
        try fm.removeItem(at: tamperedAlias)
        try fm.createSymbolicLink(atPath: tamperedAlias.path, withDestinationPath: temp.path)
        try refuses("retry rejects redirected destination alias") { _ = try recovery.bind(source: old, destination: new) }
        try refuses("release refuses redirected alias") { _ = try recovery.releaseDeletedSession(new, liveSessionIDs: [old, last]) }
        try check("outside tree remains intact after refused release", fm.fileExists(atPath: temp.path))

        let (deleteCrashBase, removedRow, liveRow) = try fixture()
        let deleteCrash = ContinuationStorageBindings(base: deleteCrashBase)
        _ = try deleteCrash.bind(source: removedRow, destination: liveRow)
        let restoredAfterDelete = ContinuationStorageBindings(base: deleteCrashBase)
        try check("DB-delete-before-release crash reconstructs live references", try restoredAfterDelete.reconcile(liveSessionIDs: [liveRow]) == [removedRow])
        try check("reconciliation retains live continuation files", fm.fileExists(atPath: deleteCrashBase.appendingPathComponent(liveRow + "/workspace/.hidden").path))
        _ = try restoredAfterDelete.reconcile(liveSessionIDs: [])
        try check("crash reconciliation reclaims final unreferenced root", !fm.fileExists(atPath: deleteCrashBase.appendingPathComponent(removedRow).path))
        try check("reconciliation itself is idempotent", try restoredAfterDelete.reconcile(liveSessionIDs: []).isEmpty)

        // P1-2: an explicitly restored original ID revokes its old receipt.
        // Exercise restart/reconcile AND the adjacent direct-release path.
        for reconcileFirst in [false, true] {
            let (restoredBase, root, child) = try fixture()
            let owner = ContinuationStorageBindings.registry(at: restoredBase)
            _ = try owner.bind(source: root, destination: child)
            _ = try owner.releaseDeletedSession(root, liveSessionIDs: [child])
            let restoredFile = restoredBase.appendingPathComponent(root + "/workspace/restored")
            try Data("restored-live-root".utf8).write(to: restoredFile)
            let afterRestart = ContinuationStorageBindings(base: restoredBase)
            if reconcileFirst { _ = try afterRestart.reconcile(liveSessionIDs: [root, child]) }
            _ = try afterRestart.releaseDeletedSession(child, liveSessionIDs: [root])
            try check("restored original survives last successor release (reconcile=\(reconcileFirst))",
                      try Data(contentsOf: restoredFile) == Data("restored-live-root".utf8))
            try check("restored original regains durable self ownership", afterRestart.memberIDs(forRoot: root) == [root])
            let replacement = UUID().uuidString
            try check("restored ID can bind again, not blocked by old receipt", try afterRestart.bind(source: root, destination: replacement) == root)
            _ = try afterRestart.releaseDeletedSession(replacement, liveSessionIDs: [root])
            _ = try afterRestart.releaseDeletedSession(root, liveSessionIDs: [])
            try check("restored root still reclaims after its real final row deletion", !ContinuationStorageBindings.exists(restoredBase.appendingPathComponent(root)))
        }
        let (absentBase, absentRoot, absentChild) = try fixture()
        let absent = ContinuationStorageBindings.registry(at: absentBase)
        _ = try absent.bind(source: absentRoot, destination: absentChild)
        _ = try absent.releaseDeletedSession(absentRoot, liveSessionIDs: [absentChild])
        // Backup restores SQL before files. Reserve even a currently absent tree.
        try fm.removeItem(at: absentBase.appendingPathComponent(absentRoot))
        _ = try absent.restoreLiveReferences(liveSessionIDs: [absentRoot, absentChild])
        try fm.createDirectory(at: absentBase.appendingPathComponent(absentRoot + "/workspace"), withIntermediateDirectories: true)
        let laterFile = absentBase.appendingPathComponent(absentRoot + "/workspace/later")
        try Data("row-before-files".utf8).write(to: laterFile)
        _ = try absent.releaseDeletedSession(absentChild, liveSessionIDs: [absentRoot])
        try check("row-before-files restore is protected from old deletion receipts", fm.fileExists(atPath: laterFile.path))
        try check("late duplicate deletion cannot release a live row", try !absent.releaseDeletedSession(absentRoot, liveSessionIDs: [absentRoot]))

        // A restored alias may be an independent physical backup tree now.
        let (aliasBase, aliasRoot, aliasChild) = try fixture()
        let aliasOwner = ContinuationStorageBindings.registry(at: aliasBase)
        _ = try aliasOwner.bind(source: aliasRoot, destination: aliasChild)
        _ = try aliasOwner.releaseDeletedSession(aliasChild, liveSessionIDs: [aliasRoot])
        try fm.createDirectory(at: aliasBase.appendingPathComponent(aliasChild + "/workspace"), withIntermediateDirectories: true)
        _ = try aliasOwner.restoreLiveReferences(liveSessionIDs: [aliasRoot, aliasChild])
        try check("restored independent alias is not routed to old root", aliasOwner.rootID(for: aliasChild) == aliasChild)
        _ = try aliasOwner.releaseDeletedSession(aliasRoot, liveSessionIDs: [aliasChild])
        try check("deleting old root preserves independently restored child tree", fm.fileExists(atPath: aliasBase.appendingPathComponent(aliasChild + "/workspace").path))

        let (unsafeRestoreBase, unsafeRoot, unsafeChild) = try fixture()
        let unsafeRestore = ContinuationStorageBindings.registry(at: unsafeRestoreBase)
        _ = try unsafeRestore.bind(source: unsafeRoot, destination: unsafeChild)
        _ = try unsafeRestore.releaseDeletedSession(unsafeChild, liveSessionIDs: [unsafeRoot])
        try fm.createSymbolicLink(atPath: unsafeRestoreBase.appendingPathComponent(unsafeChild).path, withDestinationPath: temp.path)
        try refuses("restore rejects a redirected released alias") {
            _ = try unsafeRestore.restoreLiveReferences(liveSessionIDs: [unsafeRoot, unsafeChild])
        }
        try refuses("unsafe revived reference blocks destructive release") {
            _ = try unsafeRestore.releaseDeletedSession(unsafeRoot, liveSessionIDs: [unsafeChild])
        }
        try check("unsafe restore never dereferences a live root or outside directory", fm.fileExists(atPath: unsafeRestoreBase.appendingPathComponent(unsafeRoot + "/workspace/.hidden").path) && fm.fileExists(atPath: temp.path))

        // P1-3, bind wins: even a previously observed "unshared" answer is
        // never deletion authority. Test whole-root AND the exact media helper.
        for mediaOnly in [false, true] {
            let (raceBase, raceRoot, raceChild) = try fixture()
            let raceOwner = ContinuationStorageBindings.registry(at: raceBase)
            try check("unbound fixture starts unregistered", !raceOwner.registered(raceRoot))
            _ = try raceOwner.bind(source: raceRoot, destination: raceChild)
            let removed = mediaOnly
                ? SessionStorageCleanup.removeSessionMedia(raceRoot, subdirectories: ["attachments", "images"], minisBase: raceBase)
                : SessionStorageCleanup.removeSessionDirectory(raceRoot, minisBase: raceBase)
            try check("bind wins over stale clear preflight (media=\(mediaOnly))", !removed)
            try check("bound root and attachments remain complete", fm.fileExists(atPath: raceBase.appendingPathComponent(raceChild + "/attachments/uploads/a.dat").path))
        }
        // Cleanup wins: stop at the REAL removeItem call, i.e. immediately
        // after ownership authorization. A cross-thread tryLock proves the
        // lock is still held without a sleep or scheduler-dependent timeout.
        for mediaOnly in [false, true] {
            let (raceBase, raceRoot, raceChild) = try fixture()
            let raceOwner = ContinuationStorageBindings.registry(at: raceBase)
            let reachedRemoval = DispatchSemaphore(value: 0)
            let continueRemoval = DispatchSemaphore(value: 0)
            let cleanupDone = DispatchSemaphore(value: 0)
            let bindStarted = DispatchSemaphore(value: 0)
            let bindDone = DispatchSemaphore(value: 0)
            let cleanupResult = StorageTestBox(false)
            let bindResult = StorageTestBox<Result<String, Error>?>(nil)
            let probe = StorageRemovalProbe {
                reachedRemoval.signal()
                guard continueRemoval.wait(timeout: .now() + 10) == .success else {
                    throw NSError(domain: "StorageRemovalProbe", code: 1)
                }
            }
            DispatchQueue.global().async {
                let removed = mediaOnly
                    ? SessionStorageCleanup.removeSessionMedia(raceRoot, subdirectories: ["attachments", "images"], minisBase: raceBase, fm: probe)
                    : SessionStorageCleanup.removeSessionDirectory(raceRoot, minisBase: raceBase, fm: probe)
                cleanupResult.set(removed)
                cleanupDone.signal()
            }
            try check("clear reaches authorized filesystem removal", reachedRemoval.wait(timeout: .now() + 10) == .success)
            let lockWasHeld = !raceOwner.ownershipLockIsAvailableForTesting()
            DispatchQueue.global().async {
                bindStarted.signal()
                bindResult.set(Result { try raceOwner.bind(source: raceRoot, destination: raceChild) })
                bindDone.signal()
            }
            let didStart = bindStarted.wait(timeout: .now() + 10) == .success
            continueRemoval.signal() // Do not strand a worker on test failure.
            try check("bind contender was launched at removal barrier", didStart)
            try check("ownership check and removal share bind lock (media=\(mediaOnly))", lockWasHeld)
            try check("clear finishes after releasing removal barrier", cleanupDone.wait(timeout: .now() + 10) == .success && cleanupResult.get())
            try check("contending bind finishes", bindDone.wait(timeout: .now() + 10) == .success)
            if mediaOnly {
                try check("media cleanup linearizes BEFORE successful bind", try bindResult.get()!.get() == raceRoot)
                try check("media cleanup keeps workspace for later bind", fm.fileExists(atPath: raceBase.appendingPathComponent(raceChild + "/workspace/.hidden").path))
                try check("media removal was authorized before bind, not silently skipped", !fm.fileExists(atPath: raceBase.appendingPathComponent(raceChild + "/attachments/uploads/a.dat").path))
            } else {
                var refused = false
                if case .failure? = bindResult.get() { refused = true }
                try check("whole-root cleanup wins, so bind cannot publish dangling ownership", refused && !raceOwner.registered(raceChild))
            }
        }
        try check("corrupt manifest also blocks whole-root and media cleanup",
                  !SessionStorageCleanup.removeSessionDirectory(UUID().uuidString, minisBase: badBase)
                  && !SessionStorageCleanup.removeSessionMedia(UUID().uuidString, subdirectories: ["attachments"], minisBase: badBase))

        let settingsURL = temp.appendingPathComponent("settings.json")
        let settings = ContinuationSettings.Snapshot(version: 1, source: old, destination: new,
            binding: Data("actual-entry-and-group-reference".utf8), inference: Data("max".utf8),
            memoryEnabled: false, skills: ["enabled": true, "disabled": false], mcp: ["server": false])
        try check("nondefault settings checkpoint round trips", try ContinuationSettings.checkpoint(settings, at: settingsURL) == settings)
        let changed = ContinuationSettings.Snapshot(version: 1, source: old, destination: new,
            binding: Data("different-default".utf8), inference: Data("off".utf8), memoryEnabled: true,
            skills: [:], mcp: [:])
        try check("retry retains original settings, not new defaults", try ContinuationSettings.checkpoint(changed, at: settingsURL) == settings)
        let conflict = ContinuationSettings.Snapshot(version: 1, source: UUID().uuidString, destination: new,
            binding: Data(), inference: Data(), memoryEnabled: true, skills: [:], mcp: [:])
        try refuses("settings receipt cannot be stolen by another source") { _ = try ContinuationSettings.checkpoint(conflict, at: settingsURL) }
        let settingsLink = temp.appendingPathComponent("settings-link.json")
        try fm.createSymbolicLink(atPath: settingsLink.path, withDestinationPath: settingsURL.path)
        try refuses("settings checkpoint rejects symlink control file") { _ = try ContinuationSettings.checkpoint(settings, at: settingsLink) }
        print("PASS: \(checks) real production storage/settings-core checks")
        let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let integration = Process()
        integration.executableURL = URL(fileURLWithPath: "/bin/sh")
        integration.arguments = [rootURL.appendingPathComponent("tests/run_continuation_storage_integration_tests.sh").path]
        try integration.run()
        integration.waitUntilExit()
        guard integration.terminationReason == .exit, integration.terminationStatus == 0 else {
            print("FAIL/UNEXECUTED: required SQL storage suite exited \(integration.terminationStatus); not a pass.")
            exit(integration.terminationStatus == 0 ? 1 : integration.terminationStatus)
        }
    }
}
#else
// Existing standalone runner interprets one file. Delegate to an isolated compile
// of the actual production Foundation sources, not a reimplemented simulator.
private let continuationStorageStandaloneAdapter: Void = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [root.appendingPathComponent("tests/run_continuation_storage_tests.sh").path]
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) }
    catch { print("FAIL: cannot run isolated storage tests"); exit(1) }
}()
#endif
