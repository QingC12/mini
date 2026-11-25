import Combine
import Foundation

/// Device-local, at-most-once continuation outbox. Only release/restore dispatch;
/// staging a provider failure never starts work while its source owns a slot.
@MainActor
final class ContinuationCoordinator: ObservableObject {
    static let shared = ContinuationCoordinator()
    @Published private(set) var records: [String: ContinuationRecord] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var stoppedSessions = Set(UserDefaults.standard.stringArray(forKey: "nativeContinuation.stoppedSessions") ?? [])
    private var epochs: [String: UUID] = [:]
    private var policyEpoch = UUID()
    private var policyInvalidatedBefore = UserDefaults.standard.double(forKey: "nativeContinuation.policyInvalidatedBefore")
    private var invalidatedBefore = UserDefaults.standard.dictionary(forKey: "nativeContinuation.invalidatedBefore") as? [String: Double] ?? [:]
    private var restoring = false
    private var dispatchedInProcess: Set<String> = []
    private var stagedInProcess: Set<String> = []
    private var cancelling = false
    // Redirected/finished/paused sources must not drain late queue items into
    // the old provider conversation. Only a NEW explicit request releases it.
    private var explicitlyReopenedSources: Set<String> = []
    private var stagingSources: Set<String> = []

    private struct Fence {
        let source: String
        let destination: String
        let sourceEpoch: UUID?
        let destinationEpoch: UUID?
        let policyEpoch: UUID
    }
    private struct QueueSnapshot: Equatable {
        let ids: [UUID]
        let texts: [String]
        let unsupported: Bool
    }
    private enum RecoveryError: LocalizedError {
        case missingSource, uncertain, changedQueue
        var errorDescription: String? {
            switch self {
            case .missingSource: return "A linked conversation was deleted; continuation was stopped."
            case .uncertain: return "A previous dispatch may have started. Inspect files, tools and live jobs before retrying manually."
            case .changedQueue: return "Pending requirements changed during dispatch; inspect the saved handoff before retrying."
            }
        }
    }

    func hasPendingHandoff(for sessionID: String?) -> Bool {
        guard let sessionID, ContinuationPolicy.isEnabled, !explicitlyReopenedSources.contains(sessionID) else { return false }
        return stagingSources.contains(sessionID) || records.values.contains {
            $0.sourceSessionID == sessionID && !wasInvalidated($0)
        }
    }

    func status(for sessionID: String) -> ContinuationRecord? {
        records.values.filter { $0.sourceSessionID == sessionID || $0.destinationSessionID == sessionID }
            .max { $0.createdAt < $1.createdAt }
    }

    private func wasInvalidated(_ record: ContinuationRecord) -> Bool {
        let cutoff = max(policyInvalidatedBefore,
                         max(invalidatedBefore[record.sourceSessionID] ?? 0,
                             invalidatedBefore[record.destinationSessionID] ?? 0))
        return record.createdAt.timeIntervalSince1970 <= cutoff
    }

    private func publish(_ record: ContinuationRecord) {
        // Stop/disable is synchronous on MainActor and wins over late DB replies.
        if let local = records[record.id], local.state.isTerminal, local.state != record.state { return }
        records[record.id] = record
    }

    private func queueSnapshot(_ source: AIChatViewModel?) -> QueueSnapshot {
        let queue = source?.promptQueue ?? []
        return QueueSnapshot(ids: queue.map(\.id), texts: queue.map(\.text),
                             unsupported: queue.contains { !$0.attachments.isEmpty || !$0.pastePlan.isEmpty })
    }

