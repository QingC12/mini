import Foundation

/// Reads and writes PendingShare data to the App Group shared container.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    static let appGroupID = "group.com.openminis.app"

    private static let pendingShareKey = "pendingShare"

    /// Resolve once in each process; nil never becomes an extension-private path.
    static let appGroupContainer: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

    static var sharedDefaults: UserDefaults? {
        // A suite name alone does not prove sharing is authorized. Never turn
        // an extension's private defaults into an apparently shared transport.
        guard sharedFileDirectory != nil else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }

    /// Directory in the shared container for transferring attachment files.
    static var sharedFileDirectory: URL? {
        appGroupContainer?.appendingPathComponent("ShareExtension", isDirectory: true)
    }

    // MARK: - Write (called by Share Extension)

    @discardableResult
    static func savePendingShare(_ share: PendingShare) -> Bool {
        guard let defaults = sharedDefaults else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(share) else { return false }
        defaults.set(data, forKey: pendingShareKey)
        return defaults.synchronize()
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}
