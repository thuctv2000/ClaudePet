import Foundation
import Observation

/// Something that can resolve a blocking `/ask` or `/question` request
/// (implemented by `HookServer`).
protocol AskResolver: AnyObject, Sendable {
    func resolveAsk(id: String, decision: PetDecision)
    /// Resolves an `AskUserQuestion` request. `answers` is keyed by question
    /// text; `nil` means the user skipped, so the server returns an empty body
    /// and Claude Code asks in the terminal instead.
    func resolveQuestion(id: String, answers: [String: PetAnswer]?)
}

/// A pending permission request awaiting the user's Allow/Deny on the pet.
struct PendingAsk: Identifiable, Equatable {
    let id: String
    let toolName: String
    let summary: String?
}

/// A pending `AskUserQuestion` awaiting the user's answers on the pet.
struct PendingQuestion: Identifiable, Equatable {
    let id: String
    let questions: [PetQuestion]
}

/// Category of a task card, used to pick its border colour.
enum TaskKind: Equatable {
    case thinking       // Claude is reasoning (UserPromptSubmit)
    case tool           // a tool is running (PreToolUse, auto mode)
    case notification   // Claude needs attention (Notification)
    case session        // session lifecycle / app notices
    case done           // a completed result (gradient border)
    case subagent       // a running subagent (Task/Agent tool)
}

/// One card in the task stack.
struct TaskItem: Identifiable, Equatable {
    let id: UUID
    let title: String       // no emoji / icons
    let detail: String?     // e.g. tool input summary, already truncated
    let kind: TaskKind
    /// Groups notices that should replace one another (e.g. the "Hoàn thành"
    /// result of a session). A new notice removes any existing one sharing key.
    let dedupeKey: String?

    init(id: UUID = UUID(), title: String, detail: String? = nil, kind: TaskKind,
         dedupeKey: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.dedupeKey = dedupeKey
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
    private(set) var pendingQuestion: PendingQuestion?

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

    /// FIFO list of running subagent card ids, so a Post/SubagentStop can drop
    /// the oldest one (PreToolUse for Task carries no `agent_id` to match on).
    private var subagentCards: [UUID] = []

    // MARK: - Task stack

    /// Inserts a running task at the top, trims to 3, and schedules its expiry
    /// (subagent cards persist until their subagent stops, so pass `expires:
    /// false` for them).
    func pushRunning(_ item: TaskItem, expires: Bool = true) {
        runningTasks.insert(item, at: 0)
        while runningTasks.count > maxRunning {
            let dropped = runningTasks.removeLast()
            expiryTasks.removeValue(forKey: dropped.id)?.cancel()
            subagentCards.removeAll { $0 == dropped.id }
        }
        guard expires else { return }
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
        subagentCards.removeAll { $0 == id }
    }

    /// Removes the oldest still-running subagent card (FIFO). Used when a
    /// subagent finishes (SubagentStop) or its Task tool returns.
    private func finishOldestSubagent() {
        guard let id = subagentCards.first else { return }
        removeRunning(id: id)
    }

    /// Clears every running task (e.g. when Claude stops or the session ends).
    private func clearRunning() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        subagentCards.removeAll()
        runningTasks.removeAll()
    }

    /// Adds a persistent completed notice and enables mouse passthrough. A new
    /// notice replaces any existing notice sharing its `dedupeKey`, so only the
    /// latest result of a group stays on screen.
    func pushCompleted(_ item: TaskItem) {
        if let key = item.dedupeKey {
            completedNotices.removeAll { $0.dedupeKey == key }
        }
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
            // Tools running inside a subagent are internal noise; the parent
            // subagent card already represents the work.
            if event.isFromSubagent { return }
            if event.toolName == "Task" || event.toolName == "Agent" {
                // A subagent is starting: keep its card until SubagentStop.
                let card = TaskItem(
                    title: event.intentTitle,
                    detail: event.intentDetail.map { truncate($0) },
                    kind: .subagent
                )
                subagentCards.append(card.id)
                pushRunning(card, expires: false)
            } else {
                pushRunning(TaskItem(
                    title: event.intentTitle,
                    detail: event.intentDetail.map { truncate($0) },
                    kind: .tool
                ))
            }
        case "PostToolUse":
            // A tool finished. Cards live out their TTL; we only refresh mood.
            mood = .working
            if event.isFromSubagent { return }
            // If SubagentStop didn't already drop the card, retire it now.
            if event.toolName == "Task" || event.toolName == "Agent" {
                finishOldestSubagent()
            }
        case "Notification":
            mood = .asking
            pushRunning(TaskItem(title: event.message ?? "Claude cần chú ý", kind: .notification))
        case "Stop":
            mood = .talking
            clearRunning()
            if let text = event.lastAssistantMessage, !text.isEmpty {
                pushCompleted(TaskItem(
                    title: "Hoàn thành",
                    detail: truncate(text, limit: 800),
                    kind: .done,
                    dedupeKey: "stop"
                ))
            } else if let path = event.transcriptPath {
                Task { await showLastAssistant(path: path) }
            } else {
                pushCompleted(TaskItem(
                    title: "Hoàn thành", detail: "Claude đã trả lời",
                    kind: .done, dedupeKey: "stop"))
            }
        case "SubagentStop":
            mood = .talking
            finishOldestSubagent()
            let title = event.agentType.map { "Subagent \($0) hoàn thành" }
                ?? "Subagent hoàn thành"
            pushCompleted(TaskItem(
                title: title,
                detail: event.lastAssistantMessage.map { truncate($0, limit: 800) },
                kind: .done,
                dedupeKey: "subagent-\(event.agentId ?? UUID().uuidString)"
            ))
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

    // MARK: - Interactive questions (AskUserQuestion, blocking)

    /// Presents an `AskUserQuestion` request. Unlike `/ask`, questions are shown
    /// even when approvals are paused — they genuinely need a human answer.
    func presentQuestion(id: String, event: HookEvent) {
        let questions = event.askQuestions
        guard !questions.isEmpty else {
            // Nothing parseable to ask; let the terminal handle it.
            resolver?.resolveQuestion(id: id, answers: nil)
            return
        }
        mood = .asking
        pendingQuestion = PendingQuestion(id: id, questions: questions)
        onInteractiveNeeded?(true)
    }

    /// Sends the user's answers back to the waiting hook and clears the dialog.
    func resolveQuestion(_ answers: [String: PetAnswer]) {
        guard let question = pendingQuestion else { return }
        resolver?.resolveQuestion(id: question.id, answers: answers)
        pendingQuestion = nil
        mood = .idle
        onInteractiveNeeded?(false)
        updatePassthrough()
    }

    /// User chose to answer in the terminal instead: return an empty body.
    func skipQuestion() {
        guard let question = pendingQuestion else { return }
        cancelQuestion(id: question.id)
    }

    /// Called by the server on timeout, or internally when the user skips.
    func cancelQuestion(id: String) {
        guard pendingQuestion?.id == id else { return }
        resolver?.resolveQuestion(id: id, answers: nil)
        pendingQuestion = nil
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
            detail: truncate(text ?? "Claude đã trả lời", limit: 800),
            kind: .done,
            dedupeKey: "stop"
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
