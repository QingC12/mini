#!/usr/bin/env swift
// Run: swift src/ios/MinisTests/Standalone/ConversationTurnLimitTests.swift
// Compiles the SHIPPED detector + LLMError + actual OpenAI mapError/mapHTTPError
// methods, not a reimplementation. No app, credentials, network, or 100 turns.
// SSE parsing is tested directly; its three provider call sites are source guards.
import Foundation

let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ path: String) throws -> String {
    try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
}
func check(_ label: String, _ ok: Bool) {
    if !ok { print("FAIL: \(label)"); exit(1) }
}
let provider = try source("Providers/OpenAI/OpenAIProvider.swift")
let agent = try source("Providers/OpenAI/OpenAIAgentProvider.swift")
guard let start = provider.range(of: "    func mapError(_ error: Error) -> LLMError {"),
      let end = provider.range(of: "\n}", options: .backwards), start.lowerBound < end.lowerBound else {
    fatalError("Cannot extract actual OpenAI error mapping methods")
}
let methods = String(provider[start.lowerBound..<end.lowerBound])
check("HTTP detector before generic JSON formatting",
      methods.range(of: "ConversationTurnLimitDetector.fromHTTPError")!.lowerBound
        < methods.range(of: "// Try to extract error message from JSON body")!.lowerBound)
check("SSE detector wired only at three error boundaries",
      agent.components(separatedBy: "ConversationTurnLimitDetector.fromSSEEvent(event)").count - 1 == 3)
for marker in ["if let error = event[\"error\"] as? [String: Any] {", "case \"error\":", "case \"response.failed\":"] {
    check("SSE boundary \(marker)", agent.contains(marker + "\n                            if let failure = ConversationTurnLimitDetector.fromSSEEvent(event) {"))
}

