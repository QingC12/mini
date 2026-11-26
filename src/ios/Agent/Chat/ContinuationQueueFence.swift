import Foundation

/// MainActor-owned queue ownership, independent of a turn's resettable cancel
/// flag. A queued rescue captures a generation; even stop -> explicit reopen
/// cannot give an already-scheduled old rescue ownership of the new request.
struct ContinuationQueueFence {
    private(set) var generation = UUID()
    private(set) var isStopped = false
    private(set) var isDeleted = false

    mutating func invalidatePendingWork() { generation = UUID() }

    mutating func stop(deleted: Bool = false) {
        generation = UUID()
        isStopped = true
        isDeleted = isDeleted || deleted
    }

    @discardableResult
    mutating func reopenForExplicitUserRequest() -> Bool {
        guard !isDeleted else { return false }
        generation = UUID()
        isStopped = false
        return true
    }

    func permits(_ capturedGeneration: UUID) -> Bool {
        !isStopped && !isDeleted && generation == capturedGeneration
    }
}

extension AIChatViewModel {
    /// Never clears a fence. Use at EVERY asynchronous queue dispatch boundary.
    var continuationQueueMayRun: Bool {
        !continuationQueueFence.isStopped && !continuationQueueFence.isDeleted &&
            !ContinuationCoordinator.shared.isQueueFenced(sessionId)
    }

    func continuationQueueMayRun(generation: UUID) -> Bool {
        continuationQueueMayRun && continuationQueueFence.permits(generation) && !Task.isCancelled
    }

    /// Called only by the coordinator after this endpoint's explicit request.
    /// Job callbacks, queue rescues and forContinuation resumes cannot use it.
    @discardableResult
    func reopenContinuationQueueForExplicitUserRequest() -> Bool {
        guard !continuationQueueFence.isDeleted,
              !ContinuationCoordinator.shared.isQueueFenced(sessionId) else { return false }
        idleDrainTask?.cancel()
        idleDrainTask = nil
        postCompactDrainPending = false
        isDrainingQueue = false
        queueDrainGeneration = nil
        drainRequestedWhileBusy = false
        return continuationQueueFence.reopenForExplicitUserRequest()
    }

    /// Deletion is permanent for this VM. Preserves queued prompts/attachments.
    func stopContinuationQueue(deleted: Bool = false) {
        continuationQueueFence.stop(deleted: deleted)
        idleDrainTask?.cancel()
        idleDrainTask = nil
        postCompactDrainPending = false
        isDrainingQueue = false
        queueDrainGeneration = nil
        drainRequestedWhileBusy = false
    }
}
