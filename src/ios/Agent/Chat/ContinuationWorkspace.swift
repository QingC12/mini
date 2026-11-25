import Foundation
#if !CONTINUATION_STORAGE_STANDALONE
import SQLite3
#endif

/// Bind the new conversation to the EXISTING task's physical files. This is
/// deliberately not a best-effort copy: detached shell jobs keep their open
/// files, dirty git/hidden/untracked/attachments stay the exact same instances.
/// The source conversation ID/provider identity is never reused by this type.
enum ContinuationWorkspace {
    struct Receipt: Sendable {
        let storageRootID: String
        let sharedLiveStorage: Bool
    }
    #if !CONTINUATION_STORAGE_STANDALONE
    @MainActor @discardableResult
    static func prepare(sourceSessionID: String, destinationSessionID: String) async throws -> Receipt {
        _ = try await ChatStore.shared.continuationReconcileStorageOwnership()
        try await ChatStore.shared.continuationAssertEmptyDestination(source: sourceSessionID, destination: destinationSessionID)
        try assertAgentIdle(sourceSessionID, destinationSessionID)
        try Task.checkCancellation()
        // Router determines the REAL host root. No WorkspaceProvider exists in
        // this baseline. Do not derive host paths from guest /var/minis paths.
        guard let workspace = MinisFsRouter.shared.hostURL(forGuest: AIChatViewModel.minisWorkspaceLinuxDir, sid: sourceSessionID) else {
            throw ContinuationStorageBindings.Failure.unsafePath
        }
        let base = AIChatViewModel.minisPersistentBase
        let registry = ContinuationStorageBindings.registry(at: base)
        guard let rootID = registry.rootID(for: sourceSessionID),
              workspace.deletingLastPathComponent().standardizedFileURL == base.appendingPathComponent(rootID, isDirectory: true).standardizedFileURL else {
            throw ContinuationStorageBindings.Failure.unsafePath
        }
        // Synchronous MainActor mutation: no new agent start can interleave.
        // A booted kernel/background processes ARE allowed: storage is shared,
        // not copied. Coordinator owns task execution handoff/side-effect checks.
        let root = try registry.bind(source: sourceSessionID, destination: destinationSessionID)
        return Receipt(storageRootID: root, sharedLiveStorage: true)
    }

    @MainActor static func assertAgentIdle(_ source: String, _ destination: String) throws {
        for id in [source, destination] {
            guard !SessionConcurrencyManager.shared.runningSessions.contains(id),
                  ViewModelCache.shared.get(for: id)?.isProcessing != true else {
                throw ContinuationStorageBindings.Failure.occupied
            }
        }
        // Children execute as agents in the parent's task root. A detached shell
        // can keep running, but a second autonomous writer must be paused first.
        guard !AgentJobRegistry.shared.hasActiveChildren(parent: source),
              AgentJobRegistry.shared.queuedCount(parent: source) == 0 else {
            throw ContinuationStorageBindings.Failure.occupied
        }
    }
    #endif
}

#if !CONTINUATION_STORAGE_STANDALONE
extension ChatStore {
    /// Invoke on app restore and after successful session-row deletion. This
    /// actor method contains no await between the live-row read and reconcile.
    @discardableResult
    func continuationReconcileStorageOwnership() throws -> [String] {
        guard let db else { throw ContinuationStorageBindings.Failure.storage }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM sessions", -1, &stmt, nil) == SQLITE_OK else { throw ContinuationStorageBindings.Failure.storage }
        defer { sqlite3_finalize(stmt) }
        var live: Set<String> = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0) else { throw ContinuationStorageBindings.Failure.storage }
            live.insert(String(cString: text)); rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw ContinuationStorageBindings.Failure.storage }
        return try ContinuationStorageBindings.registry(at: minisBaseURL).reconcile(liveSessionIDs: live)
    }

    /// Throwing SQL guard: unlike loadMessages() an I/O/schema failure must not
    /// look like an empty destination. Called before settings/files are touched.
    func continuationAssertEmptyDestination(source: String, destination: String) throws {
        guard ContinuationStorageBindings.validID(source), ContinuationStorageBindings.validID(destination),
              source.lowercased() != destination.lowercased(), let db else {
            throw ContinuationStorageBindings.Failure.invalidID
        }
        let query = "SELECT id, parent_session_id, remote_origin_device_id FROM sessions WHERE id = ? OR id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { throw ContinuationStorageBindings.Failure.storage }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 2, (destination as NSString).utf8String, -1, transient)
        var ids: Set<String> = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0), sqlite3_column_type(stmt, 1) == SQLITE_NULL,
                  sqlite3_column_type(stmt, 2) == SQLITE_NULL else { throw ContinuationStorageBindings.Failure.occupied }
            ids.insert(String(cString: text))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE, ids == Set([source, destination]) else { throw ContinuationStorageBindings.Failure.storage }
        var count: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM messages WHERE session_id = ?", -1, &count, nil) == SQLITE_OK else { throw ContinuationStorageBindings.Failure.storage }
        defer { sqlite3_finalize(count) }
        sqlite3_bind_text(count, 1, (destination as NSString).utf8String, -1, transient)
        guard sqlite3_step(count) == SQLITE_ROW, sqlite3_column_int64(count, 0) == 0 else { throw ContinuationStorageBindings.Failure.occupied }
    }
}
#endif
