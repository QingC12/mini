import Foundation

@main
struct ContinuationStorageIntegrationTests {
    @MainActor static func main() async throws {
        // A lifecycle actor-cycle regression must fail, not hang a macOS job.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            print("FAIL: storage SQL lifecycle suite exceeded 45 seconds (possible actor deadlock)")
            exit(1)
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("continuation-storage-sql-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var checks = 0
        func expect(_ value: Bool, _ name: String) throws {
            guard value else { throw TestFailure.failed(name) }
            checks += 1
            print("PASS: " + name)
        }
        func outcome(_ value: ChatStore.RestoreOutcome) -> String {
            switch value {
            case .inserted: return "inserted"
            case .updated: return "updated"
            case .skippedLocalNewer: return "newer"
            case .skippedNoParent: return "failed"
            }
        }
        func fixture() throws -> (ChatStore, URL, String, String) {
            let base = temp.appendingPathComponent(UUID().uuidString)
            let root = UUID().uuidString, child = UUID().uuidString
            try fm.createDirectory(at: base.appendingPathComponent(root + "/workspace"), withIntermediateDirectories: true)
            try Data("keep-root".utf8).write(to: base.appendingPathComponent(root + "/workspace/keep"))
            return (try ChatStore(base: base), base, root, child)
        }
        func drain(_ base: URL) async {
            // Barrier appends after every notification enqueued by completed SQL.
            // ChatStore itself NEVER waits on this MainActor task.
            let barrier = ContinuationStorageBindings.registry(at: base).enqueueSessionLifecycleNotification {}
            await barrier.value
        }
        let coordinator = ContinuationCoordinator.shared

        // Real SQL row restoration, then adjacent release in ONE actor turn.
        do {
            let (store, base, root, child) = try fixture()
            try await store.insert(root); try await store.insert(child)
            let registry = ContinuationStorageBindings.registry(at: base)
            _ = try registry.bind(source: root, destination: child)
            await store.testDeleteSession(root)
            await drain(base)
            try expect(!(try await store.exists(root)), "source SQL row is actually deleted")
            try expect(coordinator.deleted.contains(root), "committed delete publishes deletion fence")
            try expect(fm.fileExists(atPath: base.appendingPathComponent(child + "/workspace/keep").path), "source deletion retains live successor files")
            _ = try await store.restoreThenRelease(root: root, child: child)
            await drain(base)
            try expect(try await store.exists(root), "restore root row survives adjacent last-successor release")
            try expect(fm.fileExists(atPath: base.appendingPathComponent(root + "/workspace/keep").path), "live root files survive actor restore then release")
            try expect(!coordinator.deleted.contains(root), "successful SQL restore clears only the ID deletion fence")
            try expect(registry.memberIDs(forRoot: root) == [root], "restore revokes stale receipt and persists root ownership")
            await store.testDeleteSession(root)
            await drain(base)
            try expect(!fm.fileExists(atPath: base.appendingPathComponent(root).path), "true final SQL deletion still reclaims restored root")
            await store.close()
        }

        // Real SQL INSERT/UPDATE ABORT and IGNORE failures must not notify or
        // clear a persisted deletion fence. Test both prepare and step failure.
        for operation in ["INSERT", "UPDATE"] {
            for action in ["ABORT, 'intentional failure'", "IGNORE"] {
                let (store, base, root, _) = try fixture()
                if operation == "UPDATE" { try await store.insert(root) }
                coordinator.reset(); coordinator.deleted.insert(root)
                try await store.exec("CREATE TRIGGER fail_restore BEFORE \(operation) ON sessions BEGIN SELECT RAISE(\(action)); END")
                let result = await store.restore(root)
                await drain(base)
                try expect(outcome(result) == "failed", "SQL \(operation) \(action) is not reported as restored")
                try expect(coordinator.events.isEmpty && coordinator.deleted.contains(root), "failed restore does not call sessionRestored or clear fence")
                try expect(!ContinuationStorageBindings.registry(at: base).hasPendingSessionLifecycle(for: [root]), "failed restore releases its SQL lifecycle token")
                try expect(!ContinuationStorageBindings.registry(at: base).registered(root), "failed restore does not invent ownership")
                try await store.exec("DROP TRIGGER fail_restore")
                let success = await store.restore(root)
                await drain(base)
                try expect(outcome(success) == (operation == "UPDATE" ? "updated" : "inserted"), "real SQL recovery succeeds after removing trigger")
                try expect(coordinator.events == ["restore:" + root] && !coordinator.deleted.contains(root), "only successful restore notifies exactly once")
                let skipped = await store.restore(root, updated: 1)
                await drain(base)
                try expect(outcome(skipped) == "newer" && coordinator.events.count == 1, "LWW skip does not revive VM or emit extra restore callback")
                try expect(!ContinuationStorageBindings.registry(at: base).hasPendingSessionLifecycle(for: [root]), "LWW skip releases its lifecycle token")
                await store.close()
            }
        }
        do {
            let (store, base, root, _) = try fixture()
            coordinator.reset(); coordinator.deleted.insert(root)
            try await store.exec("DROP TABLE sessions")
            try expect(outcome(await store.restore(root)) == "failed", "restore prepare failure is not a successful insert")
            await drain(base)
            try expect(coordinator.events.isEmpty && coordinator.deleted.contains(root), "prepare failure preserves deletion fence")
            try expect(!ContinuationStorageBindings.registry(at: base).hasPendingSessionLifecycle(for: [root]), "prepare failure releases its lifecycle token")
            var refused = false
            do { _ = try await store.continuationCompleteStorageDeletion(root) } catch { refused = true }
            try expect(refused && fm.fileExists(atPath: base.appendingPathComponent(root + "/workspace/keep").path), "failed live-row query preserves all files")
            await store.close()
        }

        // SQL row failure rolls back preceding child-row and journal work.
        // An enclosing transaction's unrelated work must remain untouched.
        for action in ["ABORT, 'intentional delete failure'", "IGNORE"] {
            let (store, base, root, _) = try fixture()
            try await store.insert(root)
            try await store.exec("INSERT INTO messages VALUES ('m','\(root)'); INSERT INTO compact_markers VALUES ('c','\(root)')")
            try await store.exec("CREATE TRIGGER fail_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(\(action)); END")
            try await store.exec("BEGIN; INSERT INTO deletion_journal VALUES ('outer-transaction')")
            coordinator.reset(); AgentJobRegistry.shared.cancellations = 0
            await store.testDeleteSession(root)
            try expect(try await store.exists(root), "failed DELETE keeps session row")
            try expect(try await store.count("messages") == 1, "failed DELETE rolls back message removal")
            try expect(try await store.count("compact_markers") == 1, "failed DELETE rolls back compact-marker removal")
            try expect(try await store.count("deletion_journal") == 1, "failed DELETE rolls back pause journal, not outer transaction")
            try await store.exec("COMMIT")
            await drain(base)
            try expect(coordinator.events.isEmpty && coordinator.deleted.isEmpty, "SQL DELETE failure emits no sessionDeleted or pre-SQL userStopped")
            try expect(!ContinuationStorageBindings.registry(at: base).hasPendingSessionLifecycle(for: [root]), "failed DELETE releases its lifecycle token after savepoint rollback")
            try expect(AgentJobRegistry.shared.cancellations == 0, "SQL DELETE failure does not cancel live agent jobs")
            try expect(fm.fileExists(atPath: base.appendingPathComponent(root + "/workspace/keep").path), "SQL DELETE failure keeps physical files")
            try await store.exec("DROP TRIGGER fail_delete")
            await store.testDeleteSession(root)
            await drain(base)
            try expect(coordinator.events == ["delete:" + root] && AgentJobRegistry.shared.cancellations == 4, "committed DELETE notifies and hard-stops only once")
            try expect(!fm.fileExists(atPath: base.appendingPathComponent(root).path), "successful unshared deletion reclaims files")
            await store.testDeleteSession(root)
            await drain(base)
            try expect(coordinator.events.count == 1, "zero-row repeated DELETE emits no new lifecycle notification")
            await store.close()
        }

        // MainActor may be busy while actor SQL completes several generations.
        // Explicit barrier forces callbacks to accumulate; no sleeps or guesses.
        for deleteAgain in [false, true] {
            let (store, base, root, _) = try fixture()
            try await store.insert(root)
            coordinator.reset()
            let gate = StorageLifecycleGate()
            let registry = ContinuationStorageBindings.registry(at: base)
            registry.enqueueSessionLifecycleNotification { await gate.wait() }
            await store.deleteRestoreSequence(root, deleteAgain: deleteAgain)
            try expect(coordinator.events.isEmpty, "lifecycle barrier holds callbacks while SQL generations commit")
            try expect(registry.hasPendingSessionLifecycle(for: [root]), "committed but delayed lifecycle retains its admission token")
            await gate.open()
            await drain(base)
            try expect(!registry.hasPendingSessionLifecycle(for: [root]), "all applied lifecycle generations release their independent tokens")
            let expected = ["delete:" + root, "restore:" + root] + (deleteAgain ? ["delete:" + root] : [])
            try expect(coordinator.events == expected, "SQL delete→restore\(deleteAgain ? "→delete" : "") callbacks retain exact order")
            try expect(coordinator.deleted.contains(root) == deleteAgain, "latest committed generation owns final deletion fence")
            try expect(try await store.exists(root) == !deleteAgain, "final SQL row agrees with lifecycle generation")
            try expect(fm.fileExists(atPath: base.appendingPathComponent(root + "/workspace/keep").path) == !deleteAgain, "delayed deletion cleanup uses CURRENT live SQL rows")
            await store.close()
        }
        do {
            let (store, base, root, _) = try fixture()
            coordinator.reset(); coordinator.deleted.insert(root)
            await store.close()
            try expect(outcome(await store.restore(root)) == "failed", "closed SQLite handle cannot report successful restore")
            await drain(base)
            try expect(coordinator.events.isEmpty && coordinator.deleted.contains(root), "closed-store restore leaves fence unchanged")
            try expect(!ContinuationStorageBindings.registry(at: base).hasPendingSessionLifecycle(for: [root]), "closed-store failure releases its lifecycle token")
        }
        print("PASS: \(checks) exact-production ChatStore/SQLite storage boundary checks")
        print("NOTE: Coordinator/UI are call-recording adapters here; real old-VM queue fencing is covered by continuation-stop tests.")
    }
}
