import Foundation

/// Main-app storage policy. Extensions must NOT use the sandbox fallback:
/// their sandboxes are different and cannot be used as a shared transport.
/// Pure Foundation and injectable, so nil-container launch is runtime-tested
/// without constructing UIApplication, a view model, or an Apple entitlement.
struct AppGroupStoragePaths: Sendable {
    let appGroupContainer: URL?
    let fallbackContainer: URL

    init(appGroupContainer: URL?, libraryDirectory: URL) {
        self.appGroupContainer = appGroupContainer
        self.fallbackContainer = libraryDirectory
            .appendingPathComponent("MinisLocalStorage", isDirectory: true)
    }

    var isUsingLocalFallback: Bool { appGroupContainer == nil }

    private var selectedContainer: URL { appGroupContainer ?? fallbackContainer }

    /// Same path as previous releases whenever the group is available.
    var providerRoot: URL {
        selectedContainer.appendingPathComponent("MinisFileProvider", isDirectory: true)
    }

    /// Always a sibling of providerRoot; never exported by FileProvider.
    var privateConfigRoot: URL {
        selectedContainer.appendingPathComponent("MinisConfig", isDirectory: true)
    }

    func userDirectory(_ name: String) -> URL {
        providerRoot.appendingPathComponent(name, isDirectory: true)
    }

    struct MigrationResult: Sendable {
        let skipped: Bool
        let moved: Int
        let retainedConflicts: Int
    }

    /// Legacy group migration only. Never migrate into a main-app fallback as
    /// if it were an extension container; never replace an existing destination.
    func migrateLegacyDirectory(from source: URL, to destination: URL,
                                fileManager: FileManager = .default) throws -> MigrationResult {
        guard appGroupContainer != nil else {
            return MigrationResult(skipped: true, moved: 0, retainedConflicts: 0)
        }
        guard fileManager.fileExists(atPath: source.path) else {
            return MigrationResult(skipped: false, moved: 0, retainedConflicts: 0)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        var moved = 0
        var retained = 0
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                retained += 1
            } else {
                try fileManager.moveItem(at: item, to: target)
                moved += 1
            }
        }
        // Enumeration failure must NEVER mean "empty, safe to delete".
        if try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).isEmpty {
            try fileManager.removeItem(at: source)
        }
        return MigrationResult(skipped: false, moved: moved, retainedConflicts: retained)
    }

    struct RetainedFallback: Codable, Sendable {
        let retainedContainerPath: String
        let activeContainerPath: String
        let policy: String
    }

    /// No recursive work or bulk migration on the synchronous launch path.
    /// If entitlement access returns, retain the original fallback byte-for-byte
    /// and leave a private, persistent recovery notice. Automatic replay could
    /// overwrite newer group data or resurrect files intentionally deleted there.
    /// A future explicit recovery flow can merge the retained tree with consent.
    @discardableResult
    func prepare(fileManager: FileManager = .default) throws -> RetainedFallback? {
        try fileManager.createDirectory(at: privateConfigRoot, withIntermediateDirectories: true)
        for name in ["memory", "skills", "shared"] {
            try fileManager.createDirectory(at: userDirectory(name), withIntermediateDirectories: true)
        }
        guard let group = appGroupContainer,
              group.standardizedFileURL != fallbackContainer.standardizedFileURL,
              fileManager.fileExists(atPath: fallbackContainer.path) else { return nil }
        let notice = RetainedFallback(
            retainedContainerPath: fallbackContainer.path,
            activeContainerPath: group.path,
            policy: "retained-not-merged; originals preserved; explicit non-overwriting recovery required"
        )
        let data = try JSONEncoder().encode(notice)
        try data.write(to: privateConfigRoot.appendingPathComponent("local-storage-recovery.json"),
                       options: .atomic)
        return notice
    }
}
