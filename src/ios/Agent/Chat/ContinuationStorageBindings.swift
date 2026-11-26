import Foundation

/// Durable task-storage ownership, independent of provider/conversation identity.
/// Members are flattened to one physical root. References are reconstructed from
/// this atomic manifest on launch; there is no separately persisted refcount.
/// A whole-root relative symlink also covers legacy direct host-path consumers.
final class ContinuationStorageBindings: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case invalidID, corrupt, occupied, unsafePath, missingSource, storage
        var errorDescription: String? {
            switch self {
            case .invalidID: return "Continuation storage requires distinct UUID session IDs."
            case .corrupt: return "Continuation storage ownership manifest is unavailable or invalid."
            case .occupied: return "Continuation destination already contains work; nothing was overwritten."
            case .unsafePath: return "Continuation refused an unsafe storage link or root."
            case .missingSource: return "Continuation source storage root is missing."
            case .storage: return "Continuation storage ownership could not be saved safely."
            }
        }
    }
    struct State: Codable, Equatable {
        var version = 1
        var members: [String: String] = [:]
        // Durable deletion receipts make release idempotent across crashes.
        var released: [String: String] = [:]
    }
    private static let instancesLock = NSLock()
    nonisolated(unsafe) private static var instances: [String: ContinuationStorageBindings] = [:]
    static func registry(at base: URL) -> ContinuationStorageBindings {
        instancesLock.lock(); defer { instancesLock.unlock() }
        let key = base.standardizedFileURL.resolvingSymlinksInPath().path
        if let value = instances[key] { return value }
        let value = ContinuationStorageBindings(base: base)
        instances[key] = value
        return value
    }

    let base: URL
    private let lock = NSRecursiveLock()
    private var state = State()
    private var loadFailed = false
    // SQL lifecycle notifications are enqueued synchronously by ChatStore in
    // commit order. Unstructured MainActor Tasks alone may arrive out of order:
    // a late delete callback must not re-tombstone an already restored ID.
    private var lifecycleNotification: Task<Void, Never>?
    private var manifest: URL { base.appendingPathComponent(".continuation-storage-v1.json") }

    @discardableResult
    func enqueueSessionLifecycleNotification(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        let previous = lifecycleNotification
        let next = Task { @MainActor in
            if let previous { await previous.value }
            await operation()
        }
        lifecycleNotification = next
        return next
    }

    #if CONTINUATION_STORAGE_TEST_EXECUTABLE
    // Nonblocking cross-thread probe used while FileManager is paused exactly
    // between authorization and removal. No timing-based "probably blocked".
    func ownershipLockIsAvailableForTesting() -> Bool {
        guard lock.try() else { return false }
        lock.unlock()
        return true
    }
    #endif
    init(base: URL) {
        self.base = base.standardizedFileURL.resolvingSymlinksInPath()
        do {
            if Self.exists(manifest) {
                guard try FileManager.default.attributesOfItem(atPath: manifest.path)[.type] as? FileAttributeType == .typeRegular else { throw Failure.corrupt }
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: manifest))
                try Self.validate(state)
            }
        } catch { loadFailed = true }
    }

    static func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
    private static func validate(_ value: State) throws {
        guard value.version == 1 else { throw Failure.corrupt }
        for (member, root) in value.members.merging(value.released, uniquingKeysWith: { a, _ in a }) {
            guard validID(member), validID(root) else { throw Failure.corrupt }
        }
        guard Set(value.members.keys).isDisjoint(with: value.released.keys) else { throw Failure.corrupt }
        // Members may reference a retired original owner, but never another alias.
        for root in value.members.values {
            if let next = value.members[root], next != root { throw Failure.corrupt }
        }
    }
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private func save(_ next: State) throws {
        try Self.validate(next)
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: manifest, options: .atomic)
            state = next
        } catch { throw Failure.storage }
    }
    /// Fast, locked, in-memory lookup for the fakefs hot path. On a corrupt
    /// manifest never route into a guessed physical owner.
    func rootID(for sessionID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed, Self.validID(sessionID) else { return nil }
        return state.members[sessionID] ?? sessionID
    }
    func registered(_ sessionID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registeredWhileLocked(sessionID)
    }
    private func registeredWhileLocked(_ sessionID: String) -> Bool {
        let id = sessionID.uppercased()
        return loadFailed || state.members.keys.contains { $0.uppercased() == id }
            || state.members.values.contains { $0.uppercased() == id }
            || state.released.keys.contains { $0.uppercased() == id }
    }

    /// Clear-files/media must linearize with bind/release. The ownership check
    /// AND every filesystem removal are under the same registry lock, including
    /// background Storage UI callers. A preflight registered() Boolean is never
    /// authorization to delete after its lock has been released.
    @discardableResult
    func removeUnsharedStorage(_ id: String, subdirectories: [String]? = nil,
                               fm: FileManager = .default) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { throw Failure.corrupt }
        guard Self.validID(id) else { throw Failure.invalidID }
        guard !registeredWhileLocked(id) else { return false }
        try requireDirectory(base)
        let root = base.appendingPathComponent(id, isDirectory: true)
        guard Self.exists(root) else { return false }
        try requireDirectory(root) // Never clear an unregistered root symlink.
        let targets: [URL]
        if let subdirectories {
            guard subdirectories.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else { throw Failure.unsafePath }
            targets = subdirectories.map { root.appendingPathComponent($0) }
        } else { targets = [root] }
        var removed = false
        for target in targets where Self.exists(target) {
            try fm.removeItem(at: target)
            removed = true
        }
        return removed
    }
    func protectedRootIDs() -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { return nil }
        return Set(state.members.values)
    }
    func memberIDs(forRoot root: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return state.members.filter { $0.value == root }.map(\.key).sorted()
    }
    private func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { throw Failure.unsafePath }
    }
    private func validAlias(_ alias: URL, root: String) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: alias.path)[.type],
              type as? FileAttributeType == .typeSymbolicLink,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target == root else { return false }
        return alias.resolvingSymlinksInPath().standardizedFileURL == base.appendingPathComponent(root).standardizedFileURL
    }

    /// Atomic intent first, no-overwrite alias publication second. A crash in
    /// between leaves a protected reference that the same prepare reconciles.
    @discardableResult
    func bind(source: String, destination: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { throw Failure.corrupt }
        guard Self.validID(source), Self.validID(destination), source.lowercased() != destination.lowercased() else { throw Failure.invalidID }
        guard state.released[source] == nil, state.released[destination] == nil else { throw Failure.occupied }
        try requireDirectory(base)
        let root = state.members[source] ?? source
        let rootURL = base.appendingPathComponent(root, isDirectory: true)
        guard Self.exists(rootURL) else { throw Failure.missingSource }
        try requireDirectory(rootURL)
        let sourceURL = base.appendingPathComponent(source, isDirectory: true)
        if source != root { guard validAlias(sourceURL, root: root) else { throw Failure.unsafePath } }
        let destinationURL = base.appendingPathComponent(destination, isDirectory: true)
        if let existing = state.members[destination] {
            guard existing == root else { throw Failure.occupied }
            if Self.exists(destinationURL) {
                guard validAlias(destinationURL, root: root) else { throw Failure.occupied }
                return root
            }
        } else {
            guard !Self.exists(destinationURL) else { throw Failure.occupied }
            var next = state
            next.members[source] = root
            next.members[destination] = root
            try save(next)
        }
        // createSymbolicLink is an exclusive create, not rename()'s replace.
        // The manifest already owns this exact absent destination; EEXIST fails
        // closed, and a subsequent prepare validates it instead of overwriting.
        do { try FileManager.default.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: root) }
        catch { throw Failure.occupied }
        guard validAlias(destinationURL, root: root) else { throw Failure.unsafePath }
        return root
    }

    /// Rebuild live ownership BEFORE replaying any deletion receipt. Backup
    /// restore intentionally reuses session IDs. Its row arrives before files,
    /// so an absent restored directory still reserves its own physical root;
    /// an existing path must be a contained real root or its exact known alias.
    @discardableResult
    func restoreLiveReferences(liveSessionIDs: Set<String>) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { throw Failure.corrupt }
        let live = Set(liveSessionIDs.map { $0.uppercased() })
        var next = state
        for (id, priorRoot) in state.released where live.contains(id.uppercased()) {
            let path = base.appendingPathComponent(id, isDirectory: true)
            let root: String
            if Self.exists(path) {
                let type = try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    guard id != priorRoot, validAlias(path, root: priorRoot) else { throw Failure.unsafePath }
                    root = priorRoot
                } else {
                    try requireDirectory(path)
                    root = id // A restored alias can now be an independent root.
                }
            } else { root = id }
            next.released.removeValue(forKey: id)
            next.members[id] = root
        }
        // Protect a live physical owner even if an old/incomplete receipt did
        // not preserve its self-reference. Never delete based on counts alone.
        for root in Set(next.members.values) where live.contains(root.uppercased()) {
            let path = base.appendingPathComponent(root, isDirectory: true)
            if Self.exists(path) { try requireDirectory(path) }
            next.released.removeValue(forKey: root)
            next.members[root] = root
        }
        guard next != state else { return false }
        try save(next)
        return true
    }

    /// Authoritative SQL live-row snapshot MUST be taken by ChatStore in the
    /// same synchronous actor operation as this call. No await/detached cleanup.
    @discardableResult
    func reconcile(liveSessionIDs: Set<String>) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        _ = try restoreLiveReferences(liveSessionIDs: liveSessionIDs)
        let live = Set(liveSessionIDs.map { $0.uppercased() })
        let stale = state.members.keys.filter { !live.contains($0.uppercased()) }.sorted()
        for id in stale { _ = try releaseWhileLocked(id, live: live) }
        for id in state.released.keys.sorted() where !live.contains(id.uppercased()) {
            _ = try releaseWhileLocked(id, live: live)
        }
        return stale
    }

    /// No liveness-free destructive overload: callers must hold the ChatStore
    /// actor from current live-row read through this complete locked operation.
    @discardableResult
    func releaseDeletedSession(_ id: String, liveSessionIDs: Set<String>) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        _ = try restoreLiveReferences(liveSessionIDs: liveSessionIDs)
        return try releaseWhileLocked(id, live: Set(liveSessionIDs.map { $0.uppercased() }))
    }

    private func releaseWhileLocked(_ id: String, live: Set<String>) throws -> Bool {
        guard !loadFailed else { throw Failure.corrupt }
        guard Self.validID(id) else { throw Failure.invalidID }
        guard !live.contains(id.uppercased()) else { return false }
        try requireDirectory(base)
        let root = state.members[id] ?? state.released[id] ?? id
        var next = state
        next.members.removeValue(forKey: id)
        next.released[id] = root
        try save(next) // Save dereference before removing any filesystem object.
        let fm = FileManager.default
        let alias = base.appendingPathComponent(id, isDirectory: true)
        var removed = false
        if id != root, Self.exists(alias) {
            guard validAlias(alias, root: root) else { throw Failure.unsafePath }
            try fm.removeItem(at: alias)
            removed = true
        }
        // SQL liveness independently protects the physical owner, even if an
        // ownership receipt was stale. In particular: delete A, restore A, then
        // delete last successor B must NEVER recursively remove restored A.
        if !live.contains(root.uppercased()), !state.members.values.contains(root) {
            let physical = base.appendingPathComponent(root, isDirectory: true)
            if Self.exists(physical) {
                try requireDirectory(physical)
                try fm.removeItem(at: physical)
                removed = true
            }
        }
        return removed
    }
}
