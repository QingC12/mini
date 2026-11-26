import Foundation

private enum Failure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let text): return text } }
}
private func expect(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
    if try value() == false { throw Failure.assertion(text) }
}

/// Actual filesystem operations are inherited. Only selected failure boundaries
/// are injected, so root/creation/moves/bytes/removal all exercise Foundation.
private final class FaultFileManager: FileManager, @unchecked Sendable {
    var source: URL?
    var failEnumerationNumber: Int?
    var sourceEnumerations = 0
    var sourceRemovals = 0
    var failMoveName: String?

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.standardizedFileURL == source?.standardizedFileURL {
            sourceEnumerations += 1
            if sourceEnumerations == failEnumerationNumber {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == failMoveName {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL == source?.standardizedFileURL { sourceRemovals += 1 }
        try super.removeItem(at: URL)
    }
}

private struct Fixture {
    let root: URL
    var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    var group: URL { root.appendingPathComponent("AuthorizedGroup", isDirectory: true) }
    var paths: AppGroupStoragePaths { AppGroupStoragePaths(appGroupContainer: group, libraryDirectory: library) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minis-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@main
private struct AppGroupStartupTests {
    static func main() throws {
        try nilContainerLaunch()
        try authorizedPathsUnchanged()
        try legacyMigration()
        try migrationConflicts()
        try enumerationFailures()
        try moveFailure()
        try noGroupMigrationSkipped()
        try fallbackRecovery()
        try preparationFailure()
        print("PASS: 9 real AppGroupStoragePaths/Foundation runtime scenarios")
    }

    static func nilContainerLaunch() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = AppGroupStoragePaths(appGroupContainer: nil, libraryDirectory: f.library)
        try expect(p.isUsingLocalFallback, "nil group must select fallback, not unwrap")
        let expected = f.library.appendingPathComponent("MinisLocalStorage", isDirectory: true)
        try expect(p.fallbackContainer == expected, "fallback must be stable Library/MinisLocalStorage")
        try expect(try p.prepare() == nil, "fallback launch is not group recovery")
        for name in ["shared", "skills", "memory"] {
            var isDirectory: ObjCBool = false
            try expect(FileManager.default.fileExists(atPath: p.userDirectory(name).path, isDirectory: &isDirectory) && isDirectory.boolValue,
                       "fallback user directory missing: \(name)")
        }
        try expect(f.exists(p.privateConfigRoot), "private config missing")
        let soul = p.userDirectory("memory").appendingPathComponent("SOUL.md")
        try f.write("earlier-local-soul", soul)
        // Creating the real group after resolution must not switch this process.
        try FileManager.default.createDirectory(at: f.group, withIntermediateDirectories: true)
        _ = try p.prepare()
        let restarted = AppGroupStoragePaths(appGroupContainer: nil, libraryDirectory: f.library)
        try expect(restarted.providerRoot == p.providerRoot, "repeat nil resolution must be stable")
        try expect(try f.read(soul) == "earlier-local-soul", "repeat preparation overwrote SOUL")
        print("PASS nil-container launch, stable roots, directory creation and SOUL IO")
    }

    static func authorizedPathsUnchanged() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = f.paths
        try expect(!p.isUsingLocalFallback, "authorized group must win")
        try expect(p.providerRoot == f.group.appendingPathComponent("MinisFileProvider", isDirectory: true), "existing provider path changed")
        try expect(p.privateConfigRoot == f.group.appendingPathComponent("MinisConfig", isDirectory: true), "existing config path changed")
        _ = try p.prepare(); _ = try p.prepare()
        try expect(!f.exists(p.fallbackContainer), "valid group must not create private copy")
        try expect(p.privateConfigRoot.deletingLastPathComponent() == p.providerRoot.deletingLastPathComponent(), "config is not a sibling")
        print("PASS authorized group paths unchanged, no fallback created")
    }

    static func legacyMigration() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for name in ["shared", "memory", "skills"] {
            let source = f.library.appendingPathComponent("MinisChat/\(name)", isDirectory: true)
            try f.write("legacy-\(name)", source.appendingPathComponent("nested/value.txt"))
            let result = try f.paths.migrateLegacyDirectory(from: source, to: f.paths.userDirectory(name))
            try expect(result.moved == 1 && result.retainedConflicts == 0 && !result.skipped, "legacy move failed")
            try expect(try f.read(f.paths.userDirectory(name).appendingPathComponent("nested/value.txt")) == "legacy-\(name)", "legacy bytes lost")
            try expect(!f.exists(source), "confirmed empty source not removed")
        }
        let oldGroup = f.group.appendingPathComponent("MinisShared", isDirectory: true)
        try f.write("old-group", oldGroup.appendingPathComponent("group.txt"))
        _ = try f.paths.migrateLegacyDirectory(from: oldGroup, to: f.paths.userDirectory("shared"))
        try expect(try f.read(f.paths.userDirectory("shared").appendingPathComponent("group.txt")) == "old-group", "old group migration failed")
        print("PASS all three Library legacy roots and MinisShared migration")
    }

    static func migrationConflicts() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = f.library.appendingPathComponent("legacy", isDirectory: true)
        let dest = f.paths.userDirectory("memory")
        try f.write("old-soul", source.appendingPathComponent("SOUL.md"))
        try f.write("new-soul", dest.appendingPathComponent("SOUL.md"))
        try f.write("old-nested", source.appendingPathComponent("nested/data"))
        try f.write("new-nested", dest.appendingPathComponent("nested/data"))
        try f.write("unique", source.appendingPathComponent("unique"))
        let result = try f.paths.migrateLegacyDirectory(from: source, to: dest)
        try expect(result.retainedConflicts == 2 && result.moved == 1, "wrong conflict accounting")
        try expect(try f.read(source.appendingPathComponent("SOUL.md")) == "old-soul", "conflicting original deleted")
        try expect(try f.read(dest.appendingPathComponent("SOUL.md")) == "new-soul", "current SOUL overwritten")
        try expect(try f.read(source.appendingPathComponent("nested/data")) == "old-nested", "nested conflict deleted")
        let again = try f.paths.migrateLegacyDirectory(from: source, to: dest)
        try expect(again.moved == 0 && again.retainedConflicts == 2, "repeat conflict migration not stable")
        print("PASS conflicts retain original and destination, including nested trees")
    }

