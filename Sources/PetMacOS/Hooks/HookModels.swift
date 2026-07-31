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
    // Subagent context: present only when a tool runs inside a subagent, or on
    // SubagentStop for the finishing subagent.
    let agentId: String?
    let agentType: String?
    let lastAssistantMessage: String?
    /// `StopFailure`/`SessionEnd` carry a reason. Its exact shape isn't pinned
    /// in the docs (string on `SessionEnd`, possibly structured on failure), so
    /// it is decoded as a permissive `JSONValue` — a wrong guess about the type
    /// would otherwise fail the whole event and drop it. See `failureSummary`.
    let reason: JSONValue?
    /// `StopFailure`'s error descriptor (type may be `rate_limit`, `overloaded`,
    /// `server_error`, …). Same permissive decoding as `reason`.
    let errorInfo: JSONValue?

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
        case agentId = "agent_id"
        case agentType = "agent_type"
        case lastAssistantMessage = "last_assistant_message"
        case reason
        case errorInfo = "error"
    }

    /// Placeholder used when a request body fails to decode.
    static let empty = HookEvent(
        hookEventName: nil, sessionId: nil, transcriptPath: nil, cwd: nil,
        toolName: nil, toolInput: nil, toolResponse: nil, message: nil, prompt: nil,
        agentId: nil, agentType: nil, lastAssistantMessage: nil,
        reason: nil, errorInfo: nil)

    /// Last path component of `cwd` — the project folder the session runs in.
    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Short, stable tag identifying which Claude Code tab/session this event
    /// came from (first 6 chars of the session id). Distinguishes cards from
    /// different sessions even when they share the same project folder.
    var sessionTag: String? {
        guard let sessionId, sessionId.count >= 6 else { return sessionId }
        return String(sessionId.prefix(6))
    }

    /// The launcher-assigned id of a `Bash` call started with
    /// `run_in_background: true`, or nil for any other tool result.
    ///
    /// Claude Code delivers this as a **structured field**:
    ///
    ///     {"stdout":"","stderr":"","interrupted":false,
    ///      "isImage":false,"noOutputExpected":false,
    ///      "backgroundTaskId":"br3g34yld"}
    ///
    /// The "Command running in background with ID: <id>. Output is being
    /// written to: <path>." sentence that this used to parse never appears in
    /// `tool_response` at all — it is the text Claude *reads*, recorded in the
    /// transcript, not what the hook receives. Matching on it meant no
    /// background card was ever created (verified against Claude Code 2.1.205:
    /// the PostToolUse arrived, `backgroundTasks` stayed empty). The string
    /// form is still accepted as a fallback in case an older build sends it.
    var backgroundTaskId: String? {
        guard toolName == "Bash", let toolResponse else { return nil }
        // `run_in_background` is what actually makes a call a background task,
        // and it is the only trustworthy gate. The fallback below scans the
        // flattened `tool_response`, which includes **stdout** — so a perfectly
        // ordinary `grep`/`sed` whose output happens to contain the sentence
        // (this repo's own test suite prints it) used to spawn a phantom
        // background card that nothing could ever retire.
        guard case let .object(input)? = toolInput,
              case let .bool(true)? = input["run_in_background"] else { return nil }
        if case let .object(fields) = toolResponse,
           case let .string(id)? = fields["backgroundTaskId"], !id.isEmpty {
            return id
        }
        let text = toolResponse.display
        guard let idMarker = text.range(of: "background with ID: "),
              let idEnd = text.range(of: ". Output", range: idMarker.upperBound..<text.endIndex)
        else { return nil }
        let id = String(text[idMarker.upperBound..<idEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// True for the two tool hooks. Their `cwd` is the Bash tool's persistent
    /// shell directory, which wanders with every `cd`, so it can't be trusted
    /// to name the session's project — see `PetState.rememberSessionMeta`.
    var isToolEvent: Bool {
        hookEventName == "PreToolUse" || hookEventName == "PostToolUse"
            || hookEventName == "PostToolUseFailure"
    }

    /// Best-effort human string describing why a `StopFailure` happened, pulled
    /// from whichever of `error` / `reason` / `message` the build populated.
    var failureSummary: String? {
        for candidate in [errorInfo, reason] {
            if let text = candidate?.display, !text.isEmpty { return text }
        }
        if let message, !message.isEmpty { return message }
        return nil
    }

    /// True when a `StopFailure` looks like a usage/rate limit or overload
    /// (Claude Code's `rate_limit` / `overloaded` error types), so the pet can
    /// say so rather than showing a generic error.
    var isRateLimited: Bool {
        let haystack = ((failureSummary ?? "") + " " + (message ?? "")).lowercased()
        return haystack.contains("rate") || haystack.contains("limit")
            || haystack.contains("overload")
    }

    /// True when a Pre/PostToolUse event is for a tool running *inside* a
    /// subagent (identified by `agent_id`), as opposed to the main agent.
    var isFromSubagent: Bool {
        agentId != nil && hookEventName != "SubagentStop"
    }

    /// True when a `PostToolUse` event's `tool_response` signals the tool
    /// failed. Checks the structured `is_error` / `isError` boolean Claude
    /// Code sets on failed tool results (the same flag used for MCP tool_result
    /// blocks), rather than string-matching the response text — grepping for
    /// "error" in arbitrary tool output is unreliable (a file can legitimately
    /// contain that word) and would flip the pet's mood on false positives.
    var isToolError: Bool {
        for key in ["is_error", "isError"] {
            if case let .bool(flag)? = toolResponse?[key] { return flag }
        }
        return false
    }

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

    /// Reads a string field from `tool_input`, or nil when absent/non-string.
    private func inputString(_ key: String) -> String? {
        if let value = toolInput?[key], case let .string(text) = value { return text }
        return nil
    }

    /// Last path component of a file path, for compact display.
    private func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// A localized description of *what* the tool is doing, preferred over the
    /// raw tool name so cards read as intent rather than mechanism.
    var intentTitle: String {
        switch toolName {
        case "Bash":
            return inputString("description") ?? tr("Running command")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let path = inputString("file_path") { return String(format: tr("Editing %@"), basename(path)) }
            return tr("Editing file")
        case "Read":
            if let path = inputString("file_path") { return String(format: tr("Reading %@"), basename(path)) }
            return tr("Reading file")
        case "Grep", "Glob":
            return tr("Searching")
        case "WebFetch", "WebSearch":
            return tr("Looking up the web")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "ExitPlanMode":
            return tr("Updating plan")
        case "Task", "Agent":
            let purpose = inputString("description") ?? inputString("subagent_type") ?? tr("running")
            return String(format: tr("Subagent: %@"), purpose)
        default:
            // MCP tools are named "mcp__<server>__<tool>" (e.g.
            // "mcp__computer-use__request_access") — that raw string is noisy
            // on a small card, so show just the tool's own name.
            guard let toolName else { return "Tool" }
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.components(separatedBy: "__")
                if let last = parts.last, !last.isEmpty { return last }
            }
            return toolName
        }
    }

    /// Supporting detail line for `intentTitle` (full path, command, pattern…).
    var intentDetail: String? {
        switch toolName {
        case "Bash":
            return inputString("command")
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
            return inputString("file_path")
        case "Grep", "Glob":
            return inputString("pattern")
        case "WebFetch":
            return inputString("url")
        case "WebSearch":
            return inputString("query")
        case "Task", "Agent":
            return inputString("description") ?? inputString("prompt")
        default:
            return toolInputSummary
        }
    }
}

/// Decision the pet sends back for a blocking `/ask` request. Mirrors what a
/// `PermissionRequest` decision can express, which is only allow or deny --
/// there is no field to carry a reason back to Claude Code.
struct PetDecision: Codable {
    let decision: String   // "allow" | "deny"
}

// MARK: - AskUserQuestion

/// One selectable option in an `AskUserQuestion` question.
struct PetQuestionOption: Equatable, Sendable {
    let label: String
    let description: String?
}

/// A single question from an `AskUserQuestion` tool call.
struct PetQuestion: Equatable, Sendable {
    let question: String
    let header: String?
    let options: [PetQuestionOption]
    let multiSelect: Bool
}

/// The user's answer to one question: a single choice or several (multiSelect).
enum PetAnswer: Equatable, Sendable {
    case single(String)
    case multi([String])
}

extension HookEvent {
    /// Parses `tool_input.questions` for an `AskUserQuestion` PreToolUse event.
    var askQuestions: [PetQuestion] {
        guard let questions = toolInput?["questions"],
              case let .array(items) = questions else { return [] }
        return items.compactMap { item in
            guard case let .string(question)? = item["question"] else { return nil }
            let header: String?
            if case let .string(text)? = item["header"] { header = text } else { header = nil }
            var multiSelect = false
            if case let .bool(flag)? = item["multiSelect"] { multiSelect = flag }
            var options: [PetQuestionOption] = []
            if case let .array(rawOptions)? = item["options"] {
                options = rawOptions.compactMap { option in
                    guard case let .string(label)? = option["label"] else { return nil }
                    let desc: String?
                    if case let .string(text)? = option["description"] { desc = text } else { desc = nil }
                    return PetQuestionOption(label: label, description: desc)
                }
            }
            return PetQuestion(
                question: question, header: header, options: options, multiSelect: multiSelect)
        }
    }
}
