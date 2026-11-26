// Only app/OS/provider surroundings are adapters. Cancel + ALL PromptQueue
// method bodies are extracted verbatim from production by extract_methods.py.
import Foundation

struct AppLogger {
    init(category: String) {}
    func info(_ value: String) {}
    func warning(_ value: String) {}
    func error(_ value: String) {}
}
let logger = AppLogger(category: "stop-tests")
struct TokenUsage {}
struct AttachmentMeta { var path = "" }
struct PasteEntry { let id: Int; let text: String }
typealias InputAttachment = String
typealias MarkdownContent = String
func prepareMarkdownForRender(_ text: String) -> String { text }
struct AgentMessage {
    let role: MessageRole
    var parts: [AgentContentPart]
    var dbMessageId: String? = nil
    var anchorId = UUID().uuidString
}
final class TestBlock {
    let id = UUID()
    var toolUseId: String?
    enum Status { case streaming, running, cancelled, completed }
    var toolStatus: Status = .completed
    enum Kind { case text, tool }
    var kind: Kind = .text
    var content = ""
    var cachedMarkdown: String?
}
final class ChatMessage {
    let id: UUID
    let role: MessageRole
    var error: String?
    var blocks: [TestBlock]
    var queuedPromptId: UUID?
    var isQueued = false
    var awaitingHistoryEntry = false
    var streamInterruptCount = 0
    var attachments: [AttachmentMeta] = []
    var inputAttachments: [String] = []
    var historyAnchorId: String?
    var isAwaitingModelResponse = false
    var usage: TokenUsage?
    var completedAt: Date?
    init(id: UUID = UUID(), role: MessageRole, content: String = "", blocks: [TestBlock] = []) {
        self.id = id; self.role = role; self.blocks = blocks
    }
}
struct TestEntry { struct Model { let id = "model" }; let model = Model() }
enum ProgrammaticPromptOrigin { case continuation(recoveryID: String) }
enum QueueDeliveryPoint { case turnEnd }
struct QueueTake: Equatable {
    let deliver: [UUID]
    let coalesced: [UUID]
    let scheduledJobId: String?
}
struct LoopDetector { func exemptNextCallForScheduledFire() {} }
extension RawMessage { static let queuedInterruptReminderText = "reminder" }
extension Notification.Name { static let minisUserAttachmentsMounted = Notification.Name("test-mounted") }
@MainActor final class AgentJobRegistry {
    static let shared = AgentJobRegistry()
    var stops: [String] = []
    func dropQueuedDelegations(parent: String, reason: String) { stops.append(parent) }
    func cancelAll(parent: String, reason: String, silent: Bool) {}
    func cancelScheduled(createdBy: String, reason: String) {}
}
@MainActor final class CacheKeepAliveManager {
    static let shared = CacheKeepAliveManager()
    func cancelKeepAlive(sessionId: String) {}
}
extension ChatStore {
    func loadMessages(sessionId: String) -> [RawMessage] { [] }
}

