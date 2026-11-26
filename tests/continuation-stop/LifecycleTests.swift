import Foundation

extension ContinuationStopTests {
    @MainActor static func lifecycleRegistry() -> ContinuationStorageBindings {
        ContinuationStorageBindings.registry(at: ChatStore.shared.minisBaseURL)
    }
    @MainActor static func drainLifecycle() async {
        await lifecycleRegistry().enqueueSessionLifecycleNotification {}.value
    }
    @MainActor static func testSQLLifecycleBlocksTakeover() async throws {
        let a = UUID().uuidString, b = UUID().uuidString, unrelated = UUID().uuidString
        try await link(a, b)
        let source = vm(a), target = vm(b)
        target.promptQueue = [QueuedPrompt("must not drain while lifecycle is pending")]
        let generation = target.continuationQueueFence.generation
        let registry = lifecycleRegistry()
        let applyGate = LifecycleApplyGate()
        registry.enqueueSessionLifecycleNotification { await applyGate.wait() }
        let sqlGate = LifecycleSQLBarrier()
        try await ChatStore.shared.installLifecycleDeleteBarrier(sqlGate)
        let store = ChatStore.shared
        let deletion = Task.detached { await store.testDeleteSession(a) }
        let reached = sqlGate.reachedSQL.wait(timeout: .now() + 10) == .success
        if !reached { sqlGate.continueSQL.signal() }
        try expect(reached, "real DELETE did not reach pre-commit SQLite barrier")
        // SQL is still in progress: this proves reservation is not first added
        // by enqueue AFTER commit. No MainActor notification has run.
        let reservedBeforeCommit = registry.hasPendingSessionLifecycle(for: [a])
        let rejectedBeforeCommit = !ContinuationCoordinator.shared.userBeganRequest(b)
        let unrelatedAllowed = ContinuationCoordinator.shared.userBeganRequest(unrelated)
        let noEarlyHardStop = source.isProcessing && !target.continuationQueueFence.isStopped
        target.startDrainIfIdle(reason: "pending-SQL")
        target.resumeQueueAfterCancel()
        let noQueueTask = target.idleDrainTask == nil && target.starts == 0
        sqlGate.continueSQL.signal() // Always unblock SQL before assertions throw.
        await deletion.value
        try await store.sql("DROP TRIGGER lifecycle_hold")
        try expect(reservedBeforeCommit && rejectedBeforeCommit, "SQL-before-enqueue window accepted B ownership")
        try expect(unrelatedAllowed, "unrelated explicit request was globally blocked")
        try expect(noEarlyHardStop, "pending registration itself hard-stopped a live VM")
        try expect(noQueueTask && target.promptQueue.count == 1, "pending lifecycle scheduled or consumed the real queue")
        let sourceExists = try await store.continuationSessionExists(a)
        try expect(!sourceExists, "actual source DELETE did not commit")
        try expect(registry.hasPendingSessionLifecycle(for: [a]), "SQL return released token before delayed apply")
        try expect(ContinuationCoordinator.shared.isQueueFenced(b) && ContinuationCoordinator.shared.hasPendingHandoff(for: b),
                   "journal-only A→B chain did not share lifecycle fence")
        try expect(!ContinuationCoordinator.shared.userBeganRequest(b), "committed but unapplied DELETE accepted new B owner")
        try expect(target.continuationQueueFence.generation == generation && !target.continuationQueueFence.isStopped,
                   "rejected request mutated ownership or pending hard-stopped B")
        await applyGate.open()
        await drainLifecycle()
        try expect(!registry.hasPendingSessionLifecycle(for: [a, b]), "applied deletion leaked pending token")
        try expect(ContinuationCoordinator.shared.isDeletedSession(a) && target.continuationQueueFence.isStopped,
                   "delayed production sessionDeleted did not hard-stop old task")
        try expect(target.promptQueue.count == 1 && target.starts == 0, "deleted chain lost or drained preserved B queue")
        try expect(ContinuationCoordinator.shared.userBeganRequest(b), "live successor could not reopen AFTER deletion apply")
        target.promptQueue = [] // Explicit test owner, not an automatic queue drain.
        target.userDidCancel = false; target.isProcessing = true
        try await target.runAgentLoop()
        await drainLifecycle()
        try expect(target.starts == 1 && target.isProcessing && target.continuationQueueMayRun,
                   "late lifecycle notification killed the newly admitted B owner")
    }

