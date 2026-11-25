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
    private var manifest: URL { base.appendingPathComponent(".continuation-storage-v1.json") }
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
        return loadFailed || state.members[sessionID] != nil || state.members.values.contains(sessionID)
            || state.released[sessionID] != nil
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

    /// Reconcile an authoritative live-row snapshot taken under ChatStore's
    /// actor (without suspension). Repairs DB-delete-before-dereference crashes;
    /// never infers liveness from directory existence or an in-memory count.
    @discardableResult
    func reconcile(liveSessionIDs: Set<String>) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { throw Failure.corrupt }
        let live = Set(liveSessionIDs.map { $0.uppercased() })
        let stale = state.members.keys.filter { !live.contains($0.uppercased()) }.sorted()
        for id in stale { _ = try releaseDeletedSession(id) }
        // Retry filesystem cleanup interrupted after a durable release receipt.
        for id in state.released.keys.sorted() where !live.contains(id.uppercased()) {
            _ = try releaseDeletedSession(id)
        }
        return stale
    }

    /// ONLY after the chat row is deleted and its writers have been stopped.
    /// Clear-files is deliberately not this operation: it must not detach a
    /// still-live chat or delete another member's files.
    @discardableResult
    func releaseDeletedSession(_ id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { throw Failure.corrupt }
        guard Self.validID(id) else { throw Failure.invalidID }
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
            try fm.removeItem(at: alias) // remove the link itself, never its target
            removed = true
        }
        if !state.members.values.contains(root) {
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
