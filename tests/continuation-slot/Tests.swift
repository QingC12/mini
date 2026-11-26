import Foundation
import Dispatch

struct SlotTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct SlotOwnerState: Equatable {
    let generation: UUID
    let request: UUID
    let processing: Bool
    let suspended: Bool
    let background: UUID?
    let backgroundEnds: Int
    let queue: [String]
    let rescueSignals: Int
}

@main struct ContinuationSlotTests {
    @MainActor static var assertions = 0
    @MainActor static var pool: SessionConcurrencyManager { .shared }
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw SlotTestFailure(message) }
    }
    @MainActor static func state(_ vm: AIChatViewModel) -> SlotOwnerState {
        SlotOwnerState(generation: vm.continuationQueueFence.generation,
            request: vm.continuationQueueFence.requestGeneration,
            processing: vm.isProcessing, suspended: vm.isSuspended,
            background: vm.backgroundOwner, backgroundEnds: vm.backgroundEnds,
            queue: vm.queuedPrompts, rescueSignals: vm.queueRescueSignals)
    }
    @MainActor static func until(_ message: String, _ condition: () -> Bool) async throws {
        // Wait for observable production state, not a guessed timing delay.
        for _ in 0..<50_000 {
            if condition() { return }
            await Task.yield()
        }
        throw SlotTestFailure("readiness barrier not reached: " + message)
    }
    @MainActor static func fill(_ prefix: String) async throws -> [SessionSlotLease] {
        try expect(pool.runningSessions.isEmpty && pool.suspendedSessions.isEmpty, "clean real pool before " + prefix)
        var leases: [SessionSlotLease] = []
        for index in 0..<pool.maxConcurrent {
            leases.append(try await pool.acquire(sessionId: "\(prefix)-holder-\(index)", exempt: false))
        }
        try expect(pool.runningSessions.count == pool.maxConcurrent, "real pool filled to shipping limit")
        return leases
    }
    @MainActor static func release(_ leases: [SessionSlotLease]) {
        for lease in leases { pool.release(lease) }
    }
    @MainActor static func empty(_ label: String) throws {
        try expect(pool.runningSessions.isEmpty, label + ": no running slot leak")
        try expect(pool.suspendedSessions.isEmpty, label + ": no suspended waiter leak")
    }
    @MainActor static func releaseCount(_ sid: String) -> Int {
        ContinuationCoordinator.shared.releases.filter { $0 == sid }.count
    }

    @MainActor static func testImmediate() async throws {
        let vm = AIChatViewModel("immediate")
        let owner = vm.beginExplicitOwner()
        let lease = await vm.acquireSessionSlot("immediate")
        try expect(lease == SessionSlotLease(sessionId: "immediate", holdsSlot: true), "normal helper returns a real held lease")
        try expect(pool.runningSessions == ["immediate"], "normal acquire enters real running set")
        try expect(vm.isProcessing && !vm.isSuspended && vm.backgroundOwner == owner, "success preserves caller processing/background")
        try expect(vm.backgroundEnds == 0, "success does not end background ownership")
        if let lease { pool.release(lease) }
        try expect(releaseCount("immediate") == 1, "normal caller releases once")
        try empty("immediate")
    }

    @MainActor static func testFIFO() async throws {
        let holders = try await fill("fifo")
        let a = AIChatViewModel("fifo-A"), b = AIChatViewModel("fifo-B")
        a.beginExplicitOwner(); b.beginExplicitOwner()
        let ta = Task { @MainActor in await a.acquireSessionSlot("fifo-A") }
        try await until("first waiter") { pool.isSuspended("fifo-A") }
        let tb = Task { @MainActor in await b.acquireSessionSlot("fifo-B") }
        try await until("second waiter") { pool.isSuspended("fifo-B") }
        try expect(pool.suspendedSessions == ["fifo-A", "fifo-B"], "production waiters are FIFO")
        try expect(a.isSuspended && b.isSuspended, "full pool marks both VMs suspended")
        pool.release(holders[0])
        let la = await ta.value
        try expect(la?.holdsSlot == true && !a.isSuspended, "first waiter receives real lease and unsuspends")
        try expect(pool.suspendedSessions == ["fifo-B"], "second waiter remains queued")
        if let la { pool.release(la) }
        let lb = await tb.value
        try expect(lb?.holdsSlot == true && !b.isSuspended, "second waiter progresses after first release")
        if let lb { pool.release(lb) }
        release(Array(holders.dropFirst()))
        try empty("FIFO")
    }

    @MainActor static func testCurrentOwnerCancellation() async throws {
        let holders = try await fill("cancel")
        let vm = AIChatViewModel("cancel-current")
        vm.beginExplicitOwner()
        let queue = vm.queuedPrompts
        let task = Task { @MainActor in await vm.acquireSessionSlot("cancel-current") }
        try await until("current owner waits") { pool.isSuspended("cancel-current") }
        // Same actor, no await between resuming the waiter and cancellation.
        pool.cancelWait(sessionId: "cancel-current")
        task.cancel()
        let result = await task.value
        try expect(result == nil, "real cancellation throws through real helper catch")
        try expect(!vm.isProcessing && !vm.isSuspended, "current owner cancellation still resets run flags")
        try expect(vm.backgroundOwner == nil && vm.backgroundEnds == 1, "current owner cancellation ends background once")
        try expect(vm.queuedPrompts == queue, "cancellation preserves pending prompt content")
        try expect(!pool.runningSessions.contains("cancel-current"), "cancelled waiter acquired no slot")
        try expect(releaseCount("cancel-current") == 0, "failed acquire is never released as a held lease")
        release(holders)
        try empty("current cancellation")
    }

    @MainActor static func testStoppedWaiterCannotClearNewOwner() async throws {
        let holders = try await fill("takeover")
        let sid = "takeover-same-session"
        let vm = AIChatViewModel(sid)
        vm.beginExplicitOwner()
        let old = Task { @MainActor in await vm.acquireSessionSlot(sid) }
        try await until("old real waiter is suspended") { pool.isSuspended(sid) }
        let neighbour = AIChatViewModel("takeover-neighbour")
        neighbour.beginExplicitOwner()
        let neighbourTask = Task { @MainActor in await neighbour.acquireSessionSlot("takeover-neighbour") }
        try await until("unrelated FIFO waiter") { pool.isSuspended("takeover-neighbour") }
        let oldGeneration = vm.continuationQueueFence.generation

        // CRITICAL SECTION: NO await. The old checked continuation is resumed,
        // cancelled and superseded before MainActor can run its failure catch.
        vm.stopWaitingTask(old)
        let newBackground = vm.beginExplicitOwner(suspended: true)
        let fresh = Task { @MainActor in await vm.acquireSessionSlot(sid) }
        let newState = state(vm)
        let runningBefore = pool.runningSessions
        try expect(newState.generation != oldGeneration, "explicit retry owns a different generation before old failure")
        try expect(newState.processing && newState.suspended && newState.background == newBackground, "new owner is visibly active before releasing actor")
        try expect(pool.suspendedSessions == ["takeover-neighbour"], "Stop removed only old waiter synchronously")
        // End critical section. No hook or fake successful acquire intervenes.

        let oldResult = await old.value
        try expect(oldResult == nil, "cancelled old real waiter returns nil")
        try expect(state(vm) == newState, "P1: old cancellation cannot alter new processing/suspended/background/queue/rescue ownership")
        try await until("fresh owner genuinely waits in same full pool") { pool.isSuspended(sid) }
        try expect(state(vm) == newState, "new owner's true wait preserves the ownership snapshot")
        try expect(pool.runningSessions == runningBefore, "old failure neither steals nor frees another owner's slot")
        try expect(pool.suspendedSessions == ["takeover-neighbour", sid], "old catch preserves unrelated and new FIFO waiter ownership")
        try expect(releaseCount(sid) == 0, "cancelled old waiter had no lease to release")

        pool.release(holders[0])
        let neighbourLease = await neighbourTask.value
        try expect(neighbourLease?.holdsSlot == true, "unrelated existing waiter still wins FIFO")
        if let neighbourLease { pool.release(neighbourLease) }
        let freshLease = await fresh.value
        try expect(freshLease?.holdsSlot == true, "new owner later receives a real slot")
        try expect(vm.isProcessing && !vm.isSuspended && vm.backgroundOwner == newBackground, "fresh success leaves new request running normally")
        if let freshLease { pool.release(freshLease) }
        release(Array(holders.dropFirst()))
        try empty("Stop/retry failure takeover")
    }

    @MainActor static func testStaleSuccessfulLeaseIsReleased() async throws {
        let holders = try await fill("stale-success")
        let sid = "stale-success-same-session"
        let vm = AIChatViewModel(sid)
        vm.beginExplicitOwner()
        let old = Task { @MainActor in await vm.acquireSessionSlot(sid) }
        try await until("old success-path waiter") { pool.isSuspended(sid) }
        // Deliberately DO NOT cancel the Task: cancelWait resumes a real
        // acquire that succeeds, so only the generation guard can reject it.
        vm.stopWaitingTask(old, cancel: false)
        vm.beginExplicitOwner(suspended: true)
        let newState = state(vm)
        let runningBefore = pool.runningSessions
        let result = await old.value
        try expect(result == nil, "obsolete noncancelled successful acquire is not handed to caller")
        try expect(state(vm) == newState, "obsolete success does not clear new suspended/background owner")
        try expect(pool.runningSessions == runningBefore, "helper returns obsolete acquired slot immediately: no leak")
        try expect(releaseCount(sid) == 1, "obsolete real held lease released exactly once inside helper")
        try expect(!pool.isSuspended(sid), "obsolete waiter removed from real FIFO")
        release(holders)
        try empty("obsolete successful lease")
    }

    @MainActor static func testPendingLifecycleCannotStrandAdmittedSlotOwner() async throws {
        let holders = try await fill("pending-lifecycle")
        let sid = UUID().uuidString
        let vm = AIChatViewModel(sid)
        let background = vm.beginExplicitOwner()
        let generation = vm.continuationQueueFence.generation
        let waiting = Task { @MainActor in await vm.acquireSessionSlot(sid) }
        try await until("admitted owner waiting before lifecycle") { pool.isSuspended(sid) }
        let coordinator = ContinuationCoordinator.shared
        let registry = coordinator.lifecycleRegistry
        let token = registry.beginSessionLifecycle(for: [sid])
        // Registry token uses the shipping protocol, not a Bool-only stub.
        // Real SQL failure/release is separately exercised by LifecycleTests.
        try expect(coordinator.isQueueFenced(sid), "pending lifecycle blocks new ownership admission")
        try expect(vm.continuationQueueMayRun(generation: generation), "transient pending is not Stop of an admitted owner")
        pool.release(holders[0])
        let lease = await waiting.value
        try expect(lease?.holdsSlot == true, "real helper must not release-and-nil an admitted lease merely because SQL is pending")
        try expect(vm.isProcessing && !vm.isSuspended && vm.backgroundOwner == background && vm.backgroundEnds == 0,
                   "same-generation pending preserves the active owner and background lease")
        try expect(pool.runningSessions.contains(sid), "admitted owner retains its real slot while SQL is pending")
        // Exact failure/skip protocol: release reservation, without Stop or
        // generation mutation. It must not leave processing=true with no lease.
        registry.finishSessionLifecycle(token)
        try expect(!coordinator.isQueueFenced(sid) && vm.continuationQueueFence.generation == generation,
                   "failure-style pending release restores admission without changing owner")
        try expect(vm.continuationQueueMayRun && pool.runningSessions.contains(sid),
                   "pending failure leaves a live runnable owner, not stranded UI state")
        if let lease { pool.release(lease) }
        release(Array(holders.dropFirst()))
        try empty("admitted owner across pending failure")
    }

    @MainActor static func testStoppedWithoutReopen() async throws {
        let holders = try await fill("stop-only")
        let vm = AIChatViewModel("stop-only-session")
        vm.beginExplicitOwner()
        let old = Task { @MainActor in await vm.acquireSessionSlot("stop-only-session") }
        try await until("stop-only waiter") { pool.isSuspended("stop-only-session") }
        vm.stopWaitingTask(old)
        let stoppedState = state(vm)
        let result = await old.value
        try expect(result == nil && state(vm) == stoppedState, "Stop already owns cleanup: late catch cannot repeat it")
        try expect(vm.backgroundEnds == 1, "plain Stop ends background exactly once")
        release(holders)
        try empty("Stop without reopen")
    }

    @MainActor static func testExemptChild() async throws {
        let holders = try await fill("exempt")
        let vm = AIChatViewModel("exempt-child", exempt: true)
        let owner = vm.beginExplicitOwner()
        let runningBefore = pool.runningSessions
        let lease = await vm.acquireSessionSlot("exempt-child")
        try expect(lease == SessionSlotLease(sessionId: "exempt-child", holdsSlot: false), "child exemption returns real nonholding lease even when full")
        try expect(!vm.isSuspended && vm.isProcessing && vm.backgroundOwner == owner, "child remains running without queueing")
        if let lease { pool.release(lease) }
        try expect(pool.runningSessions == runningBefore && pool.suspendedSessions.isEmpty, "child release cannot release another session's slot")
        try expect(releaseCount("exempt-child") == 0, "nonholding lease does not notify Coordinator of release")
        release(holders)
        try empty("child exemption")
    }

    @MainActor static func main() async {
        // Deadlocks must fail CI, not hang indefinitely on a lost continuation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("FAIL: continuation-slot watchdog expired\n", stderr)
            exit(124)
        }
        do {
            try await testImmediate()
            try await testFIFO()
            try await testCurrentOwnerCancellation()
            try await testStoppedWaiterCannotClearNewOwner()
            try await testStaleSuccessfulLeaseIsReleased()
            try await testPendingLifecycleCannotStrandAdmittedSlotOwner()
            try await testStoppedWithoutReopen()
            try await testExemptChild()
            print("PASS: continuation-slot \(assertions) assertions; verbatim helper + real SessionConcurrencyManager")
        } catch {
            fputs("FAIL: continuation-slot: \(error)\n", stderr)
            exit(1)
        }
    }
}