let driver = #"""
import Foundation
var assertions = 0
func check(_ label: String, _ ok: Bool) {
    assertions += 1
    if !ok { print("FAIL: \(label)"); exit(1) }
}
let zh = "当前会话模型已回复 100 轮，达到上限"
let en = "This conversation has reached 100 model turns. Run /compact to continue."
let harness = HTTPErrorHarness()
func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), as: UTF8.self)
}
func expectTurn(_ label: String, _ error: LLMError, status: Int?, limit: Int?, message: String) {
    guard case .conversationTurnLimit(let failure) = error else { check(label, false); return }
    check(label + " status", failure.statusCode == status && error.httpStatusCode == status)
    check(label + " limit", failure.limit == limit)
    check(label + " original error message", failure.message == message)
    check(label + " no retry/fallback/capacity budget", !error.isRetryable && !error.isFallbackable && !error.isServerCapacityTransient)
}
for text in [zh, en] {
    expectTurn("HTTP JSON", harness.mapHTTPError(statusCode: 400, body: json(["error": ["message": text, "code": "invalid_request_error"]])), status: 400, limit: 100, message: text)
    expectTurn("HTTP plain text", harness.mapHTTPError(statusCode: 400, body: text), status: 400, limit: 100, message: text)
}
for count in [1, 7, 80, 150, 1000] {
    let text = "当前会话模型已回复\(count)轮，达到上限。请开启新会话。"
    check("variable Chinese count \(count)", ConversationTurnLimitDetector.classify(statusCode: 400, message: text)?.limit == count)
    check("variable English count \(count)", ConversationTurnLimitDetector.classify(statusCode: nil, message: "This conversation has reached \(count) model turns.")?.limit == count)
}
for status in [nil, 200, 400] as [Int?] {
    check("direct status retained", ConversationTurnLimitDetector.classify(statusCode: status, message: en)?.statusCode == status)
}
let negatives = ["Bad Request", "100", "Maximum context length is 100 tokens", "context_length_exceeded", "Current model has replied 100 times", "This conversation has not reached 100 model turns", "This conversation has reached 100 tokens", "This conversation has reached 100 model turnstiles", "当前会话模型已回复 100 轮", "当前会话模型已回复 0 轮，达到上限", "User quoted: \(en)", "Request was cancelled"]
for text in negatives {
    check("negative message: \(text)", ConversationTurnLimitDetector.classify(statusCode: 400, message: text) == nil)
}
for status in [401, 403, 408, 429, 499, 500, 502, 503, 504, 529] {
    check("status \(status) excluded", ConversationTurnLimitDetector.classify(statusCode: status, message: en) == nil)
    if case .conversationTurnLimit = harness.mapHTTPError(statusCode: status, body: zh) { check("HTTP status exclusion", false) }
}
check("successful HTTP body not scanned", ConversationTurnLimitDetector.fromHTTPError(statusCode: 200, body: zh) == nil)
let compatibleBodies: [[String: Any]] = [
    ["error": zh], ["message": en], ["response": ["error": ["message": zh]]]
]
for body in compatibleBodies {
    check("HTTP compatible error envelope", ConversationTurnLimitDetector.fromHTTPError(statusCode: 400, body: json(body))?.limit == 100)
}
let ordinaryBodies: [[String: Any]] = [
    ["messages": [["role": "user", "content": en]]],
    ["choices": [["message": ["role": "assistant", "content": zh]]]],
    ["error": ["message": "invalid input", "request_body": en]],
    ["error": ["message": en, "code": "context_length_exceeded"]]
]
for body in ordinaryBodies {
    check("JSON output/quoted data not scanned", ConversationTurnLimitDetector.fromHTTPError(statusCode: 400, body: json(body)) == nil)
}
"""#

let sseDriver = #"""
let sseCases: [([String: Any], Int?)] = [
    (["error": ["message": zh, "code": 400]], 400),
    (["type": "error", "message": en, "code": "conversation_turn_limit"], nil),
    (["type": "error", "error": ["message": zh], "status_code": 200], 200),
    (["type": "error", "error": ["message": zh, "code": "400"]], 400),
    (["type": "response.failed", "response": ["status": "failed", "error": ["code": "invalid_request_error", "message": en]]], nil),
    (["type": "response.failed", "response": ["status_code": 400, "error": ["message": en]]], 400)
]
for (event, status) in sseCases {
    guard let failure = ConversationTurnLimitDetector.fromSSEEvent(event) else { check("SSE classified", false); continue }
    expectTurn("SSE failure", .conversationTurnLimit(failure), status: status, limit: 100, message: failure.message)
}
let nonErrors: [[String: Any]] = [
    ["choices": [["delta": ["role": "assistant", "content": en]]]],
    ["role": "user", "content": zh],
    ["role": "tool", "content": en],
    ["type": "response.output_text.delta", "delta": en],
    ["type": "response.completed", "response": ["output_text": en]],
    ["type": "response.output_text.delta", "error": ["message": en]],
    ["type": "response.failed", "response": ["output_text": en]],
    ["type": "error", "code": "conversation_turn_limit", "message": "100"]
]
for event in nonErrors {
    check("chat/user/tool/ordinary events ignored", ConversationTurnLimitDetector.fromSSEEvent(event) == nil)
}
for code in ["context_length_exceeded", "rate_limit_exceeded", "server_error", "cancelled", "request_canceled"] {
    check("explicit unrelated SSE failure family", ConversationTurnLimitDetector.fromSSEEvent(["type": "error", "code": code, "message": en]) == nil)
}
for status in [401, 403, 429, 499, 503] {
    check("SSE unrelated status", ConversationTurnLimitDetector.fromSSEEvent(["error": ["status_code": status, "message": zh]]) == nil)
}
if case .providerError(let message) = harness.mapHTTPError(statusCode: 400, body: json(["error": ["message": "invalid input"]])) {
    check("ordinary 400 unchanged", message == "[400] invalid input")
} else { check("ordinary 400 original category", false) }
for status in [401, 403] {
    if case .invalidAPIKey = harness.mapHTTPError(statusCode: status, body: en) {} else { check("auth unchanged", false) }
}
if case .rateLimited = harness.mapHTTPError(statusCode: 429, body: en) {} else { check("429 unchanged", false) }
let capacity = harness.mapHTTPError(statusCode: 503, body: en)
check("503 original transient policy", capacity.isRetryable && capacity.httpStatusCode == 503 && capacity.isServerCapacityTransient)
let cancellations: [Error] = [CancellationError(), URLError(.cancelled)]
for cancellation in cancellations {
    if case .cancelled = harness.mapError(cancellation) {} else { check("cancellation unchanged", false) }
}
let raw = en + " Credential echo: Bearer fixture-not-a-secret"
let saved = ConversationTurnLimitDetector.classify(statusCode: 400, message: raw)!
expectTurn("mapError preserves structured error", harness.mapError(LLMError.conversationTurnLimit(saved)), status: 400, limit: 100, message: raw)
check("automatic description does not log raw message", !(LLMError.conversationTurnLimit(saved).errorDescription ?? "").contains("fixture-not-a-secret"))
let restored = try JSONDecoder().decode(ConversationTurnLimitFailure.self, from: JSONEncoder().encode(saved))
check("Codable round-trip", restored.message == raw && restored.limit == 100 && restored.statusCode == 400)
let defensive = LLMError.conversationTurnLimit(.init(statusCode: 503, message: en, limit: 100))
check("turn ceiling is never a capacity transient", !defensive.isServerCapacityTransient)
print("PASS: \(assertions) production-code assertions; SSE provider source guards passed")
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-turn-limit-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let main = tmp.appendingPathComponent("main.swift")
try ("import Foundation\nstruct HTTPErrorHarness {\n" + methods + "\n}\n" + driver + "\n" + sseDriver)
    .write(to: main, atomically: true, encoding: .utf8)
func run(_ executable: String, _ args: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let executable = tmp.appendingPathComponent("tests").path
let compile = try run("/usr/bin/env", ["swiftc", main.path,
    iosRoot.appendingPathComponent("Providers/ConversationTurnLimit.swift").path,
    iosRoot.appendingPathComponent("Providers/LLMError.swift").path, "-o", executable])
check("shipped Swift files compile", compile == 0)
check("production-code assertions", try run(executable, []) == 0)