    private func checkpoint(_ transcript: [RawMessage], pending: [String]) -> String {
        let texts = transcript.map { row -> (role: String, text: String) in
            let text = row.parts.map { part -> String in
                switch part {
                case .text(let value): return value
                case .toolUse(let tool): return "Tool \(tool.name), id=\(tool.toolUseId). Inspect original arguments and effects before replaying."
                case .toolResult(let result):
                    return "Tool result id=\(result.toolUseId), status=\(result.status ?? (result.success ? "success" : "failed")). Verify the source result before repeating."
                case .mediaRef(let ref): return "Attachment: \(ref.originalFileName ?? ref.id)"
                }
            }.joined(separator: "\n")
            return (row.role.rawValue, text)
        }
        let goal = texts.first { $0.role == "user" && !$0.text.isEmpty }?.text ?? "Read the original user request in the source conversation."
        return ContinuationCheckpoint.build(originalGoal: goal, recent: texts, pending: pending)
    }

    /// Called while the old loop still owns its lease. No restore/start here.
    func stage(source: AIChatViewModel, attemptID: String, failure: ConversationTurnLimitFailure) async {
        guard ContinuationPolicy.isEnabled, source.helperConfig == nil, source.remoteDeviceId == nil,
              !source.turnWasStopped, let sid = source.sessionId, !stoppedSessions.contains(sid) else { return }
        explicitlyReopenedSources.remove(sid)
        stagingSources.insert(sid)
        defer { stagingSources.remove(sid) }
        let epoch = epochs[sid]
        let policyVersion = policyEpoch
        func allowed() -> Bool {
            !Task.isCancelled && ContinuationPolicy.isEnabled && policyEpoch == policyVersion && !source.turnWasStopped &&
                !stoppedSessions.contains(sid) && epochs[sid] == epoch
        }
        do {
            let saved = try await ChatStore.shared.continuationRecords(activeOnly: false)
            guard allowed() else { return }
            for record in saved { publish(record) }
            let metadata = try await ChatStore.shared.continuationSourceMetadata(sid)
            guard allowed() else { return }
            let transcript = try await ChatStore.shared.continuationMessages(sessionID: sid)
            guard allowed() else { return }
            let parent = saved.filter { $0.destinationSessionID == sid && !wasInvalidated($0) }.max { $0.createdAt < $1.createdAt }
            let failures = (parent?.consecutiveFailures ?? 0) + 1
            let queue = queueSnapshot(source)
            let reason: String? = queue.unsupported ? "Queued attachments or pasted files require manual handoff; the source queue was preserved." :
                (failures >= ContinuationPolicy.maxConsecutiveFailures ? "Consecutive recovery failure limit reached." : nil)
            let now = Date()
            var draft = ContinuationRecord(id: UUID().uuidString, sourceSessionID: sid,
                attemptID: attemptID, destinationSessionID: UUID().uuidString,
                sourceModelID: source.resolveCurrentEntry()?.model.id ?? metadata.modelID,
                title: "续接 · " + String(metadata.title.prefix(80)), checkpoint: checkpoint(transcript, pending: queue.texts),
                providerStatusCode: failure.statusCode, providerLimit: failure.limit,
                providerMessage: String(ContinuationCheckpoint.redact(failure.message).prefix(4_000)),
                createdAt: now, updatedAt: now, state: reason == nil ? .pending : (queue.unsupported ? .paused : .failed),
                consecutiveFailures: failures, acknowledgedAt: nil, lastError: reason)
            draft.queuedPromptIDs = queue.ids
            let record = try await ChatStore.shared.registerContinuation(draft)
            publish(record)
            stagedInProcess.insert(record.id)
            guard allowed() else {
                await pause(record, reason: "Stopped or changed while saving the handoff.")
                return
            }
            if let parent, !parent.state.isTerminal,
               let updated = try await ChatStore.shared.transitionContinuation(id: parent.id,
                    to: record.state.isTerminal ? .paused : .redirected,
                    error: record.state.isTerminal ? reason : nil) { publish(updated) }
        } catch {
            // Preserve the original provider failure/bubble. No durable outbox
            // receipt means no successor and never a fabricated success.
        }
    }

