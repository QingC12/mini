import Foundation
import Darwin

@main struct ContinuationReliabilityTests {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message) }
        assertions += 1
    }
    @MainActor static func mustThrow(_ message: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { assertions += 1; return }
        throw TestFailure(message)
    }
    @MainActor static func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<5_000 {
            if try await condition() { return }
            await Task.yield()
        }
        throw TestFailure("asynchronous condition never became true")
    }
    @MainActor static func reset() throws -> ChatStore {
        UserDefaults.standard.set(true, forKey: ContinuationPolicy.settingsKey)
        UserDefaults.standard.removeObject(forKey: "nativeContinuation.stoppedSessions")
        UserDefaults.standard.removeObject(forKey: "nativeContinuation.deletedSessions")
        UserDefaults.standard.removeObject(forKey: "nativeContinuation.hardStoppedSessions")
        UserDefaults.standard.removeObject(forKey: "nativeContinuation.invalidatedBefore")
        UserDefaults.standard.removeObject(forKey: "nativeContinuation.policyInvalidatedBefore")
        AIChatViewModel.afterLoad = nil
        ContinuationWorkspace.prepareHook = nil
        ViewModelCache.shared.cache = [:]
        SessionConcurrencyManager.shared.runningSessions = []
        let store = try ChatStore()
        ChatStore.shared = store
        return store
    }
    static func draft(_ source: String, attempt: String = UUID().uuidString) -> ContinuationRecord {
        let now = Date()
        return ContinuationRecord(id: UUID().uuidString, sourceSessionID: source, attemptID: attempt,
            destinationSessionID: UUID().uuidString, sourceModelID: "model", title: "Continuation",
            checkpoint: "pending: do not publish twice", providerStatusCode: 400, providerLimit: 200,
            providerMessage: "conversation turn limit", createdAt: now, updatedAt: now, state: .pending,
            consecutiveFailures: 1, acknowledgedAt: nil, lastError: nil)
    }
    @MainActor static func prepared(_ store: ChatStore, source: String) async throws -> ContinuationRecord {
        try await store.addSession(source)
        let record = try await store.registerContinuation(draft(source))
        return try await store.createContinuationDestination(recordID: record.id)
    }

    @MainActor static func testStoreReceiptsAndClaims() async throws {
        let store = try reset()
        let record = try await prepared(store, source: "source")
        let duplicate = try await store.registerContinuation(draft("source", attempt: record.attemptID))
        try expect(duplicate.id == record.id, "same attempt was not deduplicated")
        let otherAttempt = try await store.registerContinuation(draft("source"))
        try expect(otherAttempt.id == record.id, "second active source outbox was allowed")
        let queued = UUID()
        let first = try await store.prepareContinuationSeed(recordID: record.id, checkpoint: "newest instruction", queuedPromptIDs: [queued])
        try expect(first.record.state == .seedPersisted && first.message.id == first.record.seedMessageID,
                   "seed receipt must identify the actual committed RawMessage")
        try expect(UUID(uuidString: first.message.id) != nil,
                   "seed identity must round-trip through ChatMessage's UUID loader")
        let again = try await store.prepareContinuationSeed(recordID: record.id, checkpoint: "newest instruction, revised", queuedPromptIDs: [queued])
        let rows = try await store.continuationMessages(sessionID: record.destinationSessionID)
        try expect(rows.count == 1 && rows[0].id == first.message.id, "seed refresh appended a duplicate user turn")
        try expect(again.record.seed.contains("revised"), "latest queue checkpoint was not saved")
        let claim = try await store.claimContinuationDispatch(recordID: record.id, expectedSeed: again.record.seed)
        try expect(claim.state == .submitting && claim.dispatchClaimedAt != nil, "network claim was not persisted")
        try await mustThrow("claimed dispatch was replayable") {
            _ = try await store.claimContinuationDispatch(recordID: record.id, expectedSeed: again.record.seed)
        }
        try await mustThrow("claimed seed could be rewritten") {
            _ = try await store.prepareContinuationSeed(recordID: record.id, checkpoint: "mutated", queuedPromptIDs: [])
        }
        let paused = try await store.transitionContinuation(id: record.id, to: .paused, error: "manual")
        let late = try await store.transitionContinuation(id: record.id, to: .running, acknowledge: true)
        try expect(paused?.state == .paused && late == nil, "terminal pause lost to a late response")
    }

    @MainActor static func testTransactionFailuresAndStrictReads() async throws {
        let store = try reset()
        let record = try await prepared(store, source: "rollback")
        try await store.sql("""
            CREATE TRIGGER fail_journal BEFORE UPDATE ON native_continuations
            WHEN NEW.state='seedPersisted' BEGIN SELECT RAISE(ABORT,'injected'); END;
            """)
        try await mustThrow("journal write failure returned a seed receipt") {
            _ = try await store.prepareContinuationSeed(recordID: record.id, checkpoint: "fail", queuedPromptIDs: [])
        }
        let rows = try await store.continuationMessages(sessionID: record.destinationSessionID)
        let saved = try await store.continuationRecord(id: record.id)
        try expect(rows.isEmpty && saved?.state == .destinationCreated, "failed seed journal transaction left an orphan message")
        try await store.sql("DROP TRIGGER fail_journal")
        let receipt = try await store.prepareContinuationSeed(recordID: record.id, checkpoint: "ok", queuedPromptIDs: [])
        try await store.sql("PRAGMA query_only=ON")
        try await mustThrow("read-only storage returned dispatch receipt") {
            _ = try await store.claimContinuationDispatch(recordID: record.id, expectedSeed: receipt.record.seed)
        }
        try await store.sql("PRAGMA query_only=OFF")
        try await store.sql("UPDATE messages SET parts_json='not-json'")
        try await mustThrow("corrupt transcript was mistaken for empty history") {
            _ = try await store.continuationMessages(sessionID: record.destinationSessionID)
        }
        try await mustThrow("corrupt seed authorized network dispatch") {
            _ = try await store.claimContinuationDispatch(recordID: record.id, expectedSeed: receipt.record.seed)
        }
        try await store.sql("DROP TABLE messages")
        try await mustThrow("missing messages table was mistaken for no messages") {
            _ = try await store.continuationMessages(sessionID: record.destinationSessionID)
        }
    }

    @MainActor static func testDeletionAndJSONCompatibility() async throws {
        let store = try reset()
        let first = try await prepared(store, source: "deleted")
        _ = try await store.transitionContinuation(id: first.id, to: .redirected)
        let second = try await store.registerContinuation(draft(first.destinationSessionID))
        try await store.pauseContinuationsForDeletedSession("deleted")
        let stopped = try await store.continuationRecord(id: second.id)
        try expect(stopped?.state == .paused, "deletion did not traverse redirected successor links")
        let record = draft("legacy")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "seedMessageID"); json.removeValue(forKey: "queuedPromptIDs"); json.removeValue(forKey: "dispatchClaimedAt")
        json["state"] = "submitting"
        let legacy = try JSONDecoder().decode(ContinuationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(legacy.seedMessageID == nil && legacy.requiresManualReconciliation,
                   "old submitting JSON must decode as ambiguous, never ready-to-replay")
    }

    @MainActor static func testStageReleaseAndFreshQueue() async throws {
        let store = try reset()
        try await store.addSession("source")
        let source = AIChatViewModel("source")
        source.errorMessage = "original provider error"
        source.isProcessing = true
        ViewModelCache.shared.cache["source"] = source
        SessionConcurrencyManager.shared.runningSessions.insert("source")
        let coordinator = ContinuationCoordinator()
        let failure = ConversationTurnLimitFailure(statusCode: 400, message: "turn limit", limit: 200)
        await coordinator.stage(source: source, attemptID: "attempt", failure: failure)
        let record = coordinator.status(for: "source")!
        let destinationExists = try await store.continuationSessionExists(record.destinationSessionID)
        try expect(!destinationExists, "stage created/started a destination while the source held its lease")
        try expect(source.errorMessage == "original provider error", "stage overwrote the actual provider error")
        await coordinator.restore()
        try expect(ViewModelCache.shared.get(for: record.destinationSessionID) == nil, "restore dispatched while the source slot was held")
        source.promptQueue.append(QueuedPrompt("latest: inspect the running release, never submit twice"))
        source.isProcessing = false
        SessionConcurrencyManager.shared.runningSessions.remove("source")
        coordinator.sessionReleased("source")
        try await wait { ViewModelCache.shared.get(for: record.destinationSessionID)?.starts == 1 }
        let saved = try await store.continuationRecord(id: record.id)!
        try expect(saved.seed.contains("latest: inspect"), "dispatch ignored a user prompt queued after stage")
        try expect(source.promptQueue.isEmpty, "accepted durable handoff was not removed from source queue")
        try expect(saved.acknowledgedAt == nil && saved.consecutiveFailures == 1, "submission was mistaken for model success")
        await coordinator.providerResponded(in: record.destinationSessionID)
        let acknowledged = try await store.continuationRecord(id: record.id)!
        try expect(acknowledged.acknowledgedAt != nil && acknowledged.consecutiveFailures == 0, "real provider response did not reset the failure chain")
        _ = try await store.transitionContinuation(id: record.id, to: .finished)
        await coordinator.restore()
        try expect(coordinator.hasPendingHandoff(for: "source"), "finished handoff released late old-source queue items for a duplicate run")
        coordinator.userBeganRequest("source")
        try expect(!coordinator.hasPendingHandoff(for: "source"), "explicit source takeover did not release its old queue freeze")
    }

    @MainActor static func testStopTakeoverAndBusyAfterAwait() async throws {
        for mode in ["stop", "source-takeover", "destination-takeover", "busy"] {
            let store = try reset()
            let record = try await prepared(store, source: "race-\(mode)")
            let coordinator = ContinuationCoordinator()
            AIChatViewModel.afterLoad = { vm in
                switch mode {
                case "stop": coordinator.userStopped(record.sourceSessionID)
                case "source-takeover": coordinator.userBeganRequest(record.sourceSessionID)
                case "destination-takeover": coordinator.userBeganRequest(record.destinationSessionID)
                default: vm.isProcessing = true
                }
            }
            await coordinator.restore()
            try await wait { try await store.continuationRecord(id: record.id)?.state == .paused }
            try expect(ViewModelCache.shared.get(for: record.destinationSessionID)?.starts == 0,
                       "\(mode) during loadSession await still automatically submitted")
            let saved = try await store.continuationRecord(id: record.id)!
            try expect(saved.dispatchClaimedAt == nil, "\(mode) consumed a dispatch claim despite failing the pre-claim gate")
        }
    }

    @MainActor static func testPolicyAndDeletedSource() async throws {
        for mode in ["disabled", "deleted"] {
            let store = try reset()
            let record = try await prepared(store, source: "prep-\(mode)")
            let source = AIChatViewModel(record.sourceSessionID)
            ViewModelCache.shared.cache[record.sourceSessionID] = source
            let coordinator = ContinuationCoordinator()
            ContinuationWorkspace.prepareHook = {
                if mode == "disabled" {
                    UserDefaults.standard.set(false, forKey: ContinuationPolicy.settingsKey)
                    coordinator.policyChanged()
                } else {
                    try await store.sql("DELETE FROM sessions WHERE id='\(record.sourceSessionID)'")
                }
            }
            await coordinator.restore()
            try await wait { try await store.continuationRecord(id: record.id)?.state == .paused }
            try expect(ViewModelCache.shared.get(for: record.destinationSessionID)?.starts ?? 0 == 0,
                       "\(mode) during preparation still started network work")
            if mode == "disabled" {
                try expect(!coordinator.hasPendingHandoff(for: record.sourceSessionID), "disabled policy froze the original queue")
                try await wait { source.drains > 0 }
            }
        }
    }

    @MainActor static func testCrashRecoveryAndMissingSourceVM() async throws {
        let store = try reset()
        let pending = try await prepared(store, source: "snapshot")
        let queueID = UUID()
        let receipt = try await store.prepareContinuationSeed(recordID: pending.id,
            checkpoint: "PENDING SNAPSHOT: do not lose this requirement", queuedPromptIDs: [queueID])
        let coordinator = ContinuationCoordinator()
        let fresh = QueuedPrompt("LATEST AFTER RESTORE: also inspect the running CI job")
        AIChatViewModel.afterLoad = { _ in
            AIChatViewModel.afterLoad = nil
            let rebuiltSource = AIChatViewModel(pending.sourceSessionID)
            rebuiltSource.promptQueue = [fresh]
            ViewModelCache.shared.cache[pending.sourceSessionID] = rebuiltSource
        }
        await coordinator.restore()
        try await wait { ViewModelCache.shared.get(for: pending.destinationSessionID)?.starts == 1 }
        let resumed = try await store.continuationRecord(id: pending.id)!
        try expect(resumed.seed.contains("PENDING SNAPSHOT") && resumed.seed.contains("LATEST AFTER RESTORE") &&
                   resumed.queuedPromptIDs == [queueID, fresh.id],
                   "restart/rebuilt source VM erased old or newly queued requirements")
        try expect(ViewModelCache.shared.get(for: pending.sourceSessionID)?.promptQueue.isEmpty == true,
                   "accepted fresh queue identity was not cleared after restoring old requirements")
        try expect(resumed.seedMessageID == receipt.message.id, "restart inserted a second seed instead of loading the receipt")
        let before = ViewModelCache.shared.get(for: pending.destinationSessionID)!.starts
        ViewModelCache.shared.get(for: pending.destinationSessionID)!.isProcessing = false
        let restarted = ContinuationCoordinator()
        await restarted.restore()
        try await wait { try await store.continuationRecord(id: pending.id)?.state == .paused }
        try expect(ViewModelCache.shared.get(for: pending.destinationSessionID)!.starts == before,
                   "crashed claimed run was automatically replayed from unanswered-user tail")
        let rows = try await store.continuationMessages(sessionID: pending.destinationSessionID)
        try expect(rows.count == 1, "ambiguous crash produced another seed")
    }

    @MainActor static func testAttachmentsAndFailureCap() async throws {
        let store = try reset()
        try await store.addSession("attachment")
        let source = AIChatViewModel("attachment")
        source.promptQueue = [QueuedPrompt("check this file", attachments: ["untransferred-file"])]
        ViewModelCache.shared.cache["attachment"] = source
        let coordinator = ContinuationCoordinator()
        let failure = ConversationTurnLimitFailure(statusCode: 400, message: "limit", limit: 200)
        await coordinator.stage(source: source, attemptID: "attachments", failure: failure)
        try expect(coordinator.status(for: "attachment")?.state == .paused && source.promptQueue.count == 1,
                   "attachment queue was silently converted to text or consumed")
        try expect(coordinator.hasPendingHandoff(for: "attachment"), "manual attachment handoff did not freeze source autodrain")
        try await store.addSession("ancestor")
        var parent = draft("ancestor")
        parent.consecutiveFailures = 2
        _ = try await store.registerContinuation(parent)
        _ = try await store.createContinuationDestination(recordID: parent.id)
        let successor = AIChatViewModel(parent.destinationSessionID)
        ViewModelCache.shared.cache[parent.destinationSessionID] = successor
        await coordinator.stage(source: successor, attemptID: "third-failure", failure: failure)
        let capped = coordinator.status(for: parent.destinationSessionID)!
        try expect(capped.state == .failed && capped.consecutiveFailures == 3, "third consecutive failure did not stop the chain")
    }

    @MainActor static func main() async {
        let keys = [ContinuationPolicy.settingsKey, "nativeContinuation.stoppedSessions", "nativeContinuation.deletedSessions", "nativeContinuation.hardStoppedSessions", "nativeContinuation.invalidatedBefore",
                    "nativeContinuation.policyInvalidatedBefore"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        do {
            try await testStoreReceiptsAndClaims()
            try await testTransactionFailuresAndStrictReads()
            try await testDeletionAndJSONCompatibility()
            try await testStageReleaseAndFreshQueue()
            try await testStopTakeoverAndBusyAfterAwait()
            try await testPolicyAndDeletedSource()
            try await testCrashRecoveryAndMissingSourceVM()
            try await testAttachmentsAndFailureCap()
            print("PASS: \(assertions) assertions against real Store/Record/Coordinator implementations")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