@MainActor final class AIChatViewModel {
    var sessionId: String?
    var vmInstanceId = UUID().uuidString
    var turnStartedByRetry = false
    var isTruncatingForRetry = false
    var transitionSuspended = false
    var cachedLatestMarker: Int?
    var toolSnapshots: [ToolSnapshotItem] = []
    var forceScrollToBottom = Signal()
    var retrySnapshotReloadSignal = Signal()
    var objectWillChange = Signal()
    var kernelStatus = KernelStatus.booted
    var slotHook: (() async -> Void)?
    var loopHook: (() async throws -> Void)?
    var historyCuts = 0
    var resumeTargets: [Int?] = []
    var helperConfig: String?
    var remoteDeviceId: String?
    var isHelper: Bool { helperConfig != nil }
    var continuationQueueFence = ContinuationQueueFence()
    var currentTask: Task<Void, Never>?
    var idleDrainTask: Task<Void, Never>?
    var compactTask: Task<Void, Never>?
    var takeoverTimeoutTask: Task<Void, Never>?
    var foregroundContinuation: CheckedContinuation<Void, Never>?
    var takeoverContinuation: CheckedContinuation<Void, Never>?
    var midActionTakeoverContinuation: CheckedContinuation<Void, Never>?
    var foregroundObserver: NSObjectProtocol?
    var promptQueue: [QueuedPrompt] = []
    var messages: [ChatMessage] = []
    var agentHistory: [AgentMessage] = []
    var pastedTexts: [PasteEntry] = []
    var silentQueuedPromptIds: Set<UUID> = []
    var errorMessage: String?
    var canResume = false
    var userDidCancel = false
    var turnWasStopped: Bool { userDidCancel || Task.isCancelled || !continuationQueueMayRun }
    var isProcessing = false {
        didSet {
            if oldValue && !isProcessing && !promptQueue.isEmpty && !userDidCancel {
                startDrainIfIdle(reason: "fixture-isProcessing-didSet")
            }
        }
    }
    var isCompacting = false
    var isLoadingSession = false
    var isDrainingQueue = false
    var queueDrainGeneration: UUID?
    var postCompactDrainPending = false
    var drainRequestedWhileBusy = false
    var isSuspended = false
    var backgroundSuspended = false
    var browserTakeoverActive = false
    var delegationResultsMuted = false
    var sessionSource = ""
    var programmaticTurnOrigin: ProgrammaticPromptOrigin?
    var programmaticSilentTurn = false
    var autoRetryAttempt = 0
    var autoRetryCountdown = 0
    var inputText = "draft"
    var attachments: [String] = []
    enum CompactOrigin { case beforeSend, slashCommand }
    var compactOrigin: CompactOrigin?
    var lastKnownDbSortOrder = 0
    var lastKnownDbCount = 0
    var lastKnownDbOrderHash = 0
    var committedBlockCount = 0
    var prevCommittedBlockCount = 0
    var scrollToBottomSignal = Signal()
    struct Signal { func send() {} }
    var toolLoopDetector = LoopDetector()
    var starts = 0
    var toolStarts = 0
    var cleanupAttachmentCount = 0
    var cancelCleanupCount = 0
    var pastedHook: (() async -> Void)?
    var persistHook: (() async -> Void)?
    static var afterLoad: ((AIChatViewModel) async -> Void)?
    init(_ sid: String) { sessionId = sid }
    func resolveCurrentEntry() -> TestEntry? { TestEntry() }
    func loadSession() async {
        let rows = (try? await ChatStore.shared.continuationMessages(sessionID: sessionId!)) ?? []
        messages = rows.map { ChatMessage(id: UUID(uuidString: $0.id) ?? UUID(), role: $0.role) }
        agentHistory = rows.map { row in AgentMessage(role: row.role, parts: row.parts.compactMap {
            if case .text(let text) = $0 { return .text(text) }; return nil
        }) }
        await Self.afterLoad?(self)
    }
    func resumeUnansweredUserTurn(forContinuation: Bool) {
        guard continuationQueueMayRun, !isProcessing else { return }
        starts += 1; toolStarts += 1; isProcessing = true
    }
    func runAgentLoop(resumingAt: Int? = nil, committedBlocks: Int? = nil) async throws {
        starts += 1; toolStarts += 1; resumeTargets.append(resumingAt)
        try await loopHook?()
    }
    func ensureKernelBooted() {}
    func acquireSessionSlot(_ sid: String) async -> TestSlotLease? {
        await slotHook?(); return TestSlotLease()
    }
    @discardableResult
    func cutAtUserBubble(_ idx: Int, keepBubble: Bool, site: String) -> (keptEntry: Int?, unused: Bool) {
        historyCuts += 1
        let end = keepBubble ? idx + 1 : idx
        if end < messages.count { messages.removeSubrange(end...) }
        if end < agentHistory.count { agentHistory.removeSubrange(end...) }
        return (keepBubble ? idx : idx - 1, false)
    }
    func dumpHistoryPairing(_ site: String) {}
    func buildRawMessage(_ entry: AgentMessage) async -> RawMessage? { nil }

