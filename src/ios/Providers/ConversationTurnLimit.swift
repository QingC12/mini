import Foundation

/// A provider rejected further model turns in this conversation. This is not
/// context/token exhaustion, a transient outage, or a reason to change models.
struct ConversationTurnLimitFailure: Codable, Sendable {
    /// nil when an SSE failure did not supply an HTTP status. Never invent 400.
    let statusCode: Int?
    /// The upstream error message only, not the response envelope or headers.
    /// Treat as sensitive: do not interpolate this raw value into logs.
    let message: String
    let limit: Int?
}

/// Call only at trusted provider failure boundaries, never on chat/tool text.
/// JSON is inspected by allow-listed error fields; output/history is not scanned.
enum ConversationTurnLimitDetector {
    static func fromHTTPError(statusCode: Int, body: String) -> ConversationTurnLimitFailure? {
        guard statusCode == 400 else { return nil }
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let object = json as? [String: Any] {
                let error = object["error"] as? [String: Any]
                let responseError = (object["response"] as? [String: Any])?["error"] as? [String: Any]
                if let error = error ?? responseError {
                    return classify(error: error, statusCode: statusCode)
                }
                // Some relays use {"error":"..."} or {"message":"..."}.
                guard let message = (object["error"] as? String) ?? (object["message"] as? String) else { return nil }
                return classify(message: message, code: object["code"] as? String, statusCode: statusCode)
            }
            if let message = json as? String {
                return classify(message: message, code: nil, statusCode: statusCode)
            }
            return nil
        }
        // A non-JSON HTTP error body is itself a trusted error message.
        return classify(message: body, code: nil, statusCode: statusCode)
    }

    /// Supports chat-completions error envelopes, Responses `error`, and
    /// `response.failed`. Explicit non-error event types are always ignored.
    static func fromSSEEvent(_ event: [String: Any]) -> ConversationTurnLimitFailure? {
        let type = event["type"] as? String ?? ""
        let response = event["response"] as? [String: Any]
        let error: [String: Any]
        switch type {
        case "response.failed":
            guard let detail = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any]) else { return nil }
            error = detail
        case "error":
            error = (event["error"] as? [String: Any]) ?? event
        case "", "chat.completion.chunk":
            guard let detail = event["error"] as? [String: Any] else { return nil }
            error = detail
        default:
            return nil
        }

        // A numeric error.code is used as HTTP status by some compatible relays.
        // Prefer explicit status fields; never turn a symbolic code into 400.
        let status = statusCode(in: error) ?? statusCode(in: event)
            ?? response.flatMap { statusCode(in: $0) }
            ?? httpStatus(error["code"]) ?? httpStatus(event["code"])
        guard status == nil || status == 400 || status.map({ (200...299).contains($0) }) == true else { return nil }
        return classify(error: error, statusCode: status)
    }

    private static func statusCode(in object: [String: Any]) -> Int? {
        for key in ["status_code", "statusCode", "http_status", "http_status_code", "status"] {
            if let code = httpStatus(object[key]) { return code }
        }
        return nil
    }

    private static func httpStatus(_ value: Any?) -> Int? {
        let code: Int?
        if let number = value as? Int { code = number }
        else if let text = value as? String { code = Int(text) }
        else { code = nil }
        guard let code, (100...599).contains(code) else { return nil }
        return code
    }

    private static func classify(error: [String: Any], statusCode: Int?) -> ConversationTurnLimitFailure? {
        guard let message = error["message"] as? String else { return nil }
        return classify(message: message, code: error["code"] as? String, statusCode: statusCode)
    }

    private static func classify(message: String, code: String?, statusCode: Int?) -> ConversationTurnLimitFailure? {
        // These explicit failure families retain their existing retry/cancel/
        // context-length behavior, even if the message quotes a turn limit.
        let excludedCodes: Set<String> = [
            "context_length_exceeded", "context_window_exceeded", "max_tokens", "max_output_tokens",
            "rate_limit_exceeded", "rate_limited", "server_error", "cancelled", "canceled",
            "request_cancelled", "request_canceled", "authentication_error", "invalid_api_key"
        ]
        if let code, excludedCodes.contains(code.lowercased()) { return nil }
        return classify(statusCode: statusCode, message: message)
    }

    /// For callers that already extracted a trusted provider error message.
    /// nil is an SSE failure with no stated HTTP status; an explicit successful
    /// transport status is retained rather than misreported as HTTP 400.
    static func classify(statusCode: Int?, message: String) -> ConversationTurnLimitFailure? {
        guard statusCode == nil || statusCode == 400 || statusCode.map({ (200...299).contains($0) }) == true else { return nil }

        // Match a complete failure assertion, not a bare number or a mention of
        // turns. Anchoring to a message/line start avoids matching quoted prose
        // inside unrelated errors. The count is not hard-coded to 100.
        let patterns = [
            #"(?:^|\n)\s*当前会话模型已回复\s*([1-9][0-9]*)\s*轮\s*[,，。;；:：]?\s*(?:已)?达到上限(?=$|[\s。.!！,，;；:：])"#,
            #"(?:^|\n)\s*This conversation has reached\s+([1-9][0-9]*)\s+model turns?\b(?=$|[\s.!])"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let countRange = Range(match.range(at: 1), in: message) else { continue }
            return ConversationTurnLimitFailure(statusCode: statusCode, message: message, limit: Int(message[countRange]))
        }
        return nil
    }
}
