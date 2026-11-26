import Foundation
import SQLite3

// Only unavailable UI surroundings. SQL lifecycle function bodies, Coordinator,
// queue/cancel, registry, journal and VM fence are the production implementations.
struct ChatSession {
    let id: String
    var title: String? = nil
    var category: String? = nil
    var modelId = "model"
    var createdAt = Date(timeIntervalSince1970: 1)
    var updatedAt = Date(timeIntervalSince1970: 2)
    var pinnedAt: Date? = nil
    var folderId: String? = nil
    var parentSessionId: String? = nil
    var parentToolUseId: String? = nil
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
extension AgentJobRegistry {
    func cancelAll(parent: String, reason: String) { stops.append(parent) }
    func cancelAll(session: String, reason: String) { stops.append(session) }
    func cancelScheduled(createdBy: String, reason: String, silent: Bool) { stops.append(createdBy) }
}

actor LifecycleApplyGate {
    private var released = false
    private var didEnter = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        didEnter = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func entered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func open() { released = true; waiter?.resume(); waiter = nil }
}

final class LifecycleSQLBarrier: @unchecked Sendable {
    let reachedSQL = DispatchSemaphore(value: 0)
    let continueSQL = DispatchSemaphore(value: 0)
}
extension ChatStore {
    func deleteMessages(sessionId: String) { try? sql("DELETE FROM messages WHERE session_id='\(sessionId)'") }
    func deleteCompactMarkers(sessionId: String) { try? sql("DELETE FROM compact_markers WHERE session_id='\(sessionId)'") }
    func lifecycleRestore(_ id: String) -> RestoreOutcome {
        restoreSession(ChatSession(id: id), memoryEnabled: true, modelBinding: nil)
    }
    // Pauses a REAL SQLite DELETE before commit, not a fake enqueue API.
    func installLifecycleDeleteBarrier(_ barrier: LifecycleSQLBarrier) throws {
        let context = Unmanaged.passRetained(barrier).toOpaque()
        let result = sqlite3_create_function_v2(db, "hold_lifecycle", 0, SQLITE_UTF8, context, { context, _, _ in
            guard let context, let pointer = sqlite3_user_data(context) else { return }
            let barrier = Unmanaged<LifecycleSQLBarrier>.fromOpaque(pointer).takeUnretainedValue()
            barrier.reachedSQL.signal()
            if barrier.continueSQL.wait(timeout: .now() + 10) == .success {
                sqlite3_result_int(context, 1)
            } else {
                sqlite3_result_error(context, "SQL lifecycle barrier timed out", -1)
            }
        }, nil, nil, { pointer in
            if let pointer { Unmanaged<LifecycleSQLBarrier>.fromOpaque(pointer).release() }
        })
        guard result == SQLITE_OK else { throw TestFailure("install lifecycle SQL barrier") }
        try sql("CREATE TRIGGER lifecycle_hold BEFORE DELETE ON sessions BEGIN SELECT hold_lifecycle(); END")
    }
}
