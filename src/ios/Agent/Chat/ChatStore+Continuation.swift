import Foundation
import SQLite3

private enum ContinuationStoreError: LocalizedError {
    case storage, missingSource, invalidState
    var errorDescription: String? {
        switch self {
        case .storage: return "Native continuation could not be durably saved."
        case .missingSource: return "The source conversation no longer exists."
        case .invalidState: return "The continuation changed state; automatic dispatch was stopped."
        }
    }
}

extension ChatStore {
    /// Local-only journal/outbox. Intentionally absent from cloud-sync tables.
    private func ensureContinuationSchema() throws {
        try continuationSQL("""
            CREATE TABLE IF NOT EXISTS native_continuations (
                id TEXT PRIMARY KEY, source_session_id TEXT NOT NULL,
                attempt_id TEXT NOT NULL, destination_session_id TEXT NOT NULL UNIQUE,
                state TEXT NOT NULL, record_json TEXT NOT NULL,
                UNIQUE(source_session_id, attempt_id)
            )
            """)
        try continuationSQL("""
            CREATE UNIQUE INDEX IF NOT EXISTS one_active_continuation_per_source_v2
            ON native_continuations(source_session_id)
            WHERE state IN ('pending','destinationCreated','seedPersisted','submitting','running')
            """)
    }

    private func continuationSQL(_ sql: String, _ values: [String] = []) throws {
        guard db != nil else { throw ContinuationStoreError.storage }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContinuationStoreError.storage
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, transient) == SQLITE_OK else {
                throw ContinuationStoreError.storage
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ContinuationStoreError.storage }
    }

    private func continuationQuery(_ sql: String, _ values: [String] = []) throws -> [ContinuationRecord] {
        guard db != nil else { throw ContinuationStoreError.storage }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContinuationStoreError.storage
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, transient) == SQLITE_OK else {
                throw ContinuationStoreError.storage
            }
        }
        var rows: [ContinuationRecord] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw ContinuationStoreError.storage
            }
            let data = Data(String(cString: text).utf8)
            rows.append(try JSONDecoder().decode(ContinuationRecord.self, from: data))
        }
    }

    private func writeContinuation(_ record: ContinuationRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard let json = String(data: data, encoding: .utf8) else { throw ContinuationStoreError.storage }
        try continuationSQL("""
            INSERT INTO native_continuations(id,source_session_id,attempt_id,destination_session_id,state,record_json)
            VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,record_json=excluded.record_json
            """, [record.id, record.sourceSessionID, record.attemptID, record.destinationSessionID, record.state.rawValue, json])
    }

    func continuationRecords(activeOnly: Bool = true) throws -> [ContinuationRecord] {
        try ensureContinuationSchema()
        let filter = activeOnly ? " WHERE state NOT IN ('redirected','finished','paused','failed')" : ""
        return try continuationQuery("SELECT record_json FROM native_continuations" + filter)
    }

    func continuationRecord(id: String) throws -> ContinuationRecord? {
        try ensureContinuationSchema()
        return try continuationQuery("SELECT record_json FROM native_continuations WHERE id=?", [id]).first
    }

    /// The SQLite actor serializes claimants; the unique index is the final backstop.
    func registerContinuation(_ record: ContinuationRecord) throws -> ContinuationRecord {
        try ensureContinuationSchema()
        guard try continuationSessionExists(record.sourceSessionID) else { throw ContinuationStoreError.missingSource }
        if let existing = try continuationQuery("""
            SELECT record_json FROM native_continuations WHERE source_session_id=?
            AND (attempt_id=? OR state IN ('pending','destinationCreated','seedPersisted','submitting','running'))
            """, [record.sourceSessionID, record.attemptID]).first { return existing }
        try writeContinuation(record)
        return record
    }

    /// Session creation and outbox transition commit together, using a preallocated ID.
    func createContinuationDestination(recordID: String) throws -> ContinuationRecord {
        try ensureContinuationSchema()
        try continuationSQL("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? continuationSQL("ROLLBACK") } }
        guard var record = try continuationQuery("SELECT record_json FROM native_continuations WHERE id=?", [recordID]).first,
              !record.state.isTerminal, try continuationSessionExists(record.sourceSessionID) else {
            throw ContinuationStoreError.invalidState
        }
        let metadata = try continuationSourceMetadata(record.sourceSessionID)
        if try !continuationSessionExists(record.destinationSessionID) {
            let now = String(Date().timeIntervalSince1970)
            try continuationSQL("""
                INSERT INTO sessions(id,title,model_id,created_at,updated_at,source,memory_enabled)
                VALUES(?,?,?,?,?,'continuation',?)
                """, [record.destinationSessionID, record.title, record.sourceModelID, now, now,
                       metadata.memoryEnabled ? "1" : "0"])
            invalidateSessionListCache()
        }
        if record.state == .pending { record.state = .destinationCreated }
        record.updatedAt = Date()
        try writeContinuation(record)
        try continuationSQL("COMMIT")
        committed = true
        return record
    }
}

