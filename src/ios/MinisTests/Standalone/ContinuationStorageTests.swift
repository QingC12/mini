import Foundation

#if CONTINUATION_STORAGE_TEST_EXECUTABLE
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
        _ = try SessionStorageCleanup.releaseDeletedSession(source, minisBase: base)
        try check("deleting source retains physical files", fm.fileExists(atPath: commandFile.path))
        let scan = SessionStorageCleanup.orphanedSessionDirectories(among: [source], minisBase: base, knownSessionIds: [destination, chain], now: Date().addingTimeInterval(10000), grace: 0)
        try check("orphan scan protects retired physical owner", scan.removable.isEmpty && scan.recentlyChanged.isEmpty)
        _ = try SessionStorageCleanup.releaseDeletedSession(destination, minisBase: base)
        try check("deleting middle member removes only its link", !ContinuationStorageBindings.exists(base.appendingPathComponent(destination)) && fm.fileExists(atPath: commandFile.path))
        _ = try SessionStorageCleanup.releaseDeletedSession(chain, minisBase: base)
        try check("last reference deletes physical root", !fm.fileExists(atPath: base.appendingPathComponent(source).path))
        try check("release is idempotent", try !SessionStorageCleanup.releaseDeletedSession(chain, minisBase: base))

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
        _ = try reverse.releaseDeletedSession(successor)
        try check("deleting successor first preserves original", fm.fileExists(atPath: reverseBase.appendingPathComponent(original + "/workspace/.hidden").path))
        _ = try reverse.releaseDeletedSession(original)
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
        try refuses("release refuses redirected alias") { _ = try recovery.releaseDeletedSession(new) }
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