    @MainActor static func testSQLLifecycleRestoreNewVM() async throws {
        let a = UUID().uuidString, b = UUID().uuidString
        try await link(a, b)
        let registry = lifecycleRegistry()
        let base = ChatStore.shared.minisBaseURL
        try FileManager.default.createDirectory(at: base.appendingPathComponent(a + "/workspace"), withIntermediateDirectories: true)
        let file = base.appendingPathComponent(a + "/workspace/live-root")
        try Data("keep live restored root".utf8).write(to: file)
        _ = try registry.bind(source: a, destination: b)
        let firstGate = LifecycleApplyGate(), middleGate = LifecycleApplyGate()
        registry.enqueueSessionLifecycleNotification { await firstGate.wait() }
        await ChatStore.shared.testDeleteSession(a)
        // This barrier runs after D_A completes but BEFORE R_A applies.
        registry.enqueueSessionLifecycleNotification { await middleGate.wait() }
        let restored = await ChatStore.shared.lifecycleRestore(a)
        if case .inserted = restored {} else { throw TestFailure("actual restore INSERT failed") }
        // The UI may materialize a candidate VM from the restored SQL row.
        // It is NOT an owner until admission; pending must reject it explicitly.
        let candidate = AIChatViewModel(a)
        ViewModelCache.shared.cache[a] = candidate
        let generation = candidate.continuationQueueFence.generation
        try expect(!ContinuationCoordinator.shared.userBeganRequest(a), "restored row admitted candidate VM before D/R apply")
        try expect(candidate.starts == 0 && candidate.continuationQueueFence.generation == generation,
                   "pending restore request mutated candidate VM ownership")
        await firstGate.open()
        await middleGate.entered()
        try expect(ContinuationCoordinator.shared.isDeletedSession(a), "first deletion did not apply before middle barrier")
        try expect(registry.hasPendingSessionLifecycle(for: [a, b]), "finishing D incorrectly cleared queued R token")
        try expect(!ContinuationCoordinator.shared.userBeganRequest(b), "B reopened while same-root restore remained pending")
        await middleGate.open()
        await drainLifecycle()
        try expect(!registry.hasPendingSessionLifecycle(for: [a, b]), "D/R completion leaked reservation")
        try expect(!ContinuationCoordinator.shared.isDeletedSession(a) && ViewModelCache.shared.get(for: a) == nil,
                   "production restore did not clear ID tombstone and evict unowned candidate")
        try expect(candidate.continuationQueueFence.isDeleted && candidate.starts == 0,
                   "candidate was started or revived by restore")
        let fresh = vm(a)
        try expect(fresh !== candidate && ContinuationCoordinator.shared.userBeganRequest(a), "post-apply fresh VM could not acquire ownership")
        fresh.userDidCancel = false; fresh.isProcessing = true
        try await fresh.runAgentLoop()
        await drainLifecycle()
        try expect(fresh.starts == 1 && fresh.isProcessing && fresh.continuationQueueMayRun,
                   "old restore evicted or hard-stopped post-apply fresh owner")
        try expect(FileManager.default.fileExists(atPath: file.path), "lifecycle integration regressed live-root storage protection")
    }

