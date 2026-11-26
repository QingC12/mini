import Foundation
import SQLite3

// Only unavailable app/UI surroundings are doubles. The test runner extracts
// unchanged production function bodies, including real SQLite return checks,
// lifecycle scheduling, the live-row read and the entire registry operation.
struct AppLogger {
    init(category: String) {}
    func warning(_ message: String) { print("LOG: " + message) }
    func error(_ message: String) { print("LOG: " + message) }
}
struct ChatSession {
    let id: String
    var title: String? = nil
    var category: String? = nil
    var modelId = "test-model"
    var createdAt = Date(timeIntervalSince1970: 1)
    var updatedAt: Date
    var pinnedAt: Date? = nil
    var folderId: String? = nil
    var parentSessionId: String? = nil
    var parentToolUseId: String? = nil
}
enum TestFailure: Error { case sql(String), failed(String) }

actor ChatStore {
    var db: OpaquePointer?
    let minisBaseURL: URL
    var pauseFails = false
    init(base: URL) throws {
        minisBaseURL = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else { throw TestFailure.sql("open") }
        db = handle
        let schema = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, title TEXT, category TEXT, model_id TEXT,
                created_at REAL, updated_at REAL, memory_enabled INTEGER,
                model_binding TEXT, pinned_at REAL, folder_id TEXT,
                parent_session_id TEXT, parent_tool_use_id TEXT,
                remote_origin_device_id TEXT);
            CREATE TABLE messages (id TEXT, session_id TEXT);
            CREATE TABLE compact_markers (id TEXT, session_id TEXT);
            CREATE TABLE deletion_journal (session_id TEXT);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw TestFailure.sql("schema") }
    }
    func exec(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure.sql(sql) }
    }
    func exists(_ id: String) throws -> Bool {
        guard let db else { throw TestFailure.sql("closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { throw TestFailure.sql("exists") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    func insert(_ id: String, updated: Int = 1) throws {
        // Test IDs are generated UUIDs, never user data.
        try exec("INSERT INTO sessions(id,updated_at) VALUES ('\(id)',\(updated))")
    }
    func close() { sqlite3_close(db); db = nil }
    func invalidateSessionListCache() {}
    func pauseContinuationsForDeletedSession(_ id: String) throws {
        try exec("INSERT INTO deletion_journal VALUES ('\(id)')")
        if pauseFails { throw TestFailure.failed("journal") }
    }
    func deleteMessages(sessionId: String) { try? exec("DELETE FROM messages WHERE session_id='\(sessionId)'") }
    func deleteCompactMarkers(sessionId: String) { try? exec("DELETE FROM compact_markers WHERE session_id='\(sessionId)'") }
    func count(_ table: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { throw TestFailure.sql("count") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw TestFailure.sql("count step") }
        return Int(sqlite3_column_int(stmt, 0))
    }
    func restore(_ id: String, updated: Int = 2) -> RestoreOutcome {
        restoreSession(ChatSession(id: id, updatedAt: Date(timeIntervalSince1970: Double(updated))), memoryEnabled: true, modelBinding: nil)
    }
    // One actor turn deliberately places restore immediately next to release.
    func restoreThenRelease(root: String, child: String) throws -> Bool {
        _ = restore(root)
        try exec("DELETE FROM sessions WHERE id='\(child)'")
        return try continuationCompleteStorageDeletion(child)
    }
    // Queue all SQL lifecycle commits before letting MainActor consume them.
    func deleteRestoreSequence(_ id: String, deleteAgain: Bool) {
        testDeleteSession(id)
        _ = restore(id)
        if deleteAgain { testDeleteSession(id) }
    }
}

@MainActor final class ContinuationCoordinator {
    static let shared = ContinuationCoordinator()
    var events: [String] = []
    var deleted: Set<String> = []
    func sessionDeleted(_ id: String) { events.append("delete:" + id); deleted.insert(id) }
    func sessionRestored(_ id: String) { events.append("restore:" + id); deleted.remove(id) }
    // Deliberately retain this to detect a regression to the old pre-SQL hook.
    func userStopped(_ id: String) { events.append("UNEXPECTED-stop:" + id) }
    func reset() { events = []; deleted = [] }
}
@MainActor final class AgentJobRegistry {
    static let shared = AgentJobRegistry()
    var cancellations = 0
    func dropQueuedDelegations(parent: String, reason: String) { cancellations += 1 }
    func cancelAll(parent: String, reason: String) { cancellations += 1 }
    func cancelAll(session: String, reason: String) { cancellations += 1 }
    func cancelScheduled(createdBy: String, reason: String, silent: Bool) { cancellations += 1 }
}
enum BrowserTabPool { static func deletePersistedData(for id: String) {} }
@MainActor final class CloudSyncEngine {
    static let shared = CloudSyncEngine()
    func removeSessionCache(_ id: String) {}
}
@MainActor final class SessionBadgeStore {
    static let shared = SessionBadgeStore()
    func clearAll(for id: String) {}
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    func setInactive(_ id: String, source: String) {}
}
@MainActor final class AgentLiveActivityManager {
    static let shared = AgentLiveActivityManager()
    func handleSessionDeleted(_ id: String) {}
}

actor StorageLifecycleGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { released = true; waiter?.resume(); waiter = nil }
}
