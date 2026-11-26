import Foundation

// Only UI/background/Coordinator edges are fixtures. The helper, complete
// concurrency manager, limits and ownership fence all compile from production.
@MainActor final class ContinuationCoordinator {
    static let shared = ContinuationCoordinator()
    private(set) var releases: [String] = []
    var fencedSessions: Set<String> = []
    let lifecycleRegistry = ContinuationStorageBindings.registry(at:
        FileManager.default.temporaryDirectory.appendingPathComponent("slot-lifecycle-" + UUID().uuidString))
    func isQueueFenced(_ sid: String?, includingPendingLifecycle: Bool = true) -> Bool {
        sid.map { fencedSessions.contains($0) ||
            (includingPendingLifecycle && lifecycleRegistry.hasPendingSessionLifecycle(for: [$0])) } ?? false
    }
    func sessionReleased(_ sid: String) { releases.append(sid) }
}

@MainActor final class AIChatViewModel {
    let sessionId: String?
    var helperConfig: String?
    var continuationQueueFence = ContinuationQueueFence()
    var idleDrainTask: Task<Void, Never>?
    var postCompactDrainPending = false
    var isDrainingQueue = false
    var queueDrainGeneration: UUID?
    var drainRequestedWhileBusy = false
    var isSuspended = false
    var isProcessing = false {
        didSet {
            // Observable idle-rescue trigger, not a substitute queue algorithm.
            // A stale helper must not even emit the trigger for a new owner.
            if oldValue && !isProcessing && !queuedPrompts.isEmpty {
                queueRescueSignals += 1
            }
        }
    }
    var queuedPrompts = ["queued prompt survives old waiter"]
    private(set) var queueRescueSignals = 0
    private(set) var backgroundOwner: UUID?
    private(set) var backgroundEnds = 0

    init(_ sid: String, exempt: Bool = false) {
        sessionId = sid
        helperConfig = exempt ? "child" : nil
    }

    func endBackgroundProcessing() {
        backgroundEnds += 1
        backgroundOwner = nil
    }

    @discardableResult
    func beginExplicitOwner(suspended: Bool = false) -> UUID {
        precondition(reopenContinuationQueueForExplicitUserRequest())
        isProcessing = true
        isSuspended = suspended
        let owner = UUID()
        backgroundOwner = owner
        return owner
    }

    // Precisely the Stop scheduling boundary relevant to this regression:
    // invalidate synchronously, resume the REAL waiter, cancel the REAL Task.
    // This fixture does not claim to compile the complete production cancel.
    func stopWaitingTask(_ task: Task<SessionSlotLease?, Never>, cancel: Bool = true) {
        stopContinuationQueue()
        SessionConcurrencyManager.shared.cancelWait(sessionId: sessionId!)
        if cancel { task.cancel() }
        isSuspended = false
        isProcessing = false
        endBackgroundProcessing()
    }
}
