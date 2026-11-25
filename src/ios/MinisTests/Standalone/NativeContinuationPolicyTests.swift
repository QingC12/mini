// Native-continuation settings tests. Compile the ACTUAL production policy:
//   sh tests/run_native_continuation_tests.sh    (from repository root)
// Existing Standalone/macOS runner can also interpret this file; its adapter
// below invokes the same shell entry. No policy is copied or simulated here.
//
// Coverage: opt-in default, live enable/disable/reset, read-only reads, suite
// isolation, cap constant, and config/UI SOURCE wiring (not an iOS UI test).
// Real provider-error classification, duplicate delivery, successor creation,
// manual cancellation and persisted chain counts need coordinator tests; this
// harness intentionally makes no claim that those integration paths passed.
import Foundation

#if NATIVE_CONTINUATION_TEST_EXECUTABLE
@main
struct NativeContinuationPolicyTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("❌ Expected repository root as the only argument")
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures = 0
        var checks = 0
        func check(_ label: String, _ ok: Bool) {
            checks += 1
            if !ok { failures += 1 }
            print("  \(ok ? "✅" : "❌") \(label)")
        }
        func source(_ relativePath: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }

        // Random domains only: do not read or mutate the real app defaults.
        let suite = "org.openminis.tests.native-continuation.\(UUID().uuidString)"
        let otherSuite = suite + ".other"
        guard let defaults = UserDefaults(suiteName: suite),
              let otherDefaults = UserDefaults(suiteName: otherSuite) else {
            print("❌ Cannot create isolated UserDefaults suites")
            exit(1)
        }
        defaults.removePersistentDomain(forName: suite)
        otherDefaults.removePersistentDomain(forName: otherSuite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        let key = ContinuationPolicy.settingsKey

        print("[1] Real policy behavior with disposable settings")
        check("stable config/storage key", key == "chat.autoContinueOnTurnLimit")
        check("opt-in default is false", !ContinuationPolicy.defaultValue)
        check("chain failure cap is three", ContinuationPolicy.maxConsecutiveFailures == 3)
        check("unset setting is disabled", !ContinuationPolicy.isEnabled(in: defaults))
        check("reading unset does not store a default", defaults.object(forKey: key) == nil)
        defaults.set(true, forKey: key)
        check("setting true enables the next decision", ContinuationPolicy.isEnabled(in: defaults))
        check("enabled read preserves stored true", defaults.bool(forKey: key))
        check("another suite stays disabled", !ContinuationPolicy.isEnabled(in: otherDefaults))
        defaults.set(false, forKey: key)
        check("manual disable takes effect without restart", !ContinuationPolicy.isEnabled(in: defaults))
        defaults.set(true, forKey: key)
        check("re-enable is not cached false", ContinuationPolicy.isEnabled(in: defaults))
        defaults.removeObject(forKey: key)
        check("removing setting restores default false", !ContinuationPolicy.isEnabled(in: defaults))
        check("reset read does not recreate setting", defaults.object(forKey: key) == nil)
        defaults.set(1, forKey: key)
        check("bool conversion matches AppStorageBoolField", ContinuationPolicy.isEnabled(in: defaults))
        defaults.set(0, forKey: key)
        check("stored false matches AppStorageBoolField", !ContinuationPolicy.isEnabled(in: defaults))

        print("[2] Source wiring guards (not a compiled UI/config integration test)")
        let policy = try source("src/ios/Agent/Chat/ContinuationPolicy.swift")
        check("live production getter forwards to the tested reader",
              policy.contains("static var isEnabled: Bool {\n        isEnabled(in: .standard)\n    }"))
        let registry = try source("src/ios/Shared/Config/ConfigRegistry+Builtins.swift")
        let marker = "path: \"chat.autoContinueOnTurnLimit\""
        check("config path is registered exactly once", registry.components(separatedBy: marker).count == 2)
        if let start = registry.range(of: marker),
           let end = registry.range(of: "\n        ))", range: start.upperBound..<registry.endIndex) {
            let field = String(registry[start.lowerBound..<end.lowerBound])
            check("registry uses shared storage key", field.contains("userDefaultsKey: ContinuationPolicy.settingsKey"))
            check("registry uses shared opt-in default", field.contains("defaultValue: ContinuationPolicy.defaultValue"))
            check("registry explains real provider errors and no local-count trigger",
                  field.contains("real provider turn-limit error") && field.contains("Never inferred from local message counts"))
            check("registry exposes the explicit user-facing label", field.contains("会话轮次上限后自动新建并续接任务"))
        } else {
            check("registered field body is available", false)
        }
        let settings = try source("src/ios/Views/Settings/AppearanceSettingsView.swift")
        check("UI shares registry key and default",
              settings.contains("@AppStorage(ContinuationPolicy.settingsKey) private var autoContinueOnTurnLimit: Bool = ContinuationPolicy.defaultValue"))
        check("UI includes a manually reversible toggle",
              settings.contains("Toggle(AppLocalized(\"会话轮次上限后自动新建并续接任务\"), isOn: $autoContinueOnTurnLimit)"))
        check("UI explains provider-only trigger and opt-in behavior",
              settings.contains("默认关闭。仅在服务商明确返回会话轮次上限错误时触发，不按消息数量判断"))
        check("UI failure cap references the shared constant",
              settings.contains(#"\(ContinuationPolicy.maxConsecutiveFailures) 次后停止自动续接"#))
        print("\(checks - failures)/\(checks) checks passed; \(failures) failed")
        if failures != 0 {
            throw NSError(domain: "NativeContinuationPolicyTests", code: failures,
                          userInfo: [NSLocalizedDescriptionKey: "\(failures) checks failed"])
        }
        // Return or throw through defer, cleaning both suites even on failure.
    }
}
#else
// Compatibility with `swift NativeContinuationPolicyTests.swift` and the
// repository's Standalone runner. Keep expressions inside an initializer:
// Swift parses inactive branches too when -parse-as-library is requested.
let nativeContinuationStandaloneAdapter: Void = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let runner = Process()
    runner.executableURL = URL(fileURLWithPath: "/bin/sh")
    runner.arguments = [root.appendingPathComponent("tests/run_native_continuation_tests.sh").path]
    do {
        try runner.run()
        runner.waitUntilExit()
        exit(runner.terminationStatus)
    } catch {
        print("❌ Could not launch Swift test entry: \(error)")
        exit(1)
    }
}()
#endif
