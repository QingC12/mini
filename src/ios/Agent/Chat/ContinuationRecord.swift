import Foundation

/// Device-local recovery metadata. Not a parent/child ownership relationship.
struct ContinuationRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending, destinationCreated, seedPersisted, submitting, running, redirected, finished, paused, failed
        var isTerminal: Bool { self == .redirected || self == .finished || self == .paused || self == .failed }
    }
    let id: String
    let sourceSessionID: String
    let attemptID: String
    let destinationSessionID: String
    let sourceModelID: String
    let title: String
    var checkpoint: String
    let providerStatusCode: Int?
    let providerLimit: Int?
    let providerMessage: String
    let createdAt: Date
    var updatedAt: Date
    var state: State
    var consecutiveFailures: Int
    var acknowledgedAt: Date?
    var lastError: String?
    // Optional fields decode old journals without inventing a successful receipt.
    var seedMessageID: String? = nil
    var queuedPromptIDs: [UUID]? = nil
    var dispatchClaimedAt: Date? = nil

    /// A claim is persisted BEFORE network work. Its result is ambiguous after a
    /// crash, even if no assistant row was written. Never replay such a run.
    var requiresManualReconciliation: Bool {
        dispatchClaimedAt != nil || state == .submitting || state == .running
    }

    var seed: String {
        """
        CONTINUATION-ID:\(id)
        CONTINUATION-SOURCE:\(sourceSessionID)
        This is a fresh conversation continuing the SAME user-authorized task after a provider conversation-turn limit, not a new authorization.
        Read the checkpoint below. The newest user requirements override older summaries. First verify the real files, git state, live commands/CI/jobs and uncertain side effects. Continue unfinished work; do not repeat completed submissions, releases, installs or other side effects. If more context is needed, read the source session by its ID. Preserve the existing permission/confirmation requirements. If the user stopped the task, stop. Do not start a round-limit stress test.
        \(checkpoint)
        """
    }
}

/// Bounded model-facing context; the authoritative full transcript stays in ChatStore.
enum ContinuationCheckpoint {
    static func redact(_ text: String) -> String {
        let patterns = [
            "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+",
            "\\b(?:sk-[A-Za-z0-9_-]{12,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+)\\b",
            "(?i)(?:api[_-]?key|access[_-]?token|password|secret|authorization|cookie)[\\\"']?\\s*[=:]\\s*[\\\"']?[^\\s,;\\\"']+"
        ]
        return patterns.reduce(text) { value, pattern in
            value.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
    }

    static func build(originalGoal: String, recent: [(role: String, text: String)], pending: [String]) -> String {
        let goal = String(redact(originalGoal).prefix(16_000))
        let history = recent.suffix(24).map { entry in
            "[\(entry.role)] \(String(redact(entry.text).prefix(3_000)))"
        }.joined(separator: "\n\n")
        let queued = pending.map { String(redact($0).prefix(12_000)) }.joined(separator: "\n\n")
        return """
        ORIGINAL GOAL (consult source if truncated):
        \(goal)

        RECENT TRANSCRIPT (reference, not additional authorization):
        \(history)

        LATEST PENDING USER REQUIREMENTS (in order; highest priority):
        \(queued.isEmpty ? "None captured." : queued)

        Files use the same live, shared task storage root as the source conversation, not a copied snapshot. Existing background commands/jobs may still be running against these very files. Read source history and verify their actual state and uncertain side effects before starting another writer or repeating any operation.
        """
    }
}