    /// The release callback is the sole live dispatch trigger. It is scheduled
    /// after release so the old epilogue can finish setting isProcessing=false.
    func sessionReleased(_ sessionID: String) {
        Task { @MainActor in
            for record in Array(self.records.values) where record.sourceSessionID == sessionID && !record.state.isTerminal {
                self.start(record)
            }
            for record in Array(self.records.values) where record.destinationSessionID == sessionID &&
                !record.state.isTerminal && self.dispatchedInProcess.contains(record.id) {
                guard !self.hasPendingHandoff(for: sessionID),
                      let vm = ViewModelCache.shared.get(for: sessionID), !vm.isProcessing else { continue }
                let failed = record.acknowledgedAt == nil || vm.messages.last(where: { $0.role == .assistant })?.error != nil ||
                    vm.errorMessage != nil || vm.canResume || vm.turnWasStopped
                if failed { await self.pause(record, reason: "The successor did not finish normally; inspect it before retrying.") }
                else {
                    do {
                        if let updated = try await ChatStore.shared.transitionContinuation(id: record.id, to: .finished) {
                            self.publish(updated)
                        }
                    } catch { await self.pause(record, reason: "Completion could not be durably confirmed; inspect the successor.") }
                }
            }
        }
    }

    /// An actual provider response (not .sent/.queued) resets the chain counter.
    func providerResponded(in sessionID: String?) async {
        guard let sessionID,
              let record = records.values.first(where: { $0.destinationSessionID == sessionID && !$0.state.isTerminal }),
              dispatchedInProcess.contains(record.id), record.acknowledgedAt == nil else { return }
        do {
            if let updated = try await ChatStore.shared.transitionContinuation(id: record.id, to: .running, acknowledge: true) {
                publish(updated)
            }
        } catch { /* No receipt: leave failure accounting intact. */ }
    }

