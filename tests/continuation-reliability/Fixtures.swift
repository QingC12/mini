// Standalone doubles for the surroundings ONLY. The implementation under test
// is the unmodified ContinuationCoordinator/ChatStore+Continuation/Record files.
// macOS: sh tests/run_continuation_reliability_tests.sh
import Foundation
import SQLite3

enum MessageRole: String, Codable { case user, assistant }
struct StoredTokenUsage: Codable, Hashable { var inputTokens = 0 }
struct TestTool: Codable, Hashable { let name: String; let toolUseId: String }
struct TestResult: Codable, Hashable { let toolUseId: String; let success: Bool; var status: String? }
struct TestMedia: Codable, Hashable { let id: String; var originalFileName: String? }
enum ContentPart: Codable, Hashable {
    case text(String), toolUse(TestTool), toolResult(TestResult), mediaRef(TestMedia)
}
struct RawMessage: Identifiable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let parts: [ContentPart]
    let createdAt: Date
    var tokenUsage: StoredTokenUsage?
    var reasoningContent: String?
    var streamInterruptCount = 0
    var sortOrder = 0
    var errorInfo: String?
    var modelId: String?
    var modelDisplayName: String?
    var providerType: String?
    var providerInstanceId: String?
    var reasoningEchoJSON: String?
}

actor ChatStore {
    static var shared = try! ChatStore()
    var db: OpaquePointer?
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("continuation-\(UUID().uuidString).sqlite")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw TestFailure("open") }
        let sql = """
            PRAGMA foreign_keys=ON;
            CREATE TABLE sessions(id TEXT PRIMARY KEY,title TEXT,model_id TEXT NOT NULL,
              created_at REAL NOT NULL,updated_at REAL NOT NULL,source TEXT,memory_enabled INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE messages(id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),
              role TEXT NOT NULL,parts_json TEXT NOT NULL,created_at REAL NOT NULL,token_usage TEXT,
              reasoning_content TEXT,stream_interrupt_count INTEGER DEFAULT 0,sort_order INTEGER NOT NULL,
              error_info TEXT,model_id TEXT,model_display_name TEXT,provider_type TEXT,provider_instance_id TEXT,
              reasoning_echo TEXT,updated_at REAL,part_flags INTEGER);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure("schema") }
    }
    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: url)
    }
    func sql(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure("fixture SQL failed: \(sql)") }
    }
    func addSession(_ id: String) throws {
        try sql("INSERT INTO sessions(id,title,model_id,created_at,updated_at) VALUES('\(id)','Task','model',0,0)")
    }
    func invalidateSessionListCache() {}
    func invalidateSessionListCache(sessionId: String) {}
    func markDirty(recordType: String, recordId: String) {}
    static func partFlags(for parts: [ContentPart]) -> Int { 1 }
}

struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct QueuedPrompt {
    let id: UUID
    let text: String
    var attachments: [String] = []
    var pastePlan: [Int: String] = [:]
    init(_ text: String, attachments: [String] = []) {
        id = UUID(); self.text = text; self.attachments = attachments
    }
}
struct TestUIMessage {
    let id: UUID
    let role: MessageRole
    var error: String? = nil
}
struct TestAgentEntry { let role: MessageRole; let parts: [ContentPart] }
struct TestEntry { struct Model { let id: String }; let model = Model(id: "model") }
enum ProgrammaticPromptOrigin { case continuation(recoveryID: String) }

@MainActor final class AIChatViewModel {
    var sessionId: String?
    var helperConfig: String?
    var remoteDeviceId: String?
    var turnWasStopped = false
    var promptQueue: [QueuedPrompt] = []
    var messages: [TestUIMessage] = []
    var agentHistory: [TestAgentEntry] = []
    var errorMessage: String?
    var canResume = false
    var isProcessing = false
    var isCompacting = false
    var isLoadingSession = false
    var isDrainingQueue = false
    var postCompactDrainPending = false
    var sessionSource = ""
    var programmaticTurnOrigin: ProgrammaticPromptOrigin?
    var programmaticSilentTurn = false
    var starts = 0
    var drains = 0
    static var afterLoad: ((AIChatViewModel) async -> Void)?
    init(_ sid: String) { sessionId = sid }
    func resolveCurrentEntry() -> TestEntry? { TestEntry() }
    func loadSession() async {
        let rows = (try? await ChatStore.shared.continuationMessages(sessionID: sessionId!)) ?? []
        // Match production loadSession: invalid persisted UUIDs get a new UI
        // identity and MUST fail Coordinator's stable seed-identity gate.
        messages = rows.map { TestUIMessage(id: UUID(uuidString: $0.id) ?? UUID(), role: $0.role) }
        agentHistory = rows.map { TestAgentEntry(role: $0.role, parts: $0.parts) }
        await Self.afterLoad?(self)
    }
    func resumeUnansweredUserTurn(forContinuation: Bool) {
        precondition(forContinuation)
        guard !isProcessing, !isCompacting, remoteDeviceId == nil else { return }
        starts += 1; isProcessing = true
    }
    func acceptContinuationHandoff(promptIDs: Set<UUID>) {
        promptQueue.removeAll { promptIDs.contains($0.id) }
    }
    func cancel() { turnWasStopped = true; isProcessing = false }
    func startDrainIfIdle(reason: String) { drains += 1 }
}

@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var cache: [String: AIChatViewModel] = [:]
    func get(for id: String) -> AIChatViewModel? { cache[id] }
    func getOrCreate(for id: String) -> (AIChatViewModel, Bool) {
        if let vm = cache[id] { return (vm, false) }
        let vm = AIChatViewModel(id); cache[id] = vm; return (vm, true)
    }
}
@MainActor final class SessionConcurrencyManager {
    static let shared = SessionConcurrencyManager()
    var runningSessions: Set<String> = []
}
@MainActor enum ContinuationWorkspace {
    static var prepareHook: (() async throws -> Void)?
    static func prepare(sourceSessionID: String, destinationSessionID: String) async throws -> Bool {
        try await prepareHook?(); return true
    }
}
@MainActor enum ContinuationSettings {
    static func copy(from: String, to: String) async throws {}
}
