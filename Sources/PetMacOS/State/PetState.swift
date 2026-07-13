import Foundation
import Observation

/// Something that can resolve a blocking `/ask` request (implemented by `HookServer`).
protocol AskResolver: AnyObject, Sendable {
    func resolveAsk(id: String, decision: PetDecision)
}

/// A pending permission request awaiting the user's Allow/Deny on the pet.
struct PendingAsk: Identifiable, Equatable {
    let id: String
    let toolName: String
    let summary: String?
}

/// Category of a task card, used to pick its border colour.
enum TaskKind: Equatable {
    case thinking       // Claude is reasoning (UserPromptSubmit)
    case tool           // a tool is running (PreToolUse, auto mode)
    case notification   // Claude needs attention (Notification)
    case session        // session lifecycle / app notices
    case done           // a completed result (gradient border)
}

/// One card in the task stack.
struct TaskItem: Identifiable, Equatable {
    let id: UUID
    let title: String       // no emoji / icons
    let detail: String?     // e.g. tool input summary, already truncated
    let kind: TaskKind

    init(id: UUID = UUID(), title: String, detail: String? = nil, kind: TaskKind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

/// Shared, observable state driving the pet's mood, the running-task stack and
/// the completed notices. Owned by `PetAppDelegate` and mutated only on the
/// main actor.
@MainActor
@Observable
final class PetState {
    enum Mood {
        case idle       // nothing happening
        case thinking   // user sent a prompt, Claude is working
        case working    // a tool is running
        case talking    // Claude produced output
        case asking     // waiting for the user to approve something
        case sleep      // session ended

        /// Folder name under ~/.petmacos/sprites/ that plays for this mood.
        var spriteName: String {
            switch self {
            case .idle: return "idle"
            case .thinking: return "thinking"
            case .working: return "working"
            case .talking: return "talking"
            case .asking: return "asking"
            case .sleep: return "sleep"
            }
        }
    }

    private(set) var mood: Mood = .idle
    private(set) var pendingAsk: PendingAsk?

    /// Running tasks, newest first, capped at 3. Each auto-expires after a while.
    private(set) var runningTasks: [TaskItem] = []
    /// Completed notices, newest first. These never auto-hide; the user closes them.
    private(set) var completedNotices: [TaskItem] = []

    /// When true, `/ask` requests are auto-approved without showing a dialog.
    var autoAllow = false

    /// Set by the app delegate to wire the server as the resolver.
    @ObservationIgnored weak var resolver: AskResolver?

    /// Called with `true` when a dialog needs mouse clicks *and* key focus (the
    /// permission dialog), `false` when it is dismissed.
    @ObservationIgnored var onInteractiveNeeded: ((Bool) -> Void)?

    /// Called with `true` when the panel should accept mouse clicks *without*
    /// stealing focus (so the user can close a notice), `false` to go back to
    /// click-through.
    @ObservationIgnored var onMousePassthroughNeeded: ((Bool) -> Void)?

    private let maxRunning = 3
    private let runningTTL: TimeInterval = 8

    /// Per-item auto-expiry tasks for running cards, so they can be cancelled
    /// when the task finishes early or is pushed out of the stack.
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Task stack

    /// Inserts a running task at the top, trims to 3, and schedules its expiry.
    func pushRunning(_ item: TaskItem) {
        runningTasks.insert(item, at: 0)
        while runningTasks.count > maxRunning {
            let dropped = runningTasks.removeLast()
            expiryTasks.removeValue(forKey: dropped.id)?.cancel()
        }
        expiryTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.runningTTL ?? 8))
            guard !Task.isCancelled else { return }
            self?.removeRunning(id: item.id)
        }
    }

    /// Removes a running task (used on expiry or when a tool completes).
    private func removeRunning(id: UUID) {
        runningTasks.removeAll { $0.id == id }
        expiryTasks.removeValue(forKey: id)?.cancel()
    }

    /// Removes the newest running tool card, matching `toolName` when given.
    private func finishTool(named toolName: String?) {
        let index = runningTasks.firstIndex { item in
            item.kind == .tool && (toolName == nil || item.title == toolName)
        }
        if let index {
            let removed = runningTasks.remove(at: index)
            expiryTasks.removeValue(forKey: removed.id)?.cancel()
        }
    }

    /// Clears every running task (e.g. when Claude stops or the session ends).
    private func clearRunning() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        runningTasks.removeAll()
    }

    /// Adds a persistent completed notice and enables mouse passthrough.
    func pushCompleted(_ item: TaskItem) {
        completedNotices.insert(item, at: 0)
        updatePassthrough()
    }

    /// Dismisses a completed notice from the close button.
    func dismissNotice(id: UUID) {
        completedNotices.removeAll { $0.id == id }
        updatePassthrough()
    }

    /// Enables click passthrough while notices or an ask are on screen.
    private func updatePassthrough() {
        onMousePassthroughNeeded?(!completedNotices.isEmpty || pendingAsk != nil)
    }

    /// Shows a short-lived app notice (connection, sprites) as a session card.
    func notify(_ title: String, mood: Mood = .idle) {
        self.mood = mood
        pushRunning(TaskItem(title: title, kind: .session))
    }

    // MARK: - Hook events

    /// Applies an incoming hook event to the pet's presentation.
    func apply(_ event: HookEvent) {
        switch event.hookEventName ?? "" {
        case "UserPromptSubmit":
            mood = .thinking
            pushRunning(TaskItem(title: "Đang suy nghĩ…", kind: .thinking))
        case "PreToolUse":
            // Reached here only in auto mode (manual mode blocks via /ask).
            mood = .working
            pushRunning(TaskItem(
                title: event.toolName ?? "Tool",
                detail: event.toolInputSummary.map { truncate($0) },
                kind: .tool
            ))
        case "PostToolUse":
            // A tool finished: drop its running card, no separate notice.
            mood = .working
            finishTool(named: event.toolName)
        case "Notification":
            mood = .asking
            pushRunning(TaskItem(title: event.message ?? "Claude cần chú ý", kind: .notification))
        case "Stop":
            mood = .talking
            clearRunning()
            if let path = event.transcriptPath {
                Task { await showLastAssistant(path: path) }
            } else {
                pushCompleted(TaskItem(title: "Hoàn thành", detail: "Claude đã trả lời", kind: .done))
            }
        case "SubagentStop":
            mood = .talking
            pushCompleted(TaskItem(title: "Subagent hoàn thành", kind: .done))
        case "SessionStart":
            mood = .idle
            pushRunning(TaskItem(title: "Bắt đầu phiên mới", kind: .session))
        case "SessionEnd":
            mood = .sleep
            clearRunning()
            pushRunning(TaskItem(title: "Kết thúc phiên", kind: .session))
        default:
            if let message = event.message {
                pushRunning(TaskItem(title: message, kind: .session))
            }
        }
    }

    // MARK: - Permission requests (blocking)

    /// Presents a permission request, or auto-approves it when paused.
    func presentAsk(id: String, event: HookEvent) {
        if autoAllow {
            resolver?.resolveAsk(id: id, decision: PetDecision(decision: "allow", text: nil))
            return
        }
        mood = .asking
        pendingAsk = PendingAsk(
            id: id,
            toolName: event.toolName ?? "Tool",
            summary: event.toolInputSummary.map { truncate($0) }
        )
        onInteractiveNeeded?(true)
    }

    /// Sends the user's decision back to the waiting hook and clears the dialog.
    func resolve(_ decision: String, text: String? = nil) {
        guard let ask = pendingAsk else { return }
        resolver?.resolveAsk(id: ask.id, decision: PetDecision(decision: decision, text: text))
        pendingAsk = nil
        mood = .idle
        onInteractiveNeeded?(false)
        // Keep passthrough on if notices are still visible.
        updatePassthrough()
    }

    /// Called by the server if a request times out or the connection drops.
    func cancelAsk(id: String) {
        guard pendingAsk?.id == id else { return }
        pendingAsk = nil
        mood = .idle
        onInteractiveNeeded?(false)
        updatePassthrough()
    }

    private func truncate(_ text: String, limit: Int = 200) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Reads the transcript off the main actor and shows Claude's last reply
    /// as a persistent completed notice.
    private func showLastAssistant(path: String) async {
        let text = await Task.detached { Self.lastAssistantText(path: path) }.value
        pushCompleted(TaskItem(
            title: "Hoàn thành",
            detail: truncate(text ?? "Claude đã trả lời", limit: 300),
            kind: .done
        ))
    }

    /// Parses a Claude Code JSONL transcript and returns the text of the last
    /// assistant message. Runs off the main actor.
    nonisolated static func lastAssistantText(path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let parts = message["content"] as? [[String: Any]]
            else { continue }

            let texts = parts.compactMap { part -> String? in
                part["type"] as? String == "text" ? part["text"] as? String : nil
            }
            let joined = texts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }
}