    func restore() async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let saved = try await ChatStore.shared.continuationRecords(activeOnly: false)
            for record in saved { publish(record) }
            for record in saved where !record.state.isTerminal && workers[record.id] == nil {
                guard !dispatchedInProcess.contains(record.id) else { continue }
                if !ContinuationPolicy.isEnabled || wasInvalidated(record) || stoppedSessions.contains(record.sourceSessionID) || stoppedSessions.contains(record.destinationSessionID) {
                    await pause(record, reason: "Automatic continuation is disabled or was stopped.")
                } else if record.requiresManualReconciliation {
                    await pause(record, reason: RecoveryError.uncertain.localizedDescription)
                } else { start(record) }
            }
        } catch { /* A failed journal read is not an empty/successful restore. */ }
    }

    private func start(_ record: ContinuationRecord) {
        guard ContinuationPolicy.isEnabled, !record.state.isTerminal, records[record.id]?.state.isTerminal != true,
              workers[record.id] == nil, !dispatchedInProcess.contains(record.id), !wasInvalidated(record),
              !stoppedSessions.contains(record.sourceSessionID), !stoppedSessions.contains(record.destinationSessionID),
              !SessionConcurrencyManager.shared.runningSessions.contains(record.sourceSessionID),
              ViewModelCache.shared.get(for: record.sourceSessionID)?.isProcessing != true,
              ViewModelCache.shared.get(for: record.destinationSessionID)?.isProcessing != true else { return }
        let fence = Fence(source: record.sourceSessionID, destination: record.destinationSessionID,
                          sourceEpoch: epochs[record.sourceSessionID], destinationEpoch: epochs[record.destinationSessionID],
                          policyEpoch: policyEpoch)
        workers[record.id] = Task { @MainActor in
            defer { self.workers[record.id] = nil }
            await self.execute(record.id, fence: fence)
        }
    }

    /// Pure MainActor gate, rechecked AFTER every awaited DB/workspace operation.
    private func allowed(_ id: String, fence: Fence) -> Bool {
        !Task.isCancelled && ContinuationPolicy.isEnabled && policyEpoch == fence.policyEpoch && records[id]?.state.isTerminal != true &&
            records[id].map { !wasInvalidated($0) } == true &&
            !stoppedSessions.contains(fence.source) && !stoppedSessions.contains(fence.destination) &&
            epochs[fence.source] == fence.sourceEpoch && epochs[fence.destination] == fence.destinationEpoch &&
            !SessionConcurrencyManager.shared.runningSessions.contains(fence.source) &&
            ViewModelCache.shared.get(for: fence.source)?.isProcessing != true
    }

    private func current(_ id: String, fence: Fence) async throws -> ContinuationRecord? {
        guard allowed(id, fence: fence) else { return nil }
        let record = try await ChatStore.shared.continuationRecord(id: id)
        guard allowed(id, fence: fence), let record, !record.state.isTerminal else { return nil }
        let sourceExists = try await ChatStore.shared.continuationSessionExists(record.sourceSessionID)
        guard allowed(id, fence: fence) else { return nil }
        guard sourceExists else { throw RecoveryError.missingSource }
        if record.state != .pending {
            let destinationExists = try await ChatStore.shared.continuationSessionExists(record.destinationSessionID)
            guard allowed(id, fence: fence) else { return nil }
            guard destinationExists else { throw RecoveryError.missingSource }
        }
        publish(record)
        return record
    }

    private func ready(_ vm: AIChatViewModel, record: ContinuationRecord, fence: Fence) -> Bool {
        allowed(record.id, fence: fence) && !vm.isProcessing && !vm.isCompacting && !vm.isLoadingSession &&
            !vm.isDrainingQueue && !vm.postCompactDrainPending && vm.remoteDeviceId == nil && vm.helperConfig == nil &&
            vm.promptQueue.isEmpty && !vm.turnWasStopped &&
            !SessionConcurrencyManager.shared.runningSessions.contains(record.destinationSessionID) &&
            vm.messages.count == 1 && vm.messages.last?.id.uuidString == record.seedMessageID && vm.messages.last?.role == .user
    }

    private func execute(_ id: String, fence: Fence) async {
        do {
            guard var record = try await current(id, fence: fence) else { return }
            guard !record.requiresManualReconciliation else {
                await pause(record, reason: RecoveryError.uncertain.localizedDescription)
                return
            }
            if record.state == .pending {
                let created = try await ChatStore.shared.createContinuationDestination(recordID: id)
                guard allowed(id, fence: fence) else { return }
                publish(created)
                record = created
            }
            if record.state == .destinationCreated {
                guard try await current(id, fence: fence) != nil else { return }
                _ = try await ContinuationWorkspace.prepare(sourceSessionID: record.sourceSessionID,
                                                           destinationSessionID: record.destinationSessionID)
                guard try await current(id, fence: fence) != nil else { return }
                try await ContinuationSettings.copy(from: record.sourceSessionID, to: record.destinationSessionID)
                guard try await current(id, fence: fence) != nil else { return }
            }
            let transcript = try await ChatStore.shared.continuationMessages(sessionID: record.sourceSessionID)
            guard try await current(id, fence: fence) != nil else { return }
            let (vm, _) = ViewModelCache.shared.getOrCreate(for: record.destinationSessionID)
            guard !vm.isProcessing, !vm.isCompacting, !vm.isLoadingSession else {
                await pause(record, reason: "The destination was taken over; automatic dispatch stopped.")
                return
            }
            for _ in 0..<3 {
                let source = ViewModelCache.shared.get(for: record.sourceSessionID)
                let snapshot = queueSnapshot(source)
                guard !snapshot.unsupported else {
                    await pause(record, reason: "Queued attachments or pasted files require a manual handoff. The queue was not consumed.")
                    return
                }
                // After a restart the original in-memory queue may be gone.
                // Keep its already durable requirements rather than erase them.
                let savedIDs = record.queuedPromptIDs ?? []
                let preserveSavedQueue = (source == nil || !stagedInProcess.contains(id)) && !savedIDs.isEmpty
                let freshPending = zip(snapshot.ids, snapshot.texts).filter { !savedIDs.contains($0.0) }
                let additional = freshPending.map { String(ContinuationCheckpoint.redact($0.1).prefix(12_000)) }.joined(separator: "\n\n")
                let nextCheckpoint = preserveSavedQueue ? record.checkpoint +
                    (additional.isEmpty ? "" : "\n\nADDITIONAL LATEST PENDING USER REQUIREMENTS (highest priority):\n" + additional) :
                    checkpoint(transcript, pending: snapshot.texts)
                let ids = preserveSavedQueue ? savedIDs + freshPending.map { $0.0 } : snapshot.ids
                let receipt = try await ChatStore.shared.prepareContinuationSeed(recordID: id,
                    checkpoint: nextCheckpoint, queuedPromptIDs: ids)
                guard allowed(id, fence: fence) else { return }
                record = receipt.record
                publish(record)
                guard try await current(id, fence: fence) != nil else { return }
                if queueSnapshot(ViewModelCache.shared.get(for: record.sourceSessionID)) != snapshot { continue }
                // The user row is already committed. loadSession is hydration,
                // never an outbox receipt; verify its actual loaded seed below.
                await vm.loadSession()
                guard try await current(id, fence: fence) != nil else { return }
                if queueSnapshot(ViewModelCache.shared.get(for: record.sourceSessionID)) != snapshot { continue }
                guard ready(vm, record: record, fence: fence), vm.agentHistory.count == 1,
                      let entry = vm.agentHistory.first, entry.role == .user, entry.parts.count == 1,
                      case .text(let seed) = entry.parts[0], seed == record.seed else {
                    await pause(record, reason: "The persisted seed could not be safely loaded, or the destination was edited.")
                    return
                }
                // This is the LAST await before submitting. The transaction
                // verifies source, destination and exact sole seed, then records
                // an irreversible dispatch claim. No crash can replay this run.
                let claimed = try await ChatStore.shared.claimContinuationDispatch(recordID: id, expectedSeed: record.seed)
                guard allowed(id, fence: fence) else { return }
                publish(claimed)
                record = claimed
                // Absolutely no await between this gate and the synchronous
                // resume call: resume clears cancellation and is not a Stop gate.
                guard ready(vm, record: record, fence: fence),
                      queueSnapshot(ViewModelCache.shared.get(for: record.sourceSessionID)) == snapshot else {
                    await pause(record, reason: RecoveryError.changedQueue.localizedDescription)
                    return
                }
                vm.sessionSource = "continuation"
                vm.programmaticTurnOrigin = .continuation(recoveryID: id)
                vm.programmaticSilentTurn = true
                vm.resumeUnansweredUserTurn(forContinuation: true)
                guard vm.isProcessing else {
                    await pause(record, reason: "The successor rejected its persisted seed; inspect it before retrying.")
                    return
                }
                dispatchedInProcess.insert(id)
                ViewModelCache.shared.get(for: record.sourceSessionID)?.acceptContinuationHandoff(promptIDs: Set(snapshot.ids))
                return
            }
            await pause(record, reason: RecoveryError.changedQueue.localizedDescription)
        } catch is CancellationError {
            if let record = records[id], !record.state.isTerminal { await pause(record, reason: "Continuation was stopped.") }
        } catch {
            if let record = records[id], !record.state.isTerminal { await pause(record, reason: error.localizedDescription) }
        }
    }

    private func pause(_ record: ContinuationRecord, reason: String) async {
        if let local = records[record.id], local.state.isTerminal && local.state != .paused { return }
        var stopped = record
        stopped.state = .paused
        stopped.lastError = String(ContinuationCheckpoint.redact(reason).prefix(600))
        stopped.updatedAt = Date()
        records[record.id] = stopped
        do {
            if let updated = try await ChatStore.shared.transitionContinuation(id: record.id, to: .paused, error: reason) {
                records[record.id] = updated
            }
        } catch {
            // In-memory pause is NOT a successful persistence receipt. Never
            // restart it in this process; a restored claim will pause again.
            stopped.lastError = "Could not durably pause the journal. " + (stopped.lastError ?? "")
            records[record.id] = stopped
        }
    }

    /// Settings hook: cancellation/local terminal decisions are synchronous,
    /// before any worker can return from await. Journal writes follow in actor.
    func policyChanged() {
        policyEpoch = UUID()
        guard !ContinuationPolicy.isEnabled else { return }
        let disabledAt = Date()
        policyInvalidatedBefore = max(policyInvalidatedBefore, disabledAt.timeIntervalSince1970)
        UserDefaults.standard.set(policyInvalidatedBefore, forKey: "nativeContinuation.policyInvalidatedBefore")
        for task in workers.values { task.cancel() }
        let active = records.values.filter { !$0.state.isTerminal }
        for record in active {
            epochs[record.sourceSessionID] = UUID()
            epochs[record.destinationSessionID] = UUID()
            var stopped = record
            stopped.state = .paused
            stopped.lastError = "Automatic continuation was disabled."
            records[record.id] = stopped
        }
        Task { @MainActor in
            do {
                let saved = try await ChatStore.shared.continuationRecords(activeOnly: true)
                for record in saved where record.createdAt <= disabledAt {
                    if let updated = try await ChatStore.shared.transitionContinuation(id: record.id, to: .paused,
                            error: "Automatic continuation was disabled.") { self.publish(updated) }
                }
            } catch { /* No dispatch on failure; local workers remain cancelled. */ }
            for sid in Set(active.map(\.sourceSessionID)) {
                ViewModelCache.shared.get(for: sid)?.startDrainIfIdle(reason: "continuation-disabled")
            }
        }
    }

    /// Stop follows forward links, including redirected edges, without deleting
    /// either conversation. Persistent stopped IDs fence a crash before DB pause.
    func userStopped(_ sessionID: String) {
        guard !cancelling else { return }
        cancelling = true
        defer { cancelling = false }
        let stoppedAt = Date()
        var queue = [sessionID]
        var visited: Set<String> = []
        while let sid = queue.popLast() {
            guard visited.insert(sid).inserted else { continue }
            stoppedSessions.insert(sid)
            invalidatedBefore[sid] = Date().timeIntervalSince1970
            epochs[sid] = UUID()
            for record in Array(records.values) where record.sourceSessionID == sid || record.destinationSessionID == sid {
                if record.state == .redirected || !record.state.isTerminal { queue.append(record.destinationSessionID) }
                guard !record.state.isTerminal else { continue }
                workers[record.id]?.cancel()
                var stopped = record
                stopped.state = .paused
                stopped.lastError = "Stopped by user or superseded by a new request."
                records[record.id] = stopped
                Task { @MainActor in
                    do {
                        if let updated = try await ChatStore.shared.transitionContinuation(id: record.id, to: .paused,
                                error: stopped.lastError) { self.publish(updated) }
                    } catch { /* Persisted stop fence still prevents restore dispatch. */ }
                }
                if record.destinationSessionID != sessionID {
                    ViewModelCache.shared.get(for: record.destinationSessionID)?.cancel()
                }
            }
        }
        UserDefaults.standard.set(invalidatedBefore, forKey: "nativeContinuation.invalidatedBefore")
        UserDefaults.standard.set(Array(stoppedSessions), forKey: "nativeContinuation.stoppedSessions")
        // Also catches journal rows not yet loaded/in flight in stage().
        Task { @MainActor in
            do {
                for sid in visited {
                    let paused = try await ChatStore.shared.pauseContinuations(forSessionID: sid,
                        reason: "Stopped by user or superseded by a new request.", createdBefore: stoppedAt)
                    for record in paused { self.publish(record) }
                }
            } catch { /* Synchronous epochs and stopped IDs remain fail-closed. */ }
        }
    }

    func userBeganRequest(_ sessionID: String?) {
        guard let sessionID else { return }
        userStopped(sessionID)
        stoppedSessions.remove(sessionID)
        explicitlyReopenedSources.insert(sessionID)
        epochs[sessionID] = UUID()
        UserDefaults.standard.set(Array(stoppedSessions), forKey: "nativeContinuation.stoppedSessions")
    }
}
