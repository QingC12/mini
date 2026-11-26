import Foundation

@main struct ContinuationStopTests {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw TestFailure(message) }
    }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }
    @MainActor static func vm(_ sid: String) -> AIChatViewModel {
        ViewModelCache.shared.getOrCreate(for: sid).0
    }
    @MainActor static func attachment() throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stop-attachment-" + UUID().uuidString)
        try Data("preserve queued attachment".utf8).write(to: file)
        return file.path
    }
    @MainActor static func link(_ source: String, _ destination: String) async throws {
        let store = ChatStore.shared
        try await store.addSession(source)
        let now = Date()
        let record = ContinuationRecord(id: UUID().uuidString, sourceSessionID: source,
            attemptID: UUID().uuidString, destinationSessionID: destination, sourceModelID: "model",
            title: "Same physical task root", checkpoint: "Continue existing task", providerStatusCode: 400,
            providerLimit: 200, providerMessage: "conversation turn limit", createdAt: now, updatedAt: now,
            state: .pending, consecutiveFailures: 1, acknowledgedAt: nil, lastError: nil)
        _ = try await store.registerContinuation(record)
        _ = try await store.createContinuationDestination(recordID: record.id)
        // Keep live source busy: restore may hydrate the journal, never dispatch.
        vm(source).isProcessing = true
        await ContinuationCoordinator.shared.restore()
    }
    @MainActor static func testTakeover() async throws {
        let a = "takeover-A", b = "takeover-B"
        try await link(a, b)
        let source = vm(a), target = vm(b)
        let file = try attachment()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let q = QueuedPrompt("B queued requirement", attachments: [file])
        target.promptQueue = [q]
        target.isProcessing = true
        // A real, already-created 200ms rescue must also lose ownership.
        target.resumeQueueAfterCancel()
        // Let the exact production task enter its settle sleep before takeover.
        try await Task.sleep(nanoseconds: 20_000_000)
        let stale = target.continuationQueueFence.generation
        try expect(ContinuationCoordinator.shared.userBeganRequest(a), "A explicit request was rejected")
        source.userDidCancel = false
        source.isProcessing = true
        try await source.runAgentLoop()
        try await settle()
        try expect(source.starts == 1 && target.starts == 0 && target.toolStarts == 0,
                   "A takeover allowed B queue to restart after 200ms")
        try expect(target.promptQueue.map(\.id) == [q.id], "hard takeover consumed B queue")
        try expect(FileManager.default.fileExists(atPath: file), "hard takeover deleted B queued attachment")
        try expect(!target.continuationQueueMayRun(generation: stale), "old B generation retained ownership")
        try expect(AgentJobRegistry.shared.stops.contains(b), "linked B child jobs were not cancelled")
        // Explicitly reopen B, but the already captured rescue token stays stale.
        try expect(ContinuationCoordinator.shared.userBeganRequest(b), "B explicit endpoint could not reopen")
        try expect(target.continuationQueueMayRun && !target.continuationQueueMayRun(generation: stale),
                   "stop->reopen revived a previous generation")
        try await settle()
        try expect(target.starts == 0, "old rescue revived after explicit reopen")
    }
    @MainActor static func testIndependentStop() async throws {
        let ordinary = vm("ordinary-no-continuation")
        let file = try attachment()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let q = QueuedPrompt("ordinary queue must continue", attachments: [file])
        ordinary.promptQueue = [q]
        ordinary.isProcessing = true
        ordinary.cancel() // EXACT real production method, not a fake boolean.
        try await settle()
        try expect(ordinary.starts == 1 && ordinary.toolStarts == 1, "ordinary Stop lost upstream automatic queue semantics")
        try expect(ordinary.promptQueue.isEmpty, "ordinary Stop left an accepted queued prompt stuck")
        try expect(!FileManager.default.fileExists(atPath: file), "ordinary drain did not exercise real attachment cleanup oracle")
        try expect(!ordinary.continuationQueueFence.isStopped, "generic userDidCancel became a hard fence")
    }
    @MainActor static func testBidirectionalStop() async throws {
        try await link("chain-A", "chain-B")
        // link() needs an existing source for A->B->C, so build the second edge
        // using the actual stage method on B's existing destination row.
        let b = vm("chain-B")
        b.isProcessing = true
        let failure = ConversationTurnLimitFailure(statusCode: 400, message: "conversation turn limit", limit: 200)
        await ContinuationCoordinator.shared.stage(source: b, attemptID: UUID().uuidString, failure: failure)
        guard let second = ContinuationCoordinator.shared.status(for: "chain-B"), second.sourceSessionID == "chain-B" else {
            throw TestFailure("could not create B->C fixture")
        }
        let c = vm(second.destinationSessionID)
        let endpoints = [vm("chain-A"), b, c]
        for endpoint in endpoints { endpoint.promptQueue = [QueuedPrompt("retained")]; endpoint.isProcessing = true }
        b.cancel() // originatingCancel must NOT recurse into B.cancel again.
        try await settle()
        for endpoint in endpoints {
            try expect(!endpoint.continuationQueueMayRun && endpoint.starts == 0, "middle Stop did not hard-fence both directions")
            try expect(endpoint.promptQueue.count == 1, "middle Stop dropped a linked queue")
        }
    }
    @MainActor static func testDeleteRestore() async throws {
        try await link("delete-A", "delete-B")
        let old = vm("delete-B")
        old.promptQueue = [QueuedPrompt("old deleted queue")]
        old.resumeQueueAfterCancel()
        let stale = old.continuationQueueFence.generation
        try await ChatStore.shared.sql("DELETE FROM sessions WHERE id='delete-B'")
        ContinuationCoordinator.shared.sessionDeleted("delete-B")
        try expect(ContinuationCoordinator.shared.isDeletedSession("delete-B"), "deleted ID was not fenced")
        try expect(!ContinuationCoordinator.shared.userBeganRequest("delete-B"), "explicit send reopened a deleted ID")
        try expect(ContinuationCoordinator().isDeletedSession("delete-B"), "deleted ID was not persisted")
        try await ChatStore.shared.addSession("delete-B")
        ContinuationCoordinator.shared.sessionRestored("delete-B")
        try expect(!ContinuationCoordinator.shared.isDeletedSession("delete-B"), "restore did not clear persisted deleted ID")
        try expect(!ContinuationCoordinator().isDeletedSession("delete-B"), "restore did not persist tombstone removal")
        try expect(ViewModelCache.shared.get(for: "delete-B") == nil, "restore did not evict the old VM")
        let fresh = vm("delete-B")
        try expect(old !== fresh && old.continuationQueueFence.isDeleted, "restore reused/revived deleted VM")
        try expect(!old.reopenContinuationQueueForExplicitUserRequest(), "old VM permanent fence reopened")
        try expect(!fresh.continuationQueueMayRun, "backup restore itself started a new task")
        try expect(ContinuationCoordinator.shared.userBeganRequest("delete-B"), "fresh restored VM could not explicitly reopen")
        try await settle()
        try expect(old.starts == 0 && old.promptQueue.count == 1 && !old.continuationQueueMayRun(generation: stale),
                   "old deleted rescue survived restore of the same ID")
        try expect(fresh.starts == 0 && fresh.continuationQueueMayRun, "restore automatically dispatched a new VM")
    }
    @MainActor static func testIdleAndAwaitFences() async throws {
        let idle = vm("idle-rescue")
        idle.promptQueue = [QueuedPrompt("keep idle queue")]
        idle.startDrainIfIdle(reason: "test-already-scheduled")
        let stale = idle.continuationQueueFence.generation
        idle.cancel(resumeQueuedPrompts: false)
        try await settle()
        try expect(idle.starts == 0 && idle.promptQueue.count == 1, "queued idle task ignored hard fence")
        try expect(idle.reopenContinuationQueueForExplicitUserRequest(), "explicit local reopen failed")
        try expect(!idle.continuationQueueMayRun(generation: stale), "old idle token revived")

        let compact = vm("post-compact-rescue")
        compact.promptQueue = [QueuedPrompt("keep post-compact queue")]
        compact.schedulePostCompactDrain()
        compact.cancel(resumeQueuedPrompts: false)
        try expect(compact.reopenContinuationQueueForExplicitUserRequest(), "post-compact endpoint could not explicitly reopen")
        try await settle()
        try expect(compact.starts == 0 && compact.promptQueue.count == 1 && !compact.postCompactDrainPending,
                   "old post-compact task revived after stop->reopen or left drain stuck")

        let compactOwner = vm("compact-state-owner")
        compactOwner.isCompacting = true
        let oldCompactGeneration = compactOwner.continuationQueueFence.generation
        compactOwner.cancel(resumeQueuedPrompts: false)
        try expect(!compactOwner.isCompacting, "hard cancel left the revoked compact latch set")
        try expect(compactOwner.reopenContinuationQueueForExplicitUserRequest(), "compact owner could not explicitly reopen")
        compactOwner.isProcessing = true
        compactOwner.isCompacting = true
        compactOwner.compactTask = Task { @MainActor in }
        compactOwner.finishCompactionState(generation: oldCompactGeneration, wasProcessingOnEntry: false)
        try expect(compactOwner.isProcessing && compactOwner.isCompacting && compactOwner.compactTask != nil,
                   "old production compact defer cleared the new owner's processing/compact slot")
        compactOwner.finishCompactionState(generation: compactOwner.continuationQueueFence.generation,
                                          wasProcessingOnEntry: true)
        try expect(compactOwner.isProcessing && !compactOwner.isCompacting && compactOwner.compactTask == nil,
                   "current compact owner could not release its own state")

        for injection in [false, true] {
            let endpoint = vm("await-paste-\(injection)")
            let path = try attachment()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let q = QueuedPrompt("paste awaiting storage", attachments: [path])
            endpoint.promptQueue = [q]
            endpoint.pastedHook = { endpoint.cancel(resumeQueuedPrompts: false); await Task.yield() }
            if injection {
                var index = 0, committed = 0
                let result = await endpoint.injectQueuedPromptsAsNewTurn(msgIdx: &index,
                    committedBlockCount: &committed, turnUsage: TokenUsage(), at: .turnEnd)
                try expect(result == .none, "injection resumed after fence installed during paste await")
            } else {
                await endpoint.drainQueuedPrompts()
            }
            try expect(endpoint.starts == 0 && endpoint.promptQueue.map(\.id) == [q.id], "await guard consumed uncommitted queued work")
            try expect(FileManager.default.fileExists(atPath: path), "await guard lost queued attachment source")
        }
        let persisted = vm("await-persist")
        persisted.promptQueue = [QueuedPrompt("already committing")]
        persisted.persistHook = {
            persisted.promptQueue.append(QueuedPrompt("late uncommitted work"))
            persisted.cancel(resumeQueuedPrompts: false)
            await Task.yield()
        }
        await persisted.drainQueuedPrompts()
        try expect(persisted.starts == 0 && persisted.promptQueue.count == 1,
                   "persist await crossed a hard stop into provider/tools or consumed late work")
    }
    @MainActor static func testUncancelledOldGeneration() async throws {
        let endpoint = vm("uncancelled-old-generation")
        let path = try attachment()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let q = QueuedPrompt("orphan task still awaiting paste", attachments: [path])
        endpoint.promptQueue = [q]
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        endpoint.pastedHook = {
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        // Deliberately not registered as currentTask/idleDrainTask: generation
        // must protect even an old task whose handle has already been replaced.
        let orphan = Task { @MainActor in await endpoint.drainQueuedPrompts() }
        while !entered { await Task.yield() }
        endpoint.cancel(resumeQueuedPrompts: false)
        try expect(ContinuationCoordinator.shared.userBeganRequest(endpoint.sessionId), "explicit request could not reopen orphan endpoint")
        endpoint.userDidCancel = false
        release?.resume()
        await orphan.value
        try expect(!orphan.isCancelled, "fixture accidentally relied only on task cancellation")
        try expect(endpoint.starts == 0 && endpoint.promptQueue.map(\.id) == [q.id], "old uncancelled generation consumed the reopened request's queue")
        try expect(FileManager.default.fileExists(atPath: path), "old uncancelled generation deleted queued attachment")
    }
    @MainActor static func testOldDrainCannotReleaseNewOwner() async throws {
        for newFinishesFirst in [false, true] {
            let endpoint = vm("drain-owner-\(newFinishesFirst)")
            let path = try attachment()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let q = QueuedPrompt("preserve [Pasted#1]", attachments: [path])
            endpoint.promptQueue = [q]
            endpoint.pastedTexts = [PasteEntry(id: 1, text: "original pasted content")]
            var calls = 0
            var oldEntered = false, newEntered = false
            var oldRelease: CheckedContinuation<Void, Never>?
            var newRelease: CheckedContinuation<Void, Never>?
            endpoint.pastedHook = {
                calls += 1
                if calls == 1 {
                    oldEntered = true
                    await withCheckedContinuation { oldRelease = $0 }
                } else if calls == 2 {
                    newEntered = true
                    await withCheckedContinuation { newRelease = $0 }
                }
            }
            let old = Task { @MainActor in await endpoint.drainQueuedPrompts() }
            for _ in 0..<1000 { if oldEntered { break }; await Task.yield() }
            try expect(oldEntered, "old fixture did not enter paste await")
            endpoint.cancel(resumeQueuedPrompts: false)
            try expect(ContinuationCoordinator.shared.userBeganRequest(endpoint.sessionId), "owner fixture failed to reopen")
            endpoint.userDidCancel = false
            endpoint.isProcessing = true
            let generation = endpoint.continuationQueueFence.generation
            let fresh = Task { @MainActor in await endpoint.drainQueuedPrompts() }
            for _ in 0..<1000 { if newEntered { break }; await Task.yield() }
            try expect(newEntered, "stale drain latch blocked the explicitly reopened owner")
            if newFinishesFirst {
                newRelease?.resume()
                await fresh.value
                oldRelease?.resume()
                await old.value
                try expect(endpoint.pastedTexts.isEmpty, "old paste rollback resurrected content already consumed by new owner")
            } else {
                endpoint.drainRequestedWhileBusy = true
                oldRelease?.resume()
                await old.value
                try expect(endpoint.isDrainingQueue && endpoint.queueDrainGeneration == generation,
                           "old drain defer cleared the new owner's latch")
                try expect(endpoint.drainRequestedWhileBusy, "old drain consumed the new owner's handover flag")
                try expect(endpoint.promptQueue.map(\.id) == [q.id] && FileManager.default.fileExists(atPath: path),
                           "old drain consumed the new owner's queued attachment")
                newRelease?.resume()
                await fresh.value
            }
            try expect(!old.isCancelled, "owner regression accidentally relied on cancellation alone")
            try expect(endpoint.starts == 1 && endpoint.promptQueue.isEmpty,
                       "new owner did not run exactly once after old drain retired")
            try expect(!endpoint.isDrainingQueue && endpoint.queueDrainGeneration == nil,
                       "new owner did not release its own drain latch")
        }
    }
    @MainActor static func main() async {
        let keys = [ContinuationPolicy.settingsKey, "nativeContinuation.stoppedSessions",
            "nativeContinuation.hardStoppedSessions", "nativeContinuation.deletedSessions",
            "nativeContinuation.invalidatedBefore", "nativeContinuation.policyInvalidatedBefore"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: ContinuationPolicy.settingsKey)
        do {
            ChatStore.shared = try ChatStore()
            try await testTakeover()
            try await testIndependentStop()
            try await testBidirectionalStop()
            try await testDeleteRestore()
            try await testIdleAndAwaitFences()
            try await testUncancelledOldGeneration()
            try await testOldDrainCannotReleaseNewOwner()
            print("PASS: \(assertions) assertions using exact production Cancel + complete PromptQueue + Coordinator/Store/Fence")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
