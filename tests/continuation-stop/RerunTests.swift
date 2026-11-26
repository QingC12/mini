import Foundation

extension ContinuationStopTests {
    @MainActor static func seedRerun(_ endpoint: AIChatViewModel) -> (UUID, TestBlock) {
        let user = ChatMessage(role: .user, content: "original request")
        let text = TestBlock(); text.content = "keep prior reasoning"
        let tool = TestBlock(); tool.kind = .tool; tool.toolUseId = UUID().uuidString
        let assistant = ChatMessage(role: .assistant, blocks: [text, tool])
        endpoint.messages = [user, assistant]
        endpoint.agentHistory = [AgentMessage(role: .user, parts: [.text("original request")]),
            AgentMessage(role: .assistant, parts: [.text("keep prior reasoning"),
                .toolUse(id: tool.toolUseId!, name: "test", input: [:])])]
        return (user.id, tool)
    }

    @MainActor static func testRerunDeleteRestore() async throws {
        let id = "rerun-restored"
        try await ChatStore.shared.addSession(id)
        let old = vm(id)
        let (message, tool) = seedRerun(old)
        let file = try attachment()
        defer { try? FileManager.default.removeItem(atPath: file) }
        try await ChatStore.shared.sql("DELETE FROM sessions WHERE id='rerun-restored'")
        ContinuationCoordinator.shared.sessionDeleted(id)
        try await ChatStore.shared.addSession(id)
        ContinuationCoordinator.shared.sessionRestored(id)
        let deletes = RerunIO.deletes
        old.retryFromMessage(message, replacementAttachments: [file])
        old.retryFromToolBlock(blockId: tool.id)
        old.deleteFromMessage(message)
        try await settle()
        try expect(old.starts == 0 && old.historyCuts == 0 && old.messages.count == 2,
                   "restored ID's old VM reran or truncated its history")
        try expect(RerunIO.deletes == deletes && FileManager.default.fileExists(atPath: file),
                   "old deleted VM touched restored SQL rows or replacement attachments")
        let fresh = vm(id)
        let (freshMessage, _) = seedRerun(fresh)
        fresh.retryFromMessage(freshMessage)
        try await settle()
        try expect(fresh.starts == 1 && fresh.historyCuts == 1 && fresh.continuationQueueMayRun,
                   "fresh restored VM's explicit retry could not start")
        try expect(fresh.messages.count == 2 && fresh.messages.first?.id == freshMessage && fresh.resumeTargets.first! == 1,
                   "normal retry did not retain user row and one resumed assistant placeholder")
        let (_, freshTool) = seedRerun(fresh)
        fresh.retryFromToolBlock(blockId: freshTool.id)
        try await settle()
        try expect(fresh.starts == 2 && fresh.messages.count == 2 && fresh.messages[1].blocks.count == 1,
                   "tool-block retry changed its partial-turn preservation semantics")
        try expect(fresh.resumeTargets.last! == 1, "partial tool rerun failed to resume the surviving assistant")
    }

    @MainActor static func testRerunSlotAndKernelFences() async throws {
        let endpoint = vm("rerun-slot-owner")
        let (message, _) = seedRerun(endpoint)
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        endpoint.slotHook = { entered = true; await withCheckedContinuation { release = $0 } }
        endpoint.retryFromMessage(message)
        for _ in 0..<2000 { if entered { break }; await Task.yield() }
        try expect(entered, "real rerun did not reach slot await")
        let old = endpoint.currentTask!
        endpoint.currentTask = nil // generation, not Task cancellation, must win.
        endpoint.cancel(resumeQueuedPrompts: false)
        try expect(ContinuationCoordinator.shared.userBeganRequest(endpoint.sessionId), "slot owner failed explicit reopen")
        endpoint.userDidCancel = false
        endpoint.isProcessing = true
        endpoint.errorMessage = "new owner"
        endpoint.canResume = false
        endpoint.promptQueue = [QueuedPrompt("new owner's queue")]
        let cleanups = endpoint.cancelCleanupCount
        release?.resume(); await old.value
        try expect(!old.isCancelled && endpoint.starts == 0, "uncancelled old rerun crossed slot await into Provider")
        try expect(endpoint.isProcessing && endpoint.errorMessage == "new owner" && !endpoint.canResume && endpoint.promptQueue.count == 1,
                   "old slot task clobbered the new owner's state or drained its queue")
        try expect(endpoint.cancelCleanupCount == cleanups, "old slot task cleaned the new owner's turn")

        let kernel = vm("rerun-kernel-owner")
        let (kernelMessage, _) = seedRerun(kernel)
        kernel.kernelStatus = .booting
        kernel.retryFromMessage(kernelMessage)
        let kernelTask = kernel.currentTask!
        kernel.currentTask = nil
        await Task.yield()
        kernel.cancel(resumeQueuedPrompts: false)
        try expect(ContinuationCoordinator.shared.userBeganRequest(kernel.sessionId), "kernel owner failed reopen")
        kernel.userDidCancel = false; kernel.isProcessing = true; kernel.errorMessage = "new kernel owner"
        kernel.kernelStatus = .failed("old boot failure")
        await kernelTask.value
        try expect(!kernelTask.isCancelled && kernel.starts == 0 && kernel.isProcessing && kernel.errorMessage == "new kernel owner",
                   "stale kernel completion reset new owner or started Provider")
    }

