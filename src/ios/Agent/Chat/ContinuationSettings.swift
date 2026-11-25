import Foundation
#if !CONTINUATION_STORAGE_STANDALONE
import SQLite3
#endif

/// Explicit, allow-listed session inheritance; never clones provider secrets,
/// OAuth/response IDs, permission prompts, transcripts or arbitrary defaults.
enum ContinuationSettings {
    enum Failure: Error, LocalizedError {
        case unavailableModel, changedDestination, persistence
        var errorDescription: String? {
            switch self {
            case .unavailableModel: return "The original conversation's actual model binding is unavailable; continuation did not choose a default model."
            case .changedDestination: return "Continuation settings conflict with the destination; nothing was dispatched."
            case .persistence: return "Continuation settings could not be persisted and verified."
            }
        }
    }
    /// No credentials: binding and inference encode only typed session structs.
    struct Snapshot: Codable, Equatable {
        let version: Int
        let source: String
        let destination: String
        let binding: Data
        let inference: Data
        let memoryEnabled: Bool
        let skills: [String: Bool]
        let mcp: [String: Bool]
    }
    static func checkpoint(_ proposed: Snapshot, at url: URL) throws -> Snapshot {
        do {
            if ContinuationStorageBindings.exists(url) {
                guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw Failure.persistence }
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
                guard saved.version == 1, saved.source == proposed.source,
                      saved.destination == proposed.destination else { throw Failure.changedDestination }
                return saved // The original handoff snapshot wins on retry.
            }
            try JSONEncoder().encode(proposed).write(to: url, options: .atomic)
            return proposed
        } catch let error as Failure { throw error }
        catch { throw Failure.persistence }
    }

    #if !CONTINUATION_STORAGE_STANDALONE
    @MainActor
    static func copy(from source: String, to destination: String) async throws {
        try await ChatStore.shared.continuationAssertEmptyDestination(source: source, destination: destination)
        try ContinuationWorkspace.assertAgentIdle(source, destination)
        try Task.checkCancellation()
        // Inherit privacy protection, never an unlocked/biometric authorization
        // token. Do not weaken a destination that was already locked.
        if SessionLockStore.shared.isLocked(source) { SessionLockStore.shared.lock(destination) }
        let store = ProviderConfigStore.shared
        guard let binding = store.binding(for: source),
              let selected = store.entry(for: binding.primarySource.preferredReference),
              let provider = store.instance(for: selected.providerInstanceId), provider.isEnabled,
              !selected.isHidden else { throw Failure.unavailableModel }
        // Group fallback persists the selected entry in primarySource. Keep the
        // group reference AND that entry so context limits/submodel rules remain
        // the same, rather than routing through the new-chat defaults.
        if let live = ViewModelCache.shared.get(for: source)?.resolveCurrentEntry(), live.id != selected.id {
            throw Failure.unavailableModel
        }
        let targetBinding = SessionModelBinding(sessionId: destination, primarySource: binding.primarySource,
                                                subModelSource: binding.subModelSource)
        let inference = store.inferenceConfig(for: source) ?? SessionInferenceConfig()
        let skills = Dictionary(uniqueKeysWithValues: SkillStore.shared.skills.map {
            ($0.id, SkillStore.shared.isEnabledForSession($0.id, sessionId: source))
        })
        let mcp = Dictionary(uniqueKeysWithValues: MCPStore.shared.servers.map {
            ($0.id, MCPStore.shared.isEnabledForSession($0.id, sessionId: source))
        })
        let enabled = try await ChatStore.shared.continuationMemoryValue(source)
        try ContinuationWorkspace.assertAgentIdle(source, destination)
        let proposed = Snapshot(version: 1, source: source, destination: destination,
                                binding: try JSONEncoder().encode(targetBinding),
                                inference: try JSONEncoder().encode(inference), memoryEnabled: enabled,
                                skills: skills, mcp: mcp)
        // Outside shared task root: deleting one chat must not remove another
        // member's settings receipt. The receipt contains only IDs and switches.
        let receipt = AIChatViewModel.minisPersistentBase.appendingPathComponent(".continuation-settings-" + destination + ".json")
        let saved = try checkpoint(proposed, at: receipt)
        let inheritedBinding = try JSONDecoder().decode(SessionModelBinding.self, from: saved.binding)
        let inheritedInference = try JSONDecoder().decode(SessionInferenceConfig.self, from: saved.inference)
        guard inheritedBinding.sessionId == destination,
              store.entry(for: inheritedBinding.primarySource.preferredReference) != nil else { throw Failure.unavailableModel }
        if let existing = store.binding(for: destination), existing != inheritedBinding { throw Failure.changedDestination }
        if let existing = store.inferenceConfig(for: destination), existing != inheritedInference { throw Failure.changedDestination }
        // One save avoids two detached full-config saves racing each other.
        var config = store.config
        config.sessionBindings[destination] = inheritedBinding
        config.sessionInferenceConfigs[destination] = inheritedInference
        store.applyConfig(config, orderReason: "continuation-session-settings")
        let revision = store.configRevision
        if let db = store.db {
            // Scoped transaction only. Never enqueue an extra full-config
            // replacement that can clobber a user's edits during this await.
            try await db.continuationPersistSession(destination, bindingJSON: saved.binding,
                                                    inferenceJSON: saved.inference,
                                                    databaseURL: ProviderConfigDB.defaultURL())
            guard store.configRevision == revision else { throw Failure.changedDestination }
        }
        // Read just the allow-listed fields from the normal durable JSON mirror;
        // no credentials are decoded into the snapshot or copied to any log.
        struct SessionEnvelope: Decodable {
            let sessionBindings: [String: SessionModelBinding]
            let sessionInferenceConfigs: [String: SessionInferenceConfig]
        }
        guard let persisted = try? JSONDecoder().decode(SessionEnvelope.self, from: Data(contentsOf: ProviderConfigStore.configFileURLForBackup)),
              persisted.sessionBindings[destination] == inheritedBinding,
              persisted.sessionInferenceConfigs[destination] == inheritedInference else { throw Failure.persistence }
        try await ChatStore.shared.continuationSetMemory(saved.memoryEnabled, source: source, destination: destination)
        guard store.configRevision == revision else { throw Failure.changedDestination }
        try ContinuationWorkspace.assertAgentIdle(source, destination)
        // SkillStore/MCPStore public setters silently swallow SQLite failures.
        // Their shared DB has no override cache: a throwing scoped transaction
        // persists only boolean allow-list overrides, then readback verifies it.
        try writeOverrides(saved, database: AIChatViewModel.minisPersistentBase.deletingLastPathComponent().appendingPathComponent("skills.db"))
        guard saved.skills.allSatisfy({ SkillStore.shared.isEnabledForSession($0.key, sessionId: destination) == $0.value }),
              saved.mcp.allSatisfy({ MCPStore.shared.isEnabledForSession($0.key, sessionId: destination) == $0.value }) else { throw Failure.persistence }
        if let vm = ViewModelCache.shared.get(for: destination) { vm.memoryEnabled = saved.memoryEnabled }
        // Tools/browser/agents/model-use roster/context policies/autoCompact and
        // permission levels are app-global singletons, so both IDs already use
        // the SAME live policy. Do not write global defaults or call config CLI.
        // Ask-Once grants are intentionally NOT promoted into a new session:
        // OffloadPermissionManager exposes no safe transfer API; ask again.
    }

    private static func writeOverrides(_ snapshot: Snapshot, database: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); throw Failure.persistence
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw Failure.persistence }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (table, idColumn, values) in [("session_skill_overrides", "skill_id", snapshot.skills), ("mcp_session_overrides", "server_id", snapshot.mcp)] {
            // Constants only, not model- or user-controlled SQL identifiers.
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO \(table) (session_id, \(idColumn), is_enabled) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.persistence }
            defer { sqlite3_finalize(stmt) }
            for (id, enabled) in values {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, (snapshot.destination as NSString).utf8String, -1, transient)
                sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, transient)
                sqlite3_bind_int(stmt, 3, enabled ? 1 : 0)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.persistence }
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw Failure.persistence }
        committed = true
    }
    #endif
}