    @MainActor static func testSQLLifecycleFailureReleasesPending() async throws {
        for action in ["ABORT, 'lifecycle failure'", "IGNORE"] {
            let a = UUID().uuidString, b = UUID().uuidString
            try await link(a, b)
            let source = vm(a), target = vm(b)
            target.isProcessing = true
            let generation = target.continuationQueueFence.generation
            let stops = AgentJobRegistry.shared.stops.count
            let store = ChatStore.shared
            let sqlGate = LifecycleSQLBarrier()
            try await store.installLifecycleDeleteBarrier(sqlGate)
            try await store.sql("DROP TRIGGER lifecycle_hold; CREATE TRIGGER lifecycle_fail BEFORE DELETE ON sessions BEGIN SELECT hold_lifecycle(); SELECT RAISE(\(action)); END")
            let deletion = Task.detached { await store.testDeleteSession(a) }
            let reached = sqlGate.reachedSQL.wait(timeout: .now() + 10) == .success
            // This fixture is journal-linked but not yet physically bound;
            // Coordinator (not the root-only registry API) expands A↔B.
            let pending = ContinuationCoordinator.shared.hasPendingSessionLifecycle(for: b)
            let capturedOwnerMayRun = target.continuationQueueMayRun(generation: generation)
            let stillActive = !target.turnWasStopped && target.isProcessing
            sqlGate.continueSQL.signal()
            await deletion.value
            try expect(reached && pending, "failed DELETE precommit pending window: reached=\(reached), linkedPending=\(pending)")
            try expect(capturedOwnerMayRun && stillActive, "SQL pending temporarily turned the already-admitted generation into Stop")
            await drainLifecycle()
            try expect(!lifecycleRegistry().hasPendingSessionLifecycle(for: [a, b]), "failed DELETE leaked pending reservation")
            try expect(source.isProcessing && target.isProcessing && target.continuationQueueFence.generation == generation,
                       "SQL DELETE failure hard-stopped a real VM")
            try expect(AgentJobRegistry.shared.stops.count == stops && !ContinuationCoordinator.shared.isDeletedSession(a),
                       "SQL DELETE failure published sessionDeleted or cancelled jobs")
            try await ChatStore.shared.sql("DROP TRIGGER lifecycle_fail")
            await ChatStore.shared.testDeleteSession(a)
            await drainLifecycle()
            try await ChatStore.shared.sql("CREATE TRIGGER lifecycle_restore_fail BEFORE INSERT ON sessions BEGIN SELECT RAISE(\(action)); END")
            let failed = await ChatStore.shared.lifecycleRestore(a)
            if case .skippedNoParent = failed {} else { throw TestFailure("failed SQL restore reported success") }
            await drainLifecycle()
            try expect(!lifecycleRegistry().hasPendingSessionLifecycle(for: [a, b]), "failed restore leaked pending reservation")
            try expect(ContinuationCoordinator.shared.isDeletedSession(a) && !ContinuationCoordinator.shared.userBeganRequest(a),
                       "failed restore cleared real Coordinator deletion fence")
            try await ChatStore.shared.sql("DROP TRIGGER lifecycle_restore_fail")
            _ = await ChatStore.shared.lifecycleRestore(b)
            await drainLifecycle()
            let fresh = vm(b)
            try expect(ContinuationCoordinator.shared.userBeganRequest(b), "live B cannot reopen after successful restoration")
            fresh.userDidCancel = false; fresh.isProcessing = true
            let owner = fresh.continuationQueueFence.generation
            let skipped = await ChatStore.shared.lifecycleRestore(b)
            if case .skippedLocalNewer = skipped {} else { throw TestFailure("LWW skip fixture failed") }
            await drainLifecycle()
            try expect(!lifecycleRegistry().hasPendingSessionLifecycle(for: [b]), "LWW skip leaked pending token")
            try expect(ViewModelCache.shared.get(for: b) === fresh && fresh.isProcessing && fresh.continuationQueueFence.generation == owner,
                       "LWW skip evicted or stopped real current VM")
        }
    }

    @MainActor static func testRegistryOnlyLifecycleScope() throws {
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString, unrelated = UUID().uuidString
        let registry = lifecycleRegistry()
        try FileManager.default.createDirectory(at: registry.base.appendingPathComponent(a), withIntermediateDirectories: true)
        _ = try registry.bind(source: a, destination: b)
        let first = registry.beginSessionLifecycle(for: [a])
        let second = registry.beginSessionLifecycle(for: [a])
        try expect(ContinuationCoordinator.shared.isQueueFenced(b) && !ContinuationCoordinator.shared.userBeganRequest(b),
                   "physical-root peer without a loaded journal edge escaped pending lifecycle")
        try expect(ContinuationCoordinator.shared.userBeganRequest(unrelated), "physical-root reservation blocked unrelated ID")
        var refused = false
        do { _ = try registry.bind(source: b, destination: c) } catch { refused = true }
        try expect(refused, "bind extended a task while its SQL lifecycle was pending")
        registry.finishSessionLifecycle(first)
        try expect(registry.hasPendingSessionLifecycle(for: [b]), "finishing one token cleared another queued generation")
        registry.finishSessionLifecycle(second)
        try expect(!registry.hasPendingSessionLifecycle(for: [a, b]) && ContinuationCoordinator.shared.userBeganRequest(b),
                   "last completed reservation failed to release explicit ownership admission")
    }
}
