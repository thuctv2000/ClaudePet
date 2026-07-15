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
    /// When the request is for launching a subagent (Task/Agent tool), the card
    /// to show as a running subagent once the user allows it.
    let subagentCard: TaskItem?

    init(id: String, toolName: String, summary: String?, subagentCard: TaskItem? = nil) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.subagentCard = subagentCard
    }
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
    case background     // a Bash command launched with run_in_background
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
    /// Small caption above the title: "project · #tab", so cards from
    /// different sessions/tabs are tellable apart even in the same project.
    let context: String?
    /// When the work began; subagent/background cards show elapsed time from this.
    let startedAt: Date
    /// Present only for background-task cards: the launcher-assigned id used
    /// to match the completion signal read from the transcript.
    let taskId: String?
    /// Present only for background-task cards: transcript file to tail for
    /// the completion signal.
    let transcriptPath: String?

    init(id: UUID = UUID(), title: String, detail: String? = nil, kind: TaskKind,
         dedupeKey: String? = nil, context: String? = nil, startedAt: Date = Date(),
         taskId: String? = nil, transcriptPath: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.dedupeKey = dedupeKey
        self.context = context
        self.startedAt = startedAt
        self.taskId = taskId
        self.transcriptPath = transcriptPath
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
    /// Running subagents, oldest first. These live outside the capped stack and
    /// stay on screen until their SubagentStop arrives (they survive Stop).
    private(set) var subagentTasks: [TaskItem] = []
    /// Running background Bash commands (`run_in_background: true`), oldest
    /// first. No hook reports their completion, so they stay until a transcript
    /// poll finds the matching `<task-notification>` (see `pollBackgroundTasks`).
    private(set) var backgroundTasks: [TaskItem] = []
    /// Completed notices, newest first. These never auto-hide; the user closes them.
    private(set) var completedNotices: [TaskItem] = []

    /// When true, `/ask` requests are auto-approved without showing a dialog.
    var autoAllow = false

    /// Timestamp of the last hook event received on any route (`/event`,
    /// `/ask`, `/question`). Used by the Diagnostics tab to show "last seen"
    /// and to detect a silently broken hook pipeline (`pet-hook.sh` always
    /// exits 0, so Claude Code never surfaces a connection failure itself).
    private(set) var lastEventAt: Date?

    /// Most recent error the app noticed (hook install failure, server start
    /// failure, failed connectivity test…). Deliberately just the latest
    /// message, not a history — the Diagnostics tab only needs "what broke
    /// most recently", and `events.log` already has the full trail.
    private(set) var lastErrorMessage: String?

    /// Records the latest error for display in the Diagnostics tab.
    func recordError(_ message: String) {
        lastErrorMessage = message
    }

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

    /// Byte offset already scanned in each transcript being tailed for
    /// background-task completion signals (see `pollBackgroundTasks`).
    private var backgroundOffsets: [String: UInt64] = [:]
    /// Repeats while `backgroundTasks` is non-empty; nil otherwise.
    private var backgroundPollTask: Task<Void, Never>?

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

    /// Tracks a newly launched subagent. Its card lives outside the capped
    /// running stack: it is never trimmed and survives Stop, so the user always
    /// sees a subagent that is still working.
    func startSubagent(_ item: TaskItem) {
        subagentTasks.append(item)
        updatePassthrough()
        persistInFlightSubagents()
    }

    /// Manual close of a subagent card (safety valve for a missed SubagentStop).
    func dismissSubagent(id: UUID) {
        subagentTasks.removeAll { $0.id == id }
        updatePassthrough()
        persistInFlightSubagents()
    }

    /// Removes the oldest still-running subagent card (FIFO — PreToolUse for
    /// Task carries no `agent_id` to match on). Returns it for the completion
    /// notice.
    @discardableResult
    private func finishOldestSubagent() -> TaskItem? {
        guard !subagentTasks.isEmpty else { return nil }
        let item = subagentTasks.removeFirst()
        updatePassthrough()
        persistInFlightSubagents()
        return item
    }

    // MARK: - Subagent recovery across restarts

    /// A subagent card durably written to disk so it can be redrawn if the pet
    /// restarts while the subagent is still running (app update, crash, or a
    /// manual restart like during development). Deliberately independent of
    /// Claude Code's own transcript file format — this is the pet's own record
    /// of what it last showed, so recovery never breaks if that format changes.
    private struct PersistedSubagent: Codable {
        let title: String
        let detail: String?
        let context: String?
        let startedAt: Date
    }

    private static var inFlightSubagentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".petmacos/inflight_subagents.json")
    }

    /// Rewrites the durable record to match the current `subagentTasks`. Called
    /// after every add/remove so the file never lags behind what's on screen.
    private func persistInFlightSubagents() {
        let records = subagentTasks.map {
            PersistedSubagent(title: $0.title, detail: $0.detail, context: $0.context, startedAt: $0.startedAt)
        }
        let data = (try? JSONEncoder().encode(records)) ?? Data()
        try? data.write(to: Self.inFlightSubagentsURL)
    }

    /// Called once at launch. Only records started within the last 10 minutes
    /// are recovered — anything older is far more likely to have already
    /// finished (with its `SubagentStop` simply missed while the pet was
    /// offline) than to still be running, and showing a stale "still running"
    /// card would be actively misleading. Recovered cards are tagged "khôi
    /// phục" so they're visually distinguishable from freshly-launched ones.
    func recoverInFlightSubagents() {
        guard let data = try? Data(contentsOf: Self.inFlightSubagentsURL),
              let records = try? JSONDecoder().decode([PersistedSubagent].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for record in records where record.startedAt > cutoff {
            let context = [record.context, "khôi phục"].compactMap { $0 }.joined(separator: " · ")
            subagentTasks.append(TaskItem(
                title: record.title, detail: record.detail, kind: .subagent,
                context: context, startedAt: record.startedAt
            ))
        }
        if !subagentTasks.isEmpty { updatePassthrough() }
        persistInFlightSubagents() // drop any expired entries from the file too
    }

    /// Clears the transient running tasks (e.g. when Claude stops). Running
    /// subagents are left alone — they may still be working in the background.
    private func clearRunning() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        runningTasks.removeAll()
    }

    // MARK: - Background Bash tasks (run_in_background)

    /// Tracks a newly launched background Bash command. No hook reports its
    /// completion, so a transcript-tailing poll loop is (re)started to watch
    /// for the `<task-notification>` block Claude Code writes when it's done.
    private func startBackgroundTask(taskId: String, title: String, detail: String?,
                                      context: String?, transcriptPath: String) {
        guard !backgroundTasks.contains(where: { $0.taskId == taskId }) else { return }
        if backgroundOffsets[transcriptPath] == nil {
            // Skip everything already in the transcript; only new writes matter.
            backgroundOffsets[transcriptPath] = Self.fileSize(path: transcriptPath)
        }
        backgroundTasks.append(TaskItem(
            title: title, detail: detail, kind: .background, context: context,
            taskId: taskId, transcriptPath: transcriptPath
        ))
        updatePassthrough()
        ensureBackgroundPolling()
    }

    /// Manual close of a background-task card (safety valve if the completion
    /// signal is ever missed).
    func dismissBackgroundTask(id: UUID) {
        backgroundTasks.removeAll { $0.id == id }
        updatePassthrough()
    }

    private func ensureBackgroundPolling() {
        guard backgroundPollTask == nil else { return }
        backgroundPollTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if self.backgroundTasks.isEmpty {
                    self.backgroundPollTask = nil
                    return
                }
                self.pollBackgroundTasks()
            }
        }
    }

    /// Reads any new transcript bytes for every transcript a background task
    /// is running under, and retires cards whose id shows up as completed.
    private func pollBackgroundTasks() {
        let paths = Set(backgroundTasks.compactMap(\.transcriptPath))
        for path in paths {
            var offset = backgroundOffsets[path] ?? 0
            let notifications = Self.scanTaskNotifications(path: path, offset: &offset)
            backgroundOffsets[path] = offset
            for note in notifications where note.completed {
                finishBackgroundTask(taskId: note.taskId)
            }
        }
    }

    private func finishBackgroundTask(taskId: String) {
        guard let index = backgroundTasks.firstIndex(where: { $0.taskId == taskId }) else { return }
        let item = backgroundTasks.remove(at: index)
        updatePassthrough()
        pushCompleted(TaskItem(
            title: "Chạy nền xong",
            detail: item.title,
            kind: .done,
            dedupeKey: "bg-\(taskId)",
            context: item.context
        ))
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

    /// Enables click passthrough while notices, subagent/background cards or
    /// an ask are on screen (their manual ✕ must be clickable).
    private func updatePassthrough() {
        onMousePassthroughNeeded?(
            !completedNotices.isEmpty || !subagentTasks.isEmpty
                || !backgroundTasks.isEmpty || pendingAsk != nil)
    }

    /// Shows a short-lived app notice (connection, sprites) as a session card.
    func notify(_ title: String, mood: Mood = .idle) {
        self.mood = mood
        pushRunning(TaskItem(title: title, kind: .session))
    }

    // MARK: - Hook events

    /// Appends one line per received event to ~/.petmacos/events.log so hook
    /// delivery can be debugged (which events arrive, from which agent). The
    /// file is reset once it passes ~1MB so it never grows unbounded.
    private func logEvent(_ event: HookEvent, route: String) {
        lastEventAt = Date()
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(route) \(event.hookEventName ?? "?")"
            + " tool=\(event.toolName ?? "-")"
            + " agent=\(event.agentId ?? "-")/\(event.agentType ?? "-")"
            + " cwd=\(event.projectName ?? "-")\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".petmacos/events.log")
        let maxLogSize: UInt64 = 1_000_000
        if Self.fileSize(path: url.path) > maxLogSize {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Small caption shown above a card: "project · #tab", where the tab tag
    /// is a stable prefix of the session id — enough to tell apart subagents
    /// or background tasks launched from different Claude Code tabs, even
    /// when they share the same project folder.
    private func contextLabel(for event: HookEvent) -> String? {
        let parts = [event.projectName, event.sessionTag.map { "#\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Applies an incoming hook event to the pet's presentation.
    func apply(_ event: HookEvent) {
        logEvent(event, route: "event")
        let context = contextLabel(for: event)
        switch event.hookEventName ?? "" {
        case "UserPromptSubmit":
            mood = .thinking
            pushRunning(TaskItem(title: "Đang suy nghĩ…", kind: .thinking, context: context))
        case "PreToolUse":
            // Reached here only in auto mode (manual mode blocks via /ask).
            mood = .working
            // Tools running inside a subagent are internal noise; the parent
            // subagent card already represents the work.
            if event.isFromSubagent { return }
            if event.toolName == "Task" || event.toolName == "Agent" {
                // A subagent is starting: keep its card until SubagentStop.
                startSubagent(subagentCard(for: event))
            } else {
                pushRunning(TaskItem(
                    title: event.intentTitle,
                    detail: event.intentDetail.map { truncate($0) },
                    kind: .tool,
                    context: context
                ))
            }
        case "PostToolUse":
            // A tool finished. Cards live out their TTL; we only refresh mood.
            // Task/Agent returning does NOT mean the subagent finished (async
            // agents return immediately) — removal happens on SubagentStop.
            mood = .working
            if event.isFromSubagent { return }
            // A Bash call launched with run_in_background: true has no hook
            // that reports when it finishes, so track it separately and tail
            // the transcript for its completion signal.
            if let launch = event.backgroundLaunch, let path = event.transcriptPath {
                startBackgroundTask(
                    taskId: launch.taskId,
                    title: "Chạy nền: \(event.intentTitle)",
                    detail: event.intentDetail.map { truncate($0) },
                    context: context,
                    transcriptPath: path
                )
            }
        case "Notification":
            mood = .asking
            pushRunning(TaskItem(title: event.message ?? "Claude cần chú ý",
                                 kind: .notification, context: context))
        case "Stop":
            // Subagents/background tasks may still be working; keep their
            // cards and stay in "working" mood while any remain.
            mood = (subagentTasks.isEmpty && backgroundTasks.isEmpty) ? .talking : .working
            clearRunning()
            pushStopNotice(for: event)
        case "SubagentStop":
            mood = subagentTasks.count > 1 ? .working : .talking
            let card = finishOldestSubagent()
            let title = event.agentType.map { "Subagent \($0) hoàn thành" }
                ?? "Subagent hoàn thành"
            // Fall back to the launch card's purpose when the stop event carries
            // no final message, so the notice still says what the work was.
            let detail = event.lastAssistantMessage.map { truncate($0, limit: 800) }
                ?? card?.title
            pushCompleted(TaskItem(
                title: title,
                detail: detail,
                kind: .done,
                dedupeKey: "subagent-\(event.agentId ?? UUID().uuidString)",
                context: context
            ))
        case "SessionStart":
            // No card: with hooks installed globally, this fires for every
            // Claude Code session on the machine (other projects, automated
            // routines...), not just the one the user is watching — a card
            // here reads as noise. Only the mood/sprite reacts.
            mood = .idle
        case "SessionEnd":
            // Hooks are installed globally, so this fires for every Claude
            // Code session on the machine — NOT just the one the pet is
            // watching. Only the transient running-task stack is cleared;
            // subagents belonging to other still-active sessions must not be
            // wiped just because an unrelated session ended. Each subagent
            // card is only removed by its own SubagentStop, a manual dismiss,
            // or expiring after a restart (see recoverInFlightSubagents).
            mood = .sleep
            clearRunning()
        default:
            if let message = event.message {
                pushRunning(TaskItem(title: message, kind: .session, context: context))
            }
        }
    }

    /// Builds the persistent running card for a Task/Agent launch.
    private func subagentCard(for event: HookEvent) -> TaskItem {
        TaskItem(
            title: event.intentTitle,
            detail: event.intentDetail.map { truncate($0) },
            kind: .subagent,
            context: contextLabel(for: event)
        )
    }

    /// Pushes the "Hoàn thành" notice for a Stop event, enriching its context
    /// line with the conversation title read from the transcript when possible.
    private func pushStopNotice(for event: HookEvent) {
        let key = "stop-\(event.sessionId ?? "s")"
        let baseContext = contextLabel(for: event)
        let path = event.transcriptPath

        func push(_ text: String?, context: String?) {
            pushCompleted(TaskItem(
                title: "Hoàn thành",
                detail: truncate(text ?? "Claude đã trả lời", limit: 800),
                kind: .done,
                dedupeKey: key,
                context: context
            ))
        }

        guard let path else {
            push(event.lastAssistantMessage, context: baseContext)
            return
        }
        // Read the transcript off the main actor: the last reply (when the hook
        // didn't include one) and the conversation title Claude Code saved.
        let known = event.lastAssistantMessage
        Task {
            let (reply, title) = await Task.detached {
                (known ?? Self.lastAssistantText(path: path),
                 Self.conversationTitle(path: path))
            }.value
            let context = [baseContext, title].compactMap { $0 }.joined(separator: " · ")
            push(reply, context: context.isEmpty ? nil : context)
        }
    }

    // MARK: - Permission requests (blocking)

    /// Presents a permission request, or auto-approves it when paused.
    func presentAsk(id: String, event: HookEvent) {
        logEvent(event, route: "ask")
        // Launching a subagent? Remember its card so an "allow" can start
        // tracking it (in manual mode no separate PreToolUse /event arrives).
        let isSubagent = event.toolName == "Task" || event.toolName == "Agent"
        let card = isSubagent ? subagentCard(for: event) : nil
        if autoAllow {
            if let card { startSubagent(card) }
            resolver?.resolveAsk(id: id, decision: PetDecision(decision: "allow", text: nil))
            return
        }
        mood = .asking
        pendingAsk = PendingAsk(
            id: id,
            toolName: event.toolName ?? "Tool",
            summary: event.toolInputSummary.map { truncate($0) },
            subagentCard: card
        )
        onInteractiveNeeded?(true)
    }

    /// Sends the user's decision back to the waiting hook and clears the dialog.
    func resolve(_ decision: String, text: String? = nil) {
        guard let ask = pendingAsk else { return }
        resolver?.resolveAsk(id: ask.id, decision: PetDecision(decision: decision, text: text))
        if decision == "allow", let card = ask.subagentCard {
            startSubagent(card)
        }
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
        logEvent(event, route: "question")
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

    // MARK: - Connection health heuristic

    /// True when hooks are installed but no event has arrived for longer than
    /// `threshold`, which is the only signal the app has for a silently broken
    /// pipeline (`pet-hook.sh` intentionally exits 0 on every failure so it
    /// never blocks Claude Code). Deliberately simple: it only fires once we
    /// have actually seen an event before, so a fresh install that just
    /// hasn't been used yet does not read as broken.
    func isConnectionStale(hooksInstalled: Bool, threshold: TimeInterval = 600, now: Date = Date()) -> Bool {
        guard hooksInstalled, let lastEventAt else { return false }
        return now.timeIntervalSince(lastEventAt) > threshold
    }

    // MARK: - Debug introspection (automated tests only)

    struct DebugCard: Codable {
        let title: String
        let detail: String?
        let kind: String
        let context: String?
    }

    struct DebugSnapshot: Codable {
        let mood: String
        let runningTasks: [DebugCard]
        let subagentTasks: [DebugCard]
        let backgroundTasks: [DebugCard]
        let completedNotices: [DebugCard]
        let hasPendingAsk: Bool
        let hasPendingQuestion: Bool
    }

    /// Read-only state snapshot for `GET /debug/state`, used by automated
    /// tests that can't see this accessory app's panel via computer-use.
    func debugSnapshot() -> DebugSnapshot {
        func card(_ item: TaskItem) -> DebugCard {
            DebugCard(title: item.title, detail: item.detail,
                      kind: String(describing: item.kind), context: item.context)
        }
        return DebugSnapshot(
            mood: String(describing: mood),
            runningTasks: runningTasks.map(card),
            subagentTasks: subagentTasks.map(card),
            backgroundTasks: backgroundTasks.map(card),
            completedNotices: completedNotices.map(card),
            hasPendingAsk: pendingAsk != nil,
            hasPendingQuestion: pendingQuestion != nil
        )
    }

    /// Returns the conversation title Claude Code stored in the transcript
    /// (the newest `"type":"summary"` line), or nil when none exists yet.
    /// Runs off the main actor.
    nonisolated static func conversationTitle(path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "summary",
                  let summary = object["summary"] as? String,
                  !summary.isEmpty
            else { continue }
            return summary
        }
        return nil
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

    /// Size in bytes of the file at `path`, or 0 if it doesn't exist / can't
    /// be read. Runs off the main actor.
    nonisolated static func fileSize(path: String) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }

    /// Incrementally scans a transcript for `<task-notification>` blocks
    /// written after `offset`, advancing `offset` past the last *complete*
    /// block found. An incomplete trailing block (still being written) is left
    /// for the next poll rather than dropped. Runs off the main actor.
    nonisolated static func scanTaskNotifications(
        path: String, offset: inout UInt64
    ) -> [(taskId: String, completed: Bool)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        guard let lastClose = text.range(of: "</task-notification>", options: .backwards) else {
            return [] // no complete block yet; retry from the same offset next time
        }
        let consumed = text[text.startIndex..<lastClose.upperBound]
        offset += UInt64(consumed.utf8.count)

        var results: [(String, Bool)] = []
        var cursor = consumed.startIndex
        while let openRange = consumed.range(of: "<task-notification>", range: cursor..<consumed.endIndex) {
            let closeRange = consumed.range(
                of: "</task-notification>", range: openRange.upperBound..<consumed.endIndex)
            let blockEnd = closeRange?.lowerBound ?? consumed.endIndex
            let block = consumed[openRange.upperBound..<blockEnd]
            if let idOpen = block.range(of: "<task-id>"),
               let idClose = block.range(of: "</task-id>", range: idOpen.upperBound..<block.endIndex) {
                let taskId = String(block[idOpen.upperBound..<idClose.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let completed = block.contains("<status>completed</status>")
                results.append((taskId, completed))
            }
            cursor = closeRange?.upperBound ?? consumed.endIndex
        }
        return results
    }
}
