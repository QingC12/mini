import Foundation

// Only the app/kernel surroundings are doubles. The routing and persistent
// ownership implementations linked by the shell entry are the real sources.
final class AIChatViewModel {
    static let minisPersistentBase = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static let minisOffloadsLinuxDir = "/var/minis/offloads"
    static let minisAttachmentsLinuxDir = "/var/minis/attachments"
    static let minisWorkspaceLinuxDir = "/var/minis/workspace"
    static let minisBrowserLinuxDir = "/var/minis/browser"
}
final class ISHKernel: @unchecked Sendable {
    static let shared = ISHKernel()
    var forward: ((String, UInt64) -> String?)?
    var backward: ((String) -> String?)?
    func installPathTranslateHandler(_ handler: @escaping (String, UInt64) -> String?) { forward = handler }
    func installPathReverseHandler(_ handler: @escaping (String) -> String?) { backward = handler }
}
struct RouterTestFailure: Error { let message: String }
@main struct ContinuationRouterTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw RouterTestFailure(message: "expected base/mode") }
        let base = AIChatViewModel.minisPersistentBase
        let mode = CommandLine.arguments[2]
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let source = UUID().uuidString, destination = UUID().uuidString
        let workspace = base.appendingPathComponent(source).appendingPathComponent("workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let retained = workspace.appendingPathComponent("keep.txt")
        try Data("original".utf8).write(to: retained)
        var assertions = 0
        func check(_ label: String, _ condition: Bool) throws {
            assertions += 1
            guard condition else { throw RouterTestFailure(message: label) }
            print("PASS: \(label)")
        }
        if mode == "corrupt" {
            try Data("not-json".utf8).write(to: base.appendingPathComponent(".continuation-storage-v1.json"))
        } else {
            _ = try ContinuationStorageBindings.registry(at: base).bind(source: source, destination: destination)
        }
        let router = MinisFsRouter.shared
        router.installHook()
        let context = router.context(for: destination)
        try check("destination context is stable", router.context(for: destination) == context && context != 0)
        try check("global bucket retains legacy routing", ISHKernel.shared.forward?("/var/minis/memory/GLOBAL.md", context) == nil)
        try check("prefix lookalike is not a session bucket", ISHKernel.shared.forward?("/var/minis/workspace-other/file", context) == nil)
        try check("zero context retains legacy routing", ISHKernel.shared.forward?("/var/minis/workspace/file", 0) == nil)
        if mode == "normal" {
            for bucket in ["workspace", "offloads", "attachments", "browser"] {
                let expected = base.appendingPathComponent(source).appendingPathComponent(bucket).appendingPathComponent("file").path
                try check("\(bucket) forward routes to shared physical owner", ISHKernel.shared.forward?("/var/minis/\(bucket)/file", context) == expected)
                try check("\(bucket) direct Swift URL uses the same owner", router.hostURL(forGuest: "/var/minis/\(bucket)/file", sid: destination)?.path == expected)
            }
            // No source context was issued yet: this models a restarted app
            // which only reopened the successor, whose F_GETPATH sees owner.
            try check("reverse routing knows owner with successor-only context", ISHKernel.shared.backward?(retained.resolvingSymlinksInPath().path) == "/var/minis/workspace/keep.txt")
            try check("independent sessions retain independent context tokens", router.context(for: source) != context)
            try check("source file contents were not copied or changed", try Data(contentsOf: retained) == Data("original".utf8))
        } else {
            let blocked = "/dev/null/minis-continuation-storage-unavailable"
            for guest in ["/var/minis/workspace/file", "/var/minis/attachments/file", "/var/minis/offloads/../../escape"] {
                try check("corrupt registry returns a non-fallthrough failure path", ISHKernel.shared.forward?(guest, context) == blocked)
                try check("corrupt direct host URL does not guess the session root", router.hostURL(forGuest: guest, sid: destination)?.path == blocked)
            }
            let invalid = URL(fileURLWithPath: blocked)
            var refused = false
            do { try fm.createDirectory(at: invalid, withIntermediateDirectories: true) } catch { refused = true }
            try check("failure path really refuses filesystem writes", refused)
            try check("original files survive failed routing", try Data(contentsOf: retained) == Data("original".utf8))
            try check("no guessed destination directory was created", !fm.fileExists(atPath: base.appendingPathComponent(destination).path))
        }
        print("PASS: \(mode) router scenario, \(assertions) production-code checks")
    }
}