extension ChatStore {
    /// Terminal decisions win over a late asynchronous preparation callback.
    @discardableResult
    func transitionContinuation(id: String, to state: ContinuationRecord.State,
                                error: String? = nil, acknowledge: Bool = false) throws -> ContinuationRecord? {
        guard var record = try continuationRecord(id: id), !record.state.isTerminal else { return nil }
        record.state = state
        record.updatedAt = Date()
        record.lastError = error.map { String(ContinuationCheckpoint.redact($0).prefix(600)) }
        if acknowledge {
            record.acknowledgedAt = record.acknowledgedAt ?? Date()
            record.consecutiveFailures = 0
        }
        try writeContinuation(record)
        return record
    }

    @discardableResult
    func pauseContinuations(forSessionID sessionID: String, reason: String,
                            createdBefore cutoff: Date? = nil) throws -> [ContinuationRecord] {
        try ensureContinuationSchema()
        let records = try continuationQuery("""
            SELECT record_json FROM native_continuations
            WHERE (source_session_id=? OR destination_session_id=?)
            AND state IN ('pending','destinationCreated','seedPersisted','submitting','running')
            """, [sessionID, sessionID])
        return try records.filter { cutoff == nil || $0.createdAt <= cutoff! }.compactMap {
            try transitionContinuation(id: $0.id, to: .paused, error: reason)
        }
    }
}

/// A receipt is returned only after the seed row AND journal COMMIT succeeded.
struct ContinuationSeedReceipt {
    let record: ContinuationRecord
    let message: RawMessage
}