    static func enumerationFailures() throws {
        for failureNumber in [1, 2] {
            let f = try Fixture(); defer { f.cleanup() }
            let source = f.library.appendingPathComponent("unreadable", isDirectory: true)
            try f.write("original", source.appendingPathComponent("value"))
            let fm = FaultFileManager()
            fm.source = source; fm.failEnumerationNumber = failureNumber
            var threw = false
            do { _ = try f.paths.migrateLegacyDirectory(from: source, to: f.paths.userDirectory("shared"), fileManager: fm) }
            catch { threw = true }
            try expect(threw, "injected enumeration error not surfaced")
            try expect(fm.sourceRemovals == 0 && f.exists(source), "enumeration failure deleted source")
            let retained = failureNumber == 1 ? source : f.paths.userDirectory("shared")
            try expect(try f.read(retained.appendingPathComponent("value")) == "original", "enumeration failure lost bytes")
        }
        print("PASS initial and post-move enumeration failures never delete source")
    }

    static func moveFailure() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = f.library.appendingPathComponent("move-denied", isDirectory: true)
        try f.write("original", source.appendingPathComponent("denied"))
        let fm = FaultFileManager(); fm.source = source; fm.failMoveName = "denied"
        var threw = false
        do { _ = try f.paths.migrateLegacyDirectory(from: source, to: f.paths.userDirectory("shared"), fileManager: fm) }
        catch { threw = true }
        try expect(threw && fm.sourceRemovals == 0, "move failure swallowed or source removed")
        try expect(try f.read(source.appendingPathComponent("denied")) == "original", "failed move lost original")
        print("PASS move failure retains unmoved original")
    }

    static func noGroupMigrationSkipped() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = AppGroupStoragePaths(appGroupContainer: nil, libraryDirectory: f.library)
        let source = f.library.appendingPathComponent("legacy", isDirectory: true)
        try f.write("original", source.appendingPathComponent("value"))
        let result = try p.migrateLegacyDirectory(from: source, to: p.userDirectory("shared"))
        try expect(result.skipped && result.moved == 0, "nil group pretended to migrate shared data")
        try expect(try f.read(source.appendingPathComponent("value")) == "original", "nil group deleted legacy data")
        try expect(!f.exists(p.providerRoot), "skipped migration created false shared transport")
        print("PASS nil group migration leaves legacy source untouched")
    }

    static func fallbackRecovery() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let local = AppGroupStoragePaths(appGroupContainer: nil, libraryDirectory: f.library)
        _ = try local.prepare()
        let localFile = local.userDirectory("memory").appendingPathComponent("SOUL.md")
        let localOnly = local.userDirectory("shared").appendingPathComponent("deleted-in-group")
        let localConfig = local.privateConfigRoot.appendingPathComponent("mounted-folders.json")
        try f.write("local-soul", localFile)
        try f.write("local-only", localOnly)
        try f.write("local-config", localConfig)
        let groupFile = f.paths.userDirectory("memory").appendingPathComponent("SOUL.md")
        try f.write("newer-group-soul", groupFile)
        let notice = try f.paths.prepare()
        try expect(notice?.retainedContainerPath == local.fallbackContainer.path, "missing retained recovery path")
        try expect(try f.read(groupFile) == "newer-group-soul", "recovery overwrote newer group data")
        try expect(try f.read(localFile) == "local-soul", "fallback file deleted or changed")
        try expect(try f.read(localOnly) == "local-only", "local-only file deleted")
        try expect(try f.read(localConfig) == "local-config", "fallback config lost")
        try expect(!f.exists(f.paths.userDirectory("shared").appendingPathComponent("deleted-in-group")), "recovery resurrected deleted group file")
        let noticeURL = f.paths.privateConfigRoot.appendingPathComponent("local-storage-recovery.json")
        let decoded = try JSONDecoder().decode(AppGroupStoragePaths.RetainedFallback.self, from: Data(contentsOf: noticeURL))
        try expect(decoded.activeContainerPath == f.group.path && decoded.policy.contains("not-merged"), "persistent recovery notice incorrect")
        _ = try f.paths.prepare()
        try expect(f.exists(noticeURL) && f.exists(localFile), "repeat recovery lost notice or fallback")
        // A blocked notice write must also leave the fallback/group untouched.
        try FileManager.default.removeItem(at: noticeURL)
        try FileManager.default.createDirectory(at: noticeURL, withIntermediateDirectories: true)
        var threw = false
        do { _ = try f.paths.prepare() } catch { threw = true }
        try expect(threw, "blocked recovery notice write not surfaced")
        try expect(try f.read(localFile) == "local-soul", "notice failure deleted fallback")
        try expect(try f.read(groupFile) == "newer-group-soul", "notice failure overwrote group")
        print("PASS recovery preserves both trees, never replays, persists notice, fails safely")
    }

    static func preparationFailure() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let p = AppGroupStoragePaths(appGroupContainer: nil, libraryDirectory: f.library)
        try f.write("not-a-directory", p.fallbackContainer)
        var threw = false
        do { _ = try p.prepare() } catch { threw = true }
        try expect(threw, "directory failure did not become a catchable error")
        try expect(try f.read(p.fallbackContainer) == "not-a-directory", "preparation destroyed blocker")
        print("PASS preparation IO failure is catchable, never a nil unwrap trap")
    }
}