    func planQueueTake(at point: QueueDeliveryPoint) -> QueueTake? {
        guard !promptQueue.isEmpty else { return nil }
        return QueueTake(deliver: promptQueue.map(\.id), coalesced: [], scheduledJobId: nil)
    }
    func removeQueueTake(_ take: QueueTake) -> [QueuedPrompt] {
        let queued = promptQueue.filter { take.deliver.contains($0.id) }
        promptQueue.removeAll { take.deliver.contains($0.id) || take.coalesced.contains($0.id) }
        return queued
    }
    func scheduledReminder(for take: QueueTake, delivered: [QueuedPrompt], at point: QueueDeliveryPoint) -> String? { nil }
    static func minisUploadsDir(for sid: String) -> URL { FileManager.default.temporaryDirectory }
    func processAttachments(_ attachments: [String], uploadsDir: URL, nowStr: String) -> ([AgentContentPart], [AttachmentMeta]) {
        return (attachments.map { .text($0) }, attachments.map { AttachmentMeta(path: $0) })
    }
    static func cleanupAttachmentFiles(_ attachments: [String]) {
        // A real temporary file oracle: a wrongly consumed queued attachment
        // is observably deleted, not just a fake cancel boolean.
        for path in attachments { try? FileManager.default.removeItem(atPath: path) }
    }
    func consumePastedDraft(_ text: String, sessionId: String, plannedFileIds: [Int: String]) async
      -> (modelText: String, storedParts: [ContentPart], liveCardMetas: [AttachmentMeta])? {
        // Like the production API, capture the entry before storage awaits,
        // then remove its buffer only when that asynchronous call returns.
        let matched = pastedTexts.filter { text.contains("[Pasted#\($0.id)]") }
        await pastedHook?()
        guard !matched.isEmpty else { return nil }
        pastedTexts.removeAll { entry in matched.contains(where: { $0.id == entry.id }) }
        return (matched.map(\.text).joined(), matched.map { .text($0.text) }, [])
    }
    func persistAgentMessage(_ message: AgentMessage, snapshots: [String: String] = [:], pastedParts: [String: [ContentPart]] = [:]) async -> String? {
        await persistHook?(); return UUID().uuidString
    }
    func persistErrorInfo(_ text: String) async {}
    static func computeOrderHash(of messages: [RawMessage]) -> Int { messages.count }
    static func friendlyErrorMessage(_ text: String) -> String { text }
    func cacheAttributedString(for block: TestBlock) {}
    func publishContextUsage() {}
    func reportTurnFailure(_ text: String) { errorMessage = text }
    func dumpCandidateState(_ tag: String) {}
    func dumpQueueSnapshot(_ tag: String) {}
    func stopCurrentCommand() {}
    func cancelPendingUserAsk() {}
    func dropPresetsOfStoppedTurn() {}
    func handleUserCancelledCleanup() { cancelCleanupCount += 1 }
    func settlePendingStop(before: String) {}
    func finishStoppedTurn() { cancelCleanupCount += 1; userDidCancel = false; canResume = true }
    func beginBackgroundProcessing() {}
    func endBackgroundProcessing() {}
    func playCompletionHaptic() {}
}

struct ToolSnapshotItem { let id: String }
enum KernelStatus: Equatable { case booted, booting, failed(String) }
enum LLMError: LocalizedError {
    case test
    var errorDescription: String? { "test failure" }
}
struct TestSlotLease {}
extension SessionConcurrencyManager {
    func release(_ lease: TestSlotLease) {}
}
@MainActor enum RerunIO {
    static var deletes = 0
    static var updates = 0
    static var deleteHook: (() async -> Void)?
    static func delete() async { deletes += 1; await deleteHook?() }
}
extension ChatStore {
    func deleteMessagesAfter(sessionId: String, keepCount: Int) async { await RerunIO.delete() }
    func updateMessageParts(messageId: String, parts: [ContentPart]) async { await MainActor.run { RerunIO.updates += 1 } }
}
