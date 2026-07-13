import Foundation

/// A minimal JSON value used to display arbitrary `tool_input` / `tool_response`
/// payloads without knowing their shape ahead of time.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    /// Convenience lookup for `.object` values, e.g. `toolInput["command"]`.
    subscript(_ key: String) -> JSONValue? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    /// A compact, single-line-ish string suited for a speech bubble.
    var display: String {
        switch self {
        case let .string(value): return value
        case let .number(value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case let .bool(value): return value ? "true" : "false"
        case .null: return "null"
        case let .array(items):
            return items.map(\.display).joined(separator: ", ")
        case let .object(dict):
            return dict.map { "\($0.key): \($0.value.display)" }.joined(separator: ", ")
        }
    }
}

/// Decoded form of the JSON that Claude Code writes to a hook's stdin.
/// Only the fields we care about are modelled; everything else is ignored.
struct HookEvent: Decodable {
    let hookEventName: String?
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let toolName: String?
    let toolInput: JSONValue?
    let toolResponse: JSONValue?
    let message: String?
    let prompt: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResponse = "tool_response"
        case message
        case prompt
    }

    /// Placeholder used when a request body fails to decode.
    static let empty = HookEvent(
        hookEventName: nil, sessionId: nil, transcriptPath: nil, cwd: nil,
        toolName: nil, toolInput: nil, toolResponse: nil, message: nil, prompt: nil)

    /// Best-effort one-line summary of a tool's input for display.
    var toolInputSummary: String? {
        guard let toolInput else { return nil }
        // Prefer the most human-readable field when present.
        for key in ["command", "file_path", "path", "pattern", "url", "description"] {
            if let value = toolInput[key], case let .string(text) = value {
                return text
            }
        }
        let summary = toolInput.display
        return summary.isEmpty ? nil : summary
    }
}

/// Decision the pet sends back for a blocking `/ask` request (Phase 2).
struct PetDecision: Codable {
    let decision: String   // "allow" | "deny"
    let text: String?
}