#if !CONTINUATION_STORAGE_STANDALONE
extension ChatStore {
    func continuationMemoryValue(_ id: String) throws -> Bool {
        guard let db else { throw ContinuationSettings.Failure.persistence }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT memory_enabled FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { throw ContinuationSettings.Failure.persistence }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ContinuationSettings.Failure.persistence }
        return sqlite3_column_int(stmt, 0) != 0
    }
    func continuationSetMemory(_ enabled: Bool, source: String, destination: String) throws {
        try continuationAssertEmptyDestination(source: source, destination: destination)
        guard let db else { throw ContinuationSettings.Failure.persistence }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET memory_enabled = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { throw ContinuationSettings.Failure.persistence }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        sqlite3_bind_text(stmt, 2, (destination as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1,
              try continuationMemoryValue(destination) == enabled else { throw ContinuationSettings.Failure.persistence }
        invalidateSessionListCache(sessionId: destination)
    }
}
#endif

#if !CONTINUATION_STORAGE_STANDALONE
extension ProviderConfigDB {
    /// Actor-serialized, scoped local-only upsert. Data/String inputs are Sendable
    /// under Swift 6; no non-Sendable ProviderConfig crosses actor boundaries.
    /// Explicit URL permits isolated DB fixtures without touching the live store.
    func continuationPersistSession(_ id: String, bindingJSON: Data, inferenceJSON: Data, databaseURL: URL) throws {
        guard ContinuationStorageBindings.validID(id),
              let binding = String(data: bindingJSON, encoding: .utf8),
              let inference = String(data: inferenceJSON, encoding: .utf8) else { throw ContinuationSettings.Failure.persistence }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle); throw ContinuationSettings.Failure.persistence
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 3000)
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ContinuationSettings.Failure.persistence }
        var committed = false
        defer { if !committed { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) } }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (table, column, json) in [("provider_session_bindings", "binding_json", binding),
                                      ("provider_session_inference_configs", "config_json", inference)] {
            var write: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO \(table) (session_id, \(column), updated_at) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(handle, sql, -1, &write, nil) == SQLITE_OK else { throw ContinuationSettings.Failure.persistence }
            defer { sqlite3_finalize(write) }
            sqlite3_bind_text(write, 1, (id as NSString).utf8String, -1, transient)
            sqlite3_bind_text(write, 2, (json as NSString).utf8String, -1, transient)
            sqlite3_bind_double(write, 3, Date().timeIntervalSince1970)
            guard sqlite3_step(write) == SQLITE_DONE else { throw ContinuationSettings.Failure.persistence }
            var read: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT \(column) FROM \(table) WHERE session_id = ?", -1, &read, nil) == SQLITE_OK else { throw ContinuationSettings.Failure.persistence }
            defer { sqlite3_finalize(read) }
            sqlite3_bind_text(read, 1, (id as NSString).utf8String, -1, transient)
            guard sqlite3_step(read) == SQLITE_ROW, let value = sqlite3_column_text(read, 0),
                  String(cString: value) == json else { throw ContinuationSettings.Failure.persistence }
        }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ContinuationSettings.Failure.persistence }
        committed = true
    }
}
#endif