extension ChatStore {
    private func continuationStatement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        guard db != nil else { throw ContinuationStoreError.storage }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContinuationStoreError.storage
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw ContinuationStoreError.storage
            }
        }
        return statement
    }

    func continuationSessionExists(_ id: String) throws -> Bool {
        let statement = try continuationStatement("SELECT id FROM sessions WHERE id=?", [id])
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ContinuationStoreError.storage
        }
    }

    func continuationSourceMetadata(_ id: String) throws -> (title: String, modelID: String, memoryEnabled: Bool) {
        let statement = try continuationStatement("SELECT title,model_id,memory_enabled FROM sessions WHERE id=?", [id])
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_ROW else {
            if rc == SQLITE_DONE { throw ContinuationStoreError.missingSource }
            throw ContinuationStoreError.storage
        }
        guard let model = sqlite3_column_text(statement, 1) else { throw ContinuationStoreError.storage }
        return (sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "Task",
                String(cString: model), sqlite3_column_int(statement, 2) != 0)
    }

    /// Unlike loadMessages, neither SQLite errors nor malformed JSON mean "empty".
    /// No migration fallback: incomplete evidence must never authorize dispatch.
    func continuationMessages(sessionID: String) throws -> [RawMessage] {
        let statement = try continuationStatement("""
            SELECT id,session_id,role,parts_json,created_at,token_usage,reasoning_content,
                   stream_interrupt_count,sort_order,error_info,model_id,model_display_name,
                   provider_type,provider_instance_id,reasoning_echo
            FROM messages WHERE session_id=? ORDER BY sort_order ASC,created_at ASC,id ASC
            """, [sessionID])
        defer { sqlite3_finalize(statement) }
        var messages: [RawMessage] = []
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return messages }
            guard rc == SQLITE_ROW, let id = text(0), let sid = text(1), let roleText = text(2),
                  let role = MessageRole(rawValue: roleText), let json = text(3) else {
                throw ContinuationStoreError.storage
            }
            let parts = try JSONDecoder().decode([ContentPart].self, from: Data(json.utf8))
            let usage = try text(5).map { try JSONDecoder().decode(StoredTokenUsage.self, from: Data($0.utf8)) }
            var message = RawMessage(id: id, sessionId: sid, role: role, parts: parts,
                                     createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                                     tokenUsage: usage, reasoningContent: text(6),
                                     streamInterruptCount: Int(sqlite3_column_int64(statement, 7)))
            message.sortOrder = Int(sqlite3_column_int64(statement, 8))
            message.errorInfo = text(9)
            message.modelId = text(10)
            message.modelDisplayName = text(11)
            message.providerType = text(12)
            message.providerInstanceId = text(13)
            message.reasoningEchoJSON = text(14)
            messages.append(message)
        }
    }

    private func verifiedContinuationSeed(_ record: ContinuationRecord) throws -> RawMessage {
        let messages = try continuationMessages(sessionID: record.destinationSessionID)
        guard messages.count == 1, let message = messages.first,
              message.id == record.seedMessageID, UUID(uuidString: message.id) != nil, message.role == .user,
              message.parts.count == 1, case .text(let text) = message.parts[0],
              text == record.seed else { throw ContinuationStoreError.invalidState }
        return message
    }

    /// Refresh the bounded checkpoint and insert/update the sole first RawMessage
    /// in ONE transaction. A retry may update only our unchanged, unclaimed seed.
    func prepareContinuationSeed(recordID: String, checkpoint: String,
                                 queuedPromptIDs: [UUID]) throws -> ContinuationSeedReceipt {
        try ensureContinuationSchema()
        try continuationSQL("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? continuationSQL("ROLLBACK") } }
        guard var record = try continuationRecord(id: recordID),
              record.state == .destinationCreated || record.state == .seedPersisted,
              !record.requiresManualReconciliation,
              try continuationSessionExists(record.sourceSessionID),
              try continuationSessionExists(record.destinationSessionID) else {
            throw ContinuationStoreError.invalidState
        }
        let existing = try continuationMessages(sessionID: record.destinationSessionID)
        if record.state == .seedPersisted {
            _ = try verifiedContinuationSeed(record)
        } else if !existing.isEmpty { throw ContinuationStoreError.invalidState }
        record.checkpoint = checkpoint
        record.queuedPromptIDs = queuedPromptIDs
        record.seedMessageID = record.seedMessageID ?? UUID().uuidString
        record.state = .seedPersisted
        record.updatedAt = Date()
        let parts: [ContentPart] = [.text(record.seed)]
        let json = String(decoding: try JSONEncoder().encode(parts), as: UTF8.self)
        let messageID = record.seedMessageID!
        let timestamp = String(record.updatedAt.timeIntervalSince1970)
        if existing.isEmpty {
            try continuationSQL("""
                INSERT INTO messages(id,session_id,role,parts_json,created_at,sort_order,updated_at,part_flags)
                VALUES(?,?,'user',?,?,0,?,?)
                """, [messageID, record.destinationSessionID, json, timestamp, timestamp,
                       String(Self.partFlags(for: parts))])
        } else {
            try continuationSQL("UPDATE messages SET parts_json=?,updated_at=? WHERE id=? AND session_id=?",
                                [json, timestamp, messageID, record.destinationSessionID])
            guard sqlite3_changes(db) == 1 else { throw ContinuationStoreError.storage }
        }
        try writeContinuation(record)
        let message = try verifiedContinuationSeed(record)
        try continuationSQL("COMMIT")
        committed = true
        // Optional preview/cloud metadata is NOT the outbox receipt.
        invalidateSessionListCache(sessionId: record.destinationSessionID)
        markDirty(recordType: "Message", recordId: messageID)
        markDirty(recordType: "Session", recordId: record.destinationSessionID)
        return ContinuationSeedReceipt(record: record, message: message)
    }

    /// Irreversible at-most-once claim, committed BEFORE the first network task.
    /// If the process dies between COMMIT and launching it, prefer manual retry
    /// over risking a repeated tool, release or other external side effect.
    func claimContinuationDispatch(recordID: String, expectedSeed: String) throws -> ContinuationRecord {
        try ensureContinuationSchema()
        try continuationSQL("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? continuationSQL("ROLLBACK") } }
        guard var record = try continuationRecord(id: recordID), record.state == .seedPersisted,
              record.dispatchClaimedAt == nil, record.seed == expectedSeed,
              try continuationSessionExists(record.sourceSessionID),
              try continuationSessionExists(record.destinationSessionID) else {
            throw ContinuationStoreError.invalidState
        }
        _ = try verifiedContinuationSeed(record)
        record.state = .submitting
        record.dispatchClaimedAt = Date()
        record.updatedAt = Date()
        try writeContinuation(record)
        try continuationSQL("COMMIT")
        committed = true
        return record
    }

    /// Synchronous actor method, called BEFORE deleting any session rows. Also
    /// follows redirected edges; journal links never make the sessions owned.
    /// No BEGIN here: it can safely participate in the caller's delete transaction.
    func pauseContinuationsForDeletedSession(_ id: String) throws {
        let saved = try continuationRecords(activeOnly: false)
        var affected: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for record in saved where affected.contains(record.sourceSessionID) || affected.contains(record.destinationSessionID) {
                if affected.insert(record.destinationSessionID).inserted { changed = true }
            }
        }
        for record in saved where !record.state.isTerminal &&
            (affected.contains(record.sourceSessionID) || affected.contains(record.destinationSessionID)) {
            try transitionContinuation(id: record.id, to: .paused,
                                       error: "A linked conversation was deleted. Inspect the remaining task manually.")
        }
    }
}