    @MainActor static func testRerunPersistenceAndErrorFences() async throws {
        for deleteOnly in [false, true] {
            let endpoint = vm("rerun-sql-owner-\(deleteOnly)")
            let (message, _) = seedRerun(endpoint)
            var entered = false, returned = false
            var release: CheckedContinuation<Void, Never>?
            RerunIO.deleteHook = {
                entered = true
                await withCheckedContinuation { release = $0 }
                returned = true
            }
            if deleteOnly { endpoint.deleteFromMessage(message) } else { endpoint.retryFromMessage(message) }
            for _ in 0..<2000 { if entered { break }; await Task.yield() }
            try expect(entered, "real retry/delete did not enter SQL await")
            endpoint.cancel(resumeQueuedPrompts: false)
            try expect(ContinuationCoordinator.shared.userBeganRequest(endpoint.sessionId), "SQL owner could not reopen")
            endpoint.isTruncatingForRetry = true; endpoint.userDidCancel = false; endpoint.isProcessing = true
            RerunIO.deleteHook = nil
            release?.resume()
            for _ in 0..<2000 { if returned { break }; await Task.yield() }
            for _ in 0..<50 { await Task.yield() }
            try expect(returned && endpoint.isTruncatingForRetry && endpoint.isProcessing,
                       "old retry/delete SQL completion cleared the new owner's truncation flag")
        }
        for reopen in [false, true] {
            let endpoint = vm("rerun-error-owner-\(reopen)")
            let (message, _) = seedRerun(endpoint)
            var entered = false
            var release: CheckedContinuation<Void, Never>?
            endpoint.loopHook = {
                entered = true
                await withCheckedContinuation { release = $0 }
                throw CancellationError()
            }
            endpoint.retryFromMessage(message)
            for _ in 0..<2000 { if entered { break }; await Task.yield() }
            try expect(entered, "real rerun did not enter Provider await")
            let old = endpoint.currentTask!
            endpoint.currentTask = nil
            endpoint.cancel(resumeQueuedPrompts: false)
            if reopen {
                try expect(ContinuationCoordinator.shared.userBeganRequest(endpoint.sessionId), "error owner could not reopen")
                endpoint.userDidCancel = false; endpoint.isProcessing = true; endpoint.errorMessage = "new live owner"
            }
            let cleanups = endpoint.cancelCleanupCount
            release?.resume(); await old.value
            if reopen {
                try expect(endpoint.isProcessing && endpoint.errorMessage == "new live owner" && endpoint.cancelCleanupCount == cleanups,
                           "old rerun error handler or epilogue clobbered a newer explicit owner")
            } else {
                try expect(endpoint.canResume && !endpoint.userDidCancel && endpoint.cancelCleanupCount == cleanups + 1,
                           "ordinary stopped retry lost its existing interrupted/resume cleanup")
            }
        }

        // A deleted VM can still receive a late Provider completion after the
        // same ID was restored. It must not run persistence-capable cleanup.
        let deletedID = "rerun-deleted-provider-owner"
        try await ChatStore.shared.addSession(deletedID)
        let deleted = vm(deletedID)
        let (deletedMessage, _) = seedRerun(deleted)
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        deleted.loopHook = {
            entered = true
            await withCheckedContinuation { release = $0 }
            throw CancellationError()
        }
        deleted.retryFromMessage(deletedMessage)
        for _ in 0..<2000 { if entered { break }; await Task.yield() }
        try expect(entered, "deleted-VM regression did not reach real rerun Provider await")
        let lateTask = deleted.currentTask!
        deleted.currentTask = nil // Prove the permanent fence, not Task.cancel.
        try await ChatStore.shared.sql("DELETE FROM sessions WHERE id='rerun-deleted-provider-owner'")
        ContinuationCoordinator.shared.sessionDeleted(deletedID)
        try await ChatStore.shared.addSession(deletedID)
        ContinuationCoordinator.shared.sessionRestored(deletedID)
        let restored = vm(deletedID)
        restored.isProcessing = true
        restored.errorMessage = "restored live owner"
        let cleanups = deleted.cancelCleanupCount
        release?.resume()
        await lateTask.value
        try expect(!lateTask.isCancelled && deleted.cancelCleanupCount == cleanups,
                   "deleted old VM performed late persistence-capable stopped cleanup")
        try expect(restored.isProcessing && restored.errorMessage == "restored live owner",
                   "late deleted rerun disturbed the restored owner")
    }
}
