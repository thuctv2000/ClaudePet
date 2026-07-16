import Dispatch
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
    /// The `session_id` this ask came from, used to route its mood back to the
    /// right per-session bucket on resolve/cancel (see `PetState.sessions`).
    let sessionId: String?
    /// The conversation's resolved name (via `SessionNameResolver`, falling
    /// back to `#tag`), shown in the dialog so the user knows *which*
    /// conversation they're approving when several are running at once.
    let conversationName: String?

    init(id: String, toolName: String, summary: String?, subagentCard: TaskItem? = nil,
         sessionId: String? = nil, conversationName: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.subagentCard = subagentCard
        self.sessionId = sessionId
        self.conversationName = conversationName
    }
}

/// A pending `AskUserQuestion` awaiting the user's answers on the pet.
struct PendingQuestion: Identifiable, Equatable {
    let id: String
    let questions: [PetQuestion]
    /// The `session_id` this question came from, so resolving/cancelling it
    /// can route its mood back to the right per-session bucket.
    let sessionId: String?

    init(id: String, questions: [PetQuestion], sessionId: String? = nil) {
        self.id = id
        self.questions = questions
        self.sessionId = sessionId
    }
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
    /// A background task that ended in failure/kill, or whose outcome timed
    /// out unseen. Only ever appears on a *completed notice* (never a running
    /// card) so it can get a visually distinct (red) border from `.done` --
    /// see `SessionCardView.borderStyle` in SessionStackView.
    case failed
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
    /// Present only for subagent cards: the `session_id` the launch (PreToolUse
    /// Task/Agent, or an allowed `/ask`) came from. Used to reconcile a
    /// not-yet-identified subagent card with a later `SubagentStart` event that
    /// carries the real `agent_id` -- see `PetState.handleSubagentStart`.
    let sessionId: String?
    /// Present only for subagent cards once claimed by a `SubagentStart` event:
    /// the `agent_id` used to retire the *correct* card on `SubagentStop`,
    /// instead of falling back to oldest-first (FIFO) removal.
    let agentId: String?

    init(id: UUID = UUID(), title: String, detail: String? = nil, kind: TaskKind,
         dedupeKey: String? = nil, context: String? = nil, startedAt: Date = Date(),
         taskId: String? = nil, transcriptPath: String? = nil,
         sessionId: String? = nil, agentId: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.dedupeKey = dedupeKey
        self.context = context
        self.startedAt = startedAt
        self.taskId = taskId
        self.transcriptPath = transcriptPath
        self.sessionId = sessionId
        self.agentId = agentId
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
        case error      // a tool just failed (transient — decays back on its own)

        /// Folder name under ~/.petmacos/sprites/ that plays for this mood.
        var spriteName: String {
            switch self {
            case .idle: return "idle"
            case .thinking: return "thinking"
            case .working: return "working"
            case .talking: return "talking"
            case .asking: return "asking"
            case .sleep: return "sleep"
            case .error: return "error"
            }
        }
    }

    /// The pet's single displayed mood -- the highest-priority mood among all
    /// currently-live sessions (see `sessions`/`recomputeAggregateMood`).
    private(set) var mood: Mood = .idle
    /// FIFO queue of asks awaiting the user's Allow/Deny. Only the first item
    /// is ever shown as a dialog; see `presentAsk`/`resolve`/`cancelAsk`.
    private var askQueue: [PendingAsk] = []
    /// The ask currently shown as a dialog (the head of `askQueue`), if any.
    var pendingAsk: PendingAsk? { askQueue.first }
    /// Number of asks waiting (including the one currently shown). Exposed in
    /// `/debug/state` as `pendingAskCount`.
    var pendingAskCount: Int { askQueue.count }
    private(set) var pendingQuestion: PendingQuestion?

    /// Bumped to a fresh id whenever the "happy" one-shot sprite should play
    /// (a clean `Stop` with no subagent/background work left). `PetView`
    /// observes this and plays the clip once, mirroring the existing
    /// tap-to-react "click" one-shot; if the user has no "happy" frames it is
    /// simply a no-op and the mood's own sprite (talking) keeps playing.
    private(set) var happyID: UUID?

    /// Running tasks, newest first, capped at 3. Each auto-expires after a while.
    private(set) var runningTasks: [TaskItem] = []
    /// Running subagents, oldest first. These live outside the capped stack and
    /// stay on screen until their SubagentStop arrives (they survive Stop).
    private(set) var subagentTasks: [TaskItem] = []
    /// Running background Bash commands (`run_in_background: true`), oldest
    /// first. No hook reports their completion, so they stay until a
    /// filesystem watcher (or the safety-net poll) finds the matching
    /// `<task-notification>` — see `TranscriptWatcher` and `scanTranscript`.
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

    /// Resolves a `session_id` to its conversation's first-prompt name from
    /// `~/.claude/history.jsonl`, used by `contextLabel(for:)` to caption
    /// cards with something meaningful instead of a raw session-id tag. See
    /// `SessionNameResolver` for the read/cache strategy.
    @ObservationIgnored private let sessionNames = SessionNameResolver()

    /// Per-item auto-expiry tasks for running cards, so they can be cancelled
    /// when the task finishes early or is pushed out of the stack.
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Mood (per-session, aggregated)

    /// One live session's own mood, tracked independently so that several
    /// concurrent Claude Code tabs/sessions never stomp on each other's mood
    /// (the old bug: last-writer-wins across sessions). The pet's single
    /// displayed `mood` is the highest-priority mood among all entries here
    /// (see `moodPriority`/`recomputeAggregateMood`).
    private struct SessionActivity {
        var mood: Mood
        var lastEventAt: Date
        /// Pending decay for this session's own transient mood (`.talking`,
        /// `.error`). Cancelled and replaced every time this session's mood is
        /// set, so a stale timer can never fire after a newer event already
        /// moved this session on.
        var decayTask: Task<Void, Never>?
    }

    /// sessionId -> that session's own activity. Events with no `session_id`
    /// (malformed payloads; shouldn't happen in practice) are bucketed under
    /// a synthetic key so they don't get merged with an unrelated real
    /// session. Entries expire (see `sessionTTLSeconds`) or are removed
    /// outright on `SessionEnd`.
    private var sessions: [String: SessionActivity] = [:]
    private static let noSessionKey = "_no-session_"

    /// Display metadata remembered per session key (resolved conversation
    /// name + "#tag" fallback), captured from every event that carries a
    /// `session_id` so the per-session UI card can title itself even for
    /// items whose own `context` caption is missing. Pruned on `SessionEnd`
    /// when no card still references the session (see `pruneMetaIfUnused`).
    private struct SessionMeta {
        var name: String?
        var tag: String?
        var project: String?
    }
    private var sessionMeta: [String: SessionMeta] = [:]

    /// Captures/refreshes the display metadata for the event's session. The
    /// name is re-resolved on every event (cheap: `SessionNameResolver`
    /// caches) so a session whose first prompt lands in `history.jsonl`
    /// *after* its first hook event still picks up its real name later.
    private func rememberSessionMeta(for event: HookEvent) {
        guard let sid = event.sessionId else { return }
        var meta = sessionMeta[sid] ?? SessionMeta()
        if let name = sessionNames.name(for: sid, cwd: event.cwd) { meta.name = name }
        if meta.tag == nil { meta.tag = event.sessionTag }
        if let project = event.projectName { meta.project = project }
        sessionMeta[sid] = meta
    }

    /// Drops a session's remembered metadata once nothing on screen needs it.
    private func pruneMetaIfUnused(sessionId: String?) {
        guard let sid = sessionId else { return }
        let stillReferenced = sessions[sid] != nil
            || runningTasks.contains { $0.sessionId == sid }
            || subagentTasks.contains { $0.sessionId == sid }
            || backgroundTasks.contains { $0.sessionId == sid }
            || completedNotices.contains { $0.sessionId == sid }
        if !stillReferenced { sessionMeta.removeValue(forKey: sid) }
    }

    // MARK: - Per-session UI summaries (one card per conversation)

    /// Everything the per-conversation card UI needs about one session,
    /// derived on the fly from the existing per-kind item lists.
    struct SessionSummary: Identifiable, Equatable {
        /// The session key (`session_id`, or `""` for the app-notice bucket).
        let id: String
        /// Header title: resolved conversation name, else "#tag", else a
        /// generic app label for the no-session bucket.
        let name: String
        /// The project (cwd folder name) this conversation runs in, shown as
        /// a small caption under the name; nil when never seen on an event.
        let project: String?
        /// This session's own mood (drives the card's status icon).
        let mood: Mood
        /// Ordering key: the session's own last hook event (or, for a
        /// session already dropped from the live map, its newest item).
        let lastEventAt: Date
        /// Newest transient running task of this session, if any.
        let latestRunning: TaskItem?
        /// Newest persistent completed notice of this session, if any.
        let latestCompleted: TaskItem?
        /// This session's still-running subagents (oldest first).
        let subagents: [TaskItem]
        /// This session's still-running background Bash tasks (oldest first).
        let backgrounds: [TaskItem]
    }

    /// One card per conversation, ordered so the session with the NEWEST
    /// event sits first ("Latest"). Includes:
    ///  - every live session that is either non-idle or has cards, and
    ///  - any session that still owns cards (subagent finishing after
    ///    SessionEnd, persistent completed notices...) even if it is no
    ///    longer in the live mood map.
    /// A live but completely idle/sleeping session with no cards is skipped —
    /// hooks are installed globally, so `SessionStart`s from unrelated
    /// sessions would otherwise spawn permanent empty cards.
    var orderedSessionSummaries: [SessionSummary] {
        var keys: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            let key = raw ?? Self.noSessionKey
            if seen.insert(key).inserted { keys.append(key) }
        }
        for key in sessions.keys { add(key) }
        for item in runningTasks { add(item.sessionId) }
        for item in subagentTasks { add(item.sessionId) }
        for item in backgroundTasks { add(item.sessionId) }
        for item in completedNotices { add(item.sessionId) }

        var result: [SessionSummary] = []
        for key in keys {
            func mine(_ items: [TaskItem]) -> [TaskItem] {
                items.filter { ($0.sessionId ?? Self.noSessionKey) == key }
            }
            let running = mine(runningTasks)
            let completed = mine(completedNotices)
            let subs = mine(subagentTasks)
            let bgs = mine(backgroundTasks)
            let hasItems = !running.isEmpty || !completed.isEmpty || !subs.isEmpty || !bgs.isEmpty
            let live = sessions[key]
            let mood = live?.mood ?? ((!subs.isEmpty || !bgs.isEmpty) ? .working : .idle)
            // Skip noise: a live session that is idle/asleep with nothing to show.
            if !hasItems, mood == .idle || mood == .sleep { continue }
            let newestItemDate = (running + completed + subs + bgs).map(\.startedAt).max()
            let lastEventAt = live?.lastEventAt ?? newestItemDate ?? .distantPast
            result.append(SessionSummary(
                id: key == Self.noSessionKey ? "" : key,
                name: displayName(forKey: key),
                project: sessionMeta[key]?.project,
                mood: mood,
                lastEventAt: lastEventAt,
                latestRunning: running.first,       // runningTasks is newest-first
                latestCompleted: completed.first,   // completedNotices is newest-first
                subagents: subs,
                backgrounds: bgs
            ))
        }
        return result.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// Header title for one session card: resolved conversation name, else
    /// "#tag", else a short prefix of the raw session id; the no-session
    /// bucket (app notices) gets the app's own name.
    private func displayName(forKey key: String) -> String {
        if key == Self.noSessionKey { return "PetMacOS" }
        if let meta = sessionMeta[key] {
            if let name = meta.name { return name }
            if let tag = meta.tag { return "#\(tag)" }
        }
        return "#\(String(key.prefix(6)))"
    }

    /// asking > error > working > thinking > talking > sleep > idle, per spec.
    /// Lower index = higher priority.
    private static let moodPriority: [Mood] = [.asking, .error, .working, .thinking, .talking, .sleep, .idle]

    /// Recurring sweep that drops sessions which haven't had an event in
    /// `sessionTTLSeconds`. Started lazily on the first session, stopped once
    /// the map is empty (mirrors `backgroundSafetyPollTask`'s lifecycle).
    private var sessionExpiryTask: Task<Void, Never>?

    /// Default decay for `.talking` set by `Stop`/`notify` with no override
    /// (see `talkingDecaySeconds`).
    private static let defaultTalkingDecaySeconds: TimeInterval = 20
    /// Default decay for `.error` (see `errorDecaySeconds`).
    private static let defaultErrorDecaySeconds: TimeInterval = 6
    /// Default session expiry (see `sessionTTLSeconds`).
    private static let defaultSessionTTLMinutes: Double = 30

    /// How long `.talking` lingers before falling back to `.idle`. Read fresh
    /// from the optional `talkingDecaySeconds` field in `~/.petmacos/config.json`
    /// on every use (not just at launch) so automated tests can shorten it on a
    /// *running* app without restarting it — the app itself never writes this
    /// field, only the hook server's port/token, so it's safe for a test to add.
    var talkingDecaySeconds: TimeInterval {
        Self.configOverride(key: "talkingDecaySeconds") ?? Self.defaultTalkingDecaySeconds
    }

    /// How long `.error` lingers before falling back to `.working`/`.idle`.
    /// Same override mechanism as `talkingDecaySeconds`.
    var errorDecaySeconds: TimeInterval {
        Self.configOverride(key: "errorDecaySeconds") ?? Self.defaultErrorDecaySeconds
    }

    /// How long a session may go without an event before it's dropped from
    /// `sessions` (and therefore stops contributing to the mood aggregate).
    /// Same override mechanism, in minutes (`sessionTTLMinutes` in config.json).
    var sessionTTLSeconds: TimeInterval {
        (Self.configOverride(key: "sessionTTLMinutes") ?? Self.defaultSessionTTLMinutes) * 60
    }

    private static func configOverride(key: String) -> TimeInterval? {
        guard let data = try? Data(contentsOf: PetConfig.fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? NSNumber
        else { return nil }
        return value.doubleValue
    }

    /// True while a subagent or background task is still known to be running
    /// (globally, across every session) — used by the `.error` decay fallback
    /// to pick `.working` over `.idle`, and by `Stop` to decide the "happy"
    /// one-shot. Deliberately global, not per-session: a session whose own
    /// work already finished can still correctly decay to "working" if some
    /// *other* session's subagent/background task is still going, matching
    /// the pre-existing single-mood behaviour this replaces (task spec: "xét
    /// theo trạng thái TOÀN CỤC còn lại").
    private var hasActiveWork: Bool { !subagentTasks.isEmpty || !backgroundTasks.isEmpty }

    /// The single place a *session's* mood is ever written. `sessionId` nil is
    /// bucketed under `noSessionKey` (app-level notices via `notify`, or a
    /// malformed event). Cancels any decay timer left over from this session's
    /// previous mood, then — for the transient moods `.talking` and `.error` —
    /// schedules a fresh one scoped to this session, and finally recomputes
    /// the pet's aggregate `mood`.
    private func setMood(_ newMood: Mood, for sessionId: String?) {
        let key = sessionId ?? Self.noSessionKey
        var activity = sessions[key] ?? SessionActivity(mood: .idle, lastEventAt: Date(), decayTask: nil)
        activity.decayTask?.cancel()
        activity.decayTask = nil
        activity.mood = newMood
        activity.lastEventAt = Date()
        switch newMood {
        case .talking:
            activity.decayTask = scheduleSessionDecay(key: key, after: talkingDecaySeconds) { .idle }
        case .error:
            activity.decayTask = scheduleSessionDecay(key: key, after: errorDecaySeconds) { [weak self] in
                (self?.hasActiveWork ?? false) ? .working : .idle
            }
        default:
            break
        }
        sessions[key] = activity
        recomputeAggregateMood()
        ensureSessionExpirySweep()
    }

    private func scheduleSessionDecay(
        key: String, after seconds: TimeInterval, fallback: @escaping () -> Mood
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            guard var activity = self.sessions[key] else { return }
            activity.mood = fallback()
            activity.decayTask = nil
            self.sessions[key] = activity
            self.recomputeAggregateMood()
        }
    }

    /// Recomputes the pet's single displayed `mood` as the highest-priority
    /// mood among all live sessions (asking > error > working > thinking >
    /// talking > sleep > idle), or `.idle` when no session is tracked.
    private func recomputeAggregateMood() {
        var best: Mood?
        for activity in sessions.values {
            guard let currentBestRank = best.flatMap({ Self.moodPriority.firstIndex(of: $0) }) else {
                best = activity.mood
                continue
            }
            if let rank = Self.moodPriority.firstIndex(of: activity.mood), rank < currentBestRank {
                best = activity.mood
            }
        }
        mood = best ?? .idle
    }

    /// Starts (if not already running) a recurring sweep that drops sessions
    /// idle past `sessionTTLSeconds`. The poll interval adapts to the current
    /// TTL (down to 1s) so tests can override `sessionTTLMinutes` to a small
    /// value and see expiry within a reasonable wait, instead of being stuck
    /// with a fixed slow cadence tuned only for the real 30-minute default.
    private func ensureSessionExpirySweep() {
        guard sessionExpiryTask == nil else { return }
        sessionExpiryTask = Task { [weak self] in
            while true {
                guard let self else { return }
                let ttl = self.sessionTTLSeconds
                let interval = max(1.0, min(60.0, ttl / 5))
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                let now = Date()
                let before = self.sessions.count
                let expired = self.sessions.filter {
                    now.timeIntervalSince($0.value.lastEventAt) >= self.sessionTTLSeconds
                }.map(\.key)
                for key in expired { self.sessions.removeValue(forKey: key) }
                // Also release the expired sessions' display metadata --
                // without this, sessions that never send SessionEnd (crashed
                // or abandoned) would accumulate meta entries forever.
                for key in expired { self.pruneMetaIfUnused(sessionId: key) }
                if self.sessions.count != before { self.recomputeAggregateMood() }
                if self.sessions.isEmpty {
                    self.sessionExpiryTask = nil
                    return
                }
            }
        }
    }

    /// Byte offset already scanned in each transcript being tailed for
    /// background-task completion signals (see `scanTranscript`).
    private var backgroundOffsets: [String: UInt64] = [:]
    /// One filesystem watcher per transcript currently being tailed, keyed by
    /// `transcriptPath`. Several background tasks can share one transcript
    /// (e.g. two `run_in_background` Bash calls from the same session), so
    /// this is keyed by path, not by task id.
    private var transcriptWatchers: [String: TranscriptWatcher] = [:]
    /// Slow safety-net poll — repeats while `backgroundTasks` is non-empty;
    /// nil otherwise. See `ensureBackgroundSafetyPoll`.
    private var backgroundSafetyPollTask: Task<Void, Never>?

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

    /// Removes the oldest still-running subagent card (FIFO). This is the
    /// fallback used when a `SubagentStop` carries no `agent_id`, or carries
    /// one we never managed to claim onto a card (see `finishSubagent(agentId:)`
    /// below) -- e.g. an older Claude Code build that predates `SubagentStart`.
    /// Returns the removed card for the completion notice.
    @discardableResult
    private func finishOldestSubagent() -> TaskItem? {
        guard !subagentTasks.isEmpty else { return nil }
        let item = subagentTasks.removeFirst()
        updatePassthrough()
        persistInFlightSubagents()
        return item
    }

    /// Removes the subagent card matching `agentId` if one was claimed for it
    /// (see `handleSubagentStart`); otherwise falls back to FIFO removal. This
    /// is the actual fix for the old bug where `SubagentStop` always retired
    /// the *oldest* subagent regardless of which one truly finished -- now that
    /// `SubagentStart` tags cards with their real `agent_id`, a `SubagentStop`
    /// for a *younger* subagent removes the right card even if an older one is
    /// still running. Returns the removed card, if any.
    @discardableResult
    private func finishSubagent(agentId: String?) -> TaskItem? {
        if let agentId, let index = subagentTasks.firstIndex(where: { $0.agentId == agentId }) {
            let item = subagentTasks.remove(at: index)
            updatePassthrough()
            persistInFlightSubagents()
            return item
        }
        return finishOldestSubagent()
    }

    /// Handles a `SubagentStart` event (agent_id + agent_type; Claude Code
    /// v2.1.177+). Reconciliation trade-off: `PreToolUse` for the `Task`/`Agent`
    /// tool (and the manual "/ask" allow path) already create a subagent card
    /// with a nice human-written title (from `description`), but *no*
    /// `agent_id` -- the subagent hasn't been assigned one yet at that point.
    /// `SubagentStart` arrives moments later with the real `agent_id` but only
    /// `agent_type` (no free-text description) to title a card with. Rather than
    /// show two cards for the same subagent, this "claims" the oldest
    /// still-unclaimed card from the *same session* (FIFO within a session,
    /// since parallel Task launches from one session can't be told apart any
    /// other way) by stamping its `agent_id` on it. Only when no such card
    /// exists (e.g. this Claude Code build sends `SubagentStart` without ever
    /// having sent a matching `PreToolUse` event to us, or the event arrived
    /// out of order) does it fall back to creating a fresh card titled from
    /// `agent_type` alone.
    private func handleSubagentStart(_ event: HookEvent) {
        guard let agentId = event.agentId else { return }
        guard !subagentTasks.contains(where: { $0.agentId == agentId }) else { return } // duplicate event
        if let index = subagentTasks.firstIndex(where: { $0.agentId == nil && $0.sessionId == event.sessionId }) {
            let old = subagentTasks[index]
            subagentTasks[index] = TaskItem(
                id: old.id, title: old.title, detail: old.detail, kind: .subagent,
                dedupeKey: old.dedupeKey, context: old.context, startedAt: old.startedAt,
                sessionId: old.sessionId, agentId: agentId
            )
            persistInFlightSubagents()
            return
        }
        let title = event.agentType.map { "Subagent: \($0)" } ?? "Subagent đang chạy"
        startSubagent(TaskItem(
            title: title, kind: .subagent, context: contextLabel(for: event),
            sessionId: event.sessionId, agentId: agentId
        ))
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
        /// Added alongside SubagentStart/agent_id tracking. Absent in files
        /// written by older builds -- Codable decodes missing Optional keys as
        /// nil automatically, so old on-disk records still load fine.
        let sessionId: String?
        let agentId: String?
    }

    private static var inFlightSubagentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".petmacos/inflight_subagents.json")
    }

    /// Rewrites the durable record to match the current `subagentTasks`. Called
    /// after every add/remove so the file never lags behind what's on screen.
    private func persistInFlightSubagents() {
        let records = subagentTasks.map {
            PersistedSubagent(title: $0.title, detail: $0.detail, context: $0.context,
                              startedAt: $0.startedAt, sessionId: $0.sessionId, agentId: $0.agentId)
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
                context: context, startedAt: record.startedAt,
                sessionId: record.sessionId, agentId: record.agentId
            ))
        }
        if !subagentTasks.isEmpty { updatePassthrough() }
        persistInFlightSubagents() // drop any expired entries from the file too
    }

    /// Clears the transient running tasks belonging to one session (e.g. when
    /// that session's Claude stops). Running subagents are left alone — they
    /// may still be working in the background, regardless of session.
    ///
    /// Scoped to `sessionId` so a `Stop`/`SessionEnd` from session X can never
    /// wipe cards belonging to a *different* still-active session Y (the bug
    /// this replaces: the old global `clearRunning()` nuked every running card
    /// regardless of which session's hook fired). A card with no `sessionId`
    /// at all (e.g. an app-level `notify()` notice) is deliberately left
    /// alone here too — trade-off: such a card can only be tied to *a*
    /// session by guessing, so instead it's left to expire via its own TTL
    /// (`runningTTL`) rather than risk clearing an unrelated card.
    private func clearRunning(sessionId: String?) {
        // No session id on the triggering event at all -- nothing to scope
        // the clear to; leave every card alone rather than guess.
        guard let sessionId else { return }
        let idsToRemove = runningTasks.filter { $0.sessionId == sessionId }.map(\.id)
        for id in idsToRemove {
            expiryTasks.removeValue(forKey: id)?.cancel()
        }
        runningTasks.removeAll { $0.sessionId == sessionId }
    }

    // MARK: - Background Bash tasks (run_in_background)

    /// Outcome parsed from a `<status>` element inside a `<task-notification>`
    /// block. Anything else (a status string we don't recognise) is treated as
    /// "not actionable yet" by the caller, not as a fourth case here.
    enum BackgroundStatus: String {
        case completed, failed, killed
    }

    /// Default safety-net timeout: a background card retires on its own after
    /// this long with no completion signal, so a missed/garbled
    /// `<task-notification>` (or a command that genuinely never returns) can't
    /// pin a card on screen forever. Overridable via the optional
    /// `backgroundTimeoutSeconds` field in `~/.petmacos/config.json`, same
    /// mechanism as `talkingDecaySeconds`/`errorDecaySeconds` (see
    /// `configOverride`) -- tests shorten it instead of waiting 120 real minutes.
    private static let defaultBackgroundTimeoutSeconds: TimeInterval = 120 * 60

    var backgroundTimeoutSeconds: TimeInterval {
        Self.configOverride(key: "backgroundTimeoutSeconds") ?? Self.defaultBackgroundTimeoutSeconds
    }

    /// Per-background-task safety timeout, cancelled as soon as the task
    /// retires normally (completion signal or manual dismiss).
    private var backgroundTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// Tracks a newly launched background Bash command. No hook reports its
    /// completion, so a filesystem watcher is (re)started on its transcript to
    /// react to the `<task-notification>` block Claude Code writes when it's
    /// done (see `TranscriptWatcher`), backed by a slow safety-net poll, and a
    /// safety timeout is armed in case no signal ever arrives at all.
    private func startBackgroundTask(taskId: String, title: String, detail: String?,
                                      context: String?, transcriptPath: String, sessionId: String?) {
        guard !backgroundTasks.contains(where: { $0.taskId == taskId }) else { return }
        if backgroundOffsets[transcriptPath] == nil {
            // Skip everything already in the transcript; only new writes matter.
            backgroundOffsets[transcriptPath] = Self.fileSize(path: transcriptPath)
        }
        let item = TaskItem(
            title: title, detail: detail, kind: .background, context: context,
            taskId: taskId, transcriptPath: transcriptPath, sessionId: sessionId
        )
        backgroundTasks.append(item)
        scheduleBackgroundTimeout(id: item.id, taskId: taskId)
        updatePassthrough()
        ensureWatcher(for: transcriptPath)
        ensureBackgroundSafetyPoll()
    }

    /// Manual close of a background-task card (safety valve if the completion
    /// signal is ever missed).
    func dismissBackgroundTask(id: UUID) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        let item = backgroundTasks.remove(at: index)
        cancelBackgroundTimeout(id: id)
        if let path = item.transcriptPath { retireWatcherIfUnused(path: path) }
        updatePassthrough()
    }

    /// Starts (or reuses) the DispatchSource-based watcher for one transcript
    /// path. Several background tasks can share a transcript, so this is a
    /// no-op if a watcher for `path` already exists.
    private func ensureWatcher(for path: String) {
        guard transcriptWatchers[path] == nil else { return }
        transcriptWatchers[path] = TranscriptWatcher(path: path) { [weak self] in
            self?.scanTranscript(path: path)
        }
    }

    /// Cancels and drops the watcher for `path` once no background task under
    /// it remains — called from every retirement path (completed, failed,
    /// killed, timeout, manual dismiss) so a watcher is never leaked.
    private func retireWatcherIfUnused(path: String) {
        guard !backgroundTasks.contains(where: { $0.transcriptPath == path }) else { return }
        transcriptWatchers.removeValue(forKey: path)?.cancel()
        backgroundOffsets.removeValue(forKey: path)
    }

    /// Scans one transcript for new `<task-notification>` blocks and retires
    /// any background task whose id shows up with a recognised status. Called
    /// both by that transcript's `TranscriptWatcher` (the fast path, driven by
    /// real filesystem events) and by the slow safety-net poll below — same
    /// parsing/offset-tracking logic either way; only the trigger differs.
    private func scanTranscript(path: String) {
        guard backgroundTasks.contains(where: { $0.transcriptPath == path }) else { return }
        var offset = backgroundOffsets[path] ?? 0
        let notifications = Self.scanTaskNotifications(path: path, offset: &offset)
        backgroundOffsets[path] = offset
        for note in notifications {
            guard let status = note.status else { continue }
            finishBackgroundTask(taskId: note.taskId, status: status)
        }
    }

    /// Cadence of the slow safety-net poll — see `ensureBackgroundSafetyPoll`.
    private static let backgroundSafetyPollInterval: TimeInterval = 10

    /// Guarantees background-task completion is *never* missed even if every
    /// `TranscriptWatcher` somehow fails (e.g. both the direct file-fd open and
    /// the parent-directory-fd open are denied by sandboxing/permissions, or a
    /// rotation edge case slips through the watcher's demote/promote dance).
    /// 10s is slow enough that the I/O cost is negligible, while still bounding
    /// worst-case detection latency well under the 120-minute safety timeout.
    /// The watcher is expected to drive the common case's latency far below
    /// this; this loop exists purely as a backstop, matching the old
    /// fixed-interval poll's guarantee so nothing regresses.
    private func ensureBackgroundSafetyPoll() {
        guard backgroundSafetyPollTask == nil else { return }
        backgroundSafetyPollTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(Self.backgroundSafetyPollInterval))
                guard !Task.isCancelled, let self else { return }
                if self.backgroundTasks.isEmpty {
                    self.backgroundSafetyPollTask = nil
                    return
                }
                let paths = Set(self.backgroundTasks.compactMap(\.transcriptPath))
                for path in paths { self.scanTranscript(path: path) }
            }
        }
    }

    /// Arms the safety-net timeout for a just-started background task.
    private func scheduleBackgroundTimeout(id: UUID, taskId: String) {
        backgroundTimeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.backgroundTimeoutSeconds ?? Self.defaultBackgroundTimeoutSeconds))
            guard !Task.isCancelled, let self else { return }
            self.timeoutBackgroundTask(id: id, taskId: taskId)
        }
    }

    private func cancelBackgroundTimeout(id: UUID) {
        backgroundTimeoutTasks.removeValue(forKey: id)?.cancel()
    }

    /// Fires when a background task's safety-net timeout elapses with no
    /// completion signal ever having arrived. Retires the card with a notice
    /// that makes clear the outcome is simply unknown, not that it failed.
    private func timeoutBackgroundTask(id: UUID, taskId: String) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        let item = backgroundTasks.remove(at: index)
        backgroundTimeoutTasks.removeValue(forKey: id)
        if let path = item.transcriptPath { retireWatcherIfUnused(path: path) }
        updatePassthrough()
        pushCompleted(TaskItem(
            title: "Chạy nền: không rõ kết quả (quá hạn theo dõi)",
            detail: item.title,
            kind: .failed,
            dedupeKey: "bg-\(taskId)",
            context: item.context,
            sessionId: item.sessionId
        ))
    }

    /// Retires a background task's card once its outcome is known, with a
    /// notice worded for that specific outcome.
    private func finishBackgroundTask(taskId: String, status: BackgroundStatus) {
        guard let index = backgroundTasks.firstIndex(where: { $0.taskId == taskId }) else { return }
        let item = backgroundTasks.remove(at: index)
        cancelBackgroundTimeout(id: item.id)
        if let path = item.transcriptPath { retireWatcherIfUnused(path: path) }
        updatePassthrough()
        let (title, kind): (String, TaskKind) = {
            switch status {
            case .completed: return ("Chạy nền xong", .done)
            case .failed: return ("Chạy nền lỗi", .failed)
            case .killed: return ("Chạy nền bị dừng", .failed)
            }
        }()
        pushCompleted(TaskItem(
            title: title,
            detail: item.title,
            kind: kind,
            dedupeKey: "bg-\(taskId)",
            context: item.context,
            sessionId: item.sessionId
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
    /// Not tied to any Claude Code session, so its mood is bucketed under the
    /// synthetic "no session" key (see `setMood(_:for:)`).
    func notify(_ title: String, mood: Mood = .idle) {
        setMood(mood, for: nil)
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

    /// Small caption shown above a card: "project · name", where `name` is
    /// the conversation's first prompt (resolved via `sessionNames` from
    /// `~/.claude/history.jsonl` — the same text `claude --resume` lists it
    /// under), falling back to the old "#tab" stable session-id prefix when
    /// no name can be resolved yet (brand-new session whose first prompt
    /// hasn't reached history.jsonl, or history.jsonl unavailable). The tag
    /// still distinguishes subagents/background tasks from different Claude
    /// Code tabs sharing one project folder even in the fallback case.
    private func contextLabel(for event: HookEvent) -> String? {
        let tab: String?
        if let sessionId = event.sessionId, let name = sessionNames.name(for: sessionId, cwd: event.cwd) {
            tab = name
        } else {
            tab = event.sessionTag.map { "#\($0)" }
        }
        let parts = [event.projectName, tab].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Applies an incoming hook event to the pet's presentation.
    func apply(_ event: HookEvent) {
        logEvent(event, route: "event")
        rememberSessionMeta(for: event)
        let context = contextLabel(for: event)
        let sid = event.sessionId
        switch event.hookEventName ?? "" {
        case "UserPromptSubmit":
            setMood(.thinking, for: sid)
            pushRunning(TaskItem(title: "Đang suy nghĩ…", kind: .thinking, context: context, sessionId: sid))
        case "PreToolUse":
            // Reached here only in auto mode (manual mode blocks via /ask).
            setMood(.working, for: sid)
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
                    context: context,
                    sessionId: sid
                ))
            }
        case "PostToolUse":
            // A tool finished. Cards live out their TTL; we only refresh mood.
            // Task/Agent returning does NOT mean the subagent finished (async
            // agents return immediately) — removal happens on SubagentStop.
            // A failed tool briefly shows "error" instead, decaying back to
            // "working"/"idle" on its own (see `setMood`).
            if event.isToolError {
                setMood(.error, for: sid)
            } else {
                setMood(.working, for: sid)
            }
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
                    transcriptPath: path,
                    sessionId: sid
                )
            }
        case "Notification":
            setMood(.asking, for: sid)
            pushRunning(TaskItem(title: event.message ?? "Claude cần chú ý",
                                 kind: .notification, context: context, sessionId: sid))
        case "Stop":
            // Subagents/background tasks may still be working (globally,
            // across every session -- see `hasActiveWork`'s doc comment);
            // keep their cards and stay in "working" mood while any remain. A
            // fully clean stop plays the "happy" one-shot once (falls back to
            // just "talking" if the user has no "happy" frames — see
            // PetView) and then decays back to idle after a while (see
            // `setMood`). Only THIS session's running cards are cleared —
            // other sessions' cards are untouched (see `clearRunning`).
            if subagentTasks.isEmpty && backgroundTasks.isEmpty {
                happyID = UUID()
                setMood(.talking, for: sid)
            } else {
                setMood(.working, for: sid)
            }
            clearRunning(sessionId: sid)
            pushStopNotice(for: event)
        case "SubagentStart":
            // New in Claude Code v2.1.177+: carries the real agent_id/agent_type
            // for a subagent that's about to start. See `handleSubagentStart` for
            // how this reconciles with the card `PreToolUse`/allowed-`/ask`
            // already created (title, but no id).
            setMood(.working, for: sid)
            handleSubagentStart(event)
        case "SubagentStop":
            setMood(subagentTasks.count > 1 ? .working : .talking, for: sid)
            let card = finishSubagent(agentId: event.agentId)
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
                context: context,
                sessionId: sid
            ))
        case "SessionStart":
            // No card: with hooks installed globally, this fires for every
            // Claude Code session on the machine (other projects, automated
            // routines...), not just the one the user is watching — a card
            // here reads as noise. Only the mood/sprite reacts.
            setMood(.idle, for: sid)
        case "SessionEnd":
            // Hooks are installed globally, so this fires for every Claude
            // Code session on the machine — NOT just the one the pet is
            // watching. Only THIS session's transient running-task stack is
            // cleared and THIS session's own mood/activity entry is dropped;
            // subagents belonging to other still-active sessions must not be
            // wiped just because an unrelated session ended. Each subagent
            // card is only removed by its own SubagentStop, a manual dismiss,
            // or expiring after a restart (see recoverInFlightSubagents).
            setMood(.sleep, for: sid)
            if let sid { sessions.removeValue(forKey: sid) } else { sessions.removeValue(forKey: Self.noSessionKey) }
            recomputeAggregateMood()
            clearRunning(sessionId: sid)
            pruneMetaIfUnused(sessionId: sid)
        default:
            if let message = event.message {
                pushRunning(TaskItem(title: message, kind: .session, context: context, sessionId: sid))
            }
        }
    }

    /// Builds the persistent running card for a Task/Agent launch. No
    /// `agent_id` is available yet at this point (`PreToolUse`/`/ask` precede
    /// the subagent actually starting) — `sessionId` is stamped instead so a
    /// later `SubagentStart` can claim this exact card (see
    /// `handleSubagentStart`).
    private func subagentCard(for event: HookEvent) -> TaskItem {
        TaskItem(
            title: event.intentTitle,
            detail: event.intentDetail.map { truncate($0) },
            kind: .subagent,
            context: contextLabel(for: event),
            sessionId: event.sessionId
        )
    }

    /// Pushes the "Hoàn thành" notice for a Stop event, enriching its context
    /// line with the conversation title read from the transcript when possible.
    private func pushStopNotice(for event: HookEvent) {
        let key = "stop-\(event.sessionId ?? "s")"
        let baseContext = contextLabel(for: event)
        let path = event.transcriptPath
        let sid = event.sessionId

        func push(_ text: String?, context: String?) {
            pushCompleted(TaskItem(
                title: "Hoàn thành",
                detail: truncate(text ?? "Claude đã trả lời", limit: 800),
                kind: .done,
                dedupeKey: key,
                context: context,
                sessionId: sid
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

    // MARK: - Permission requests (blocking, FIFO queue)

    /// Presents a permission request, or auto-approves it when paused. When an
    /// ask is already being shown, the new one is appended to `askQueue`
    /// instead of replacing it -- the old single-slot behaviour silently
    /// dropped/overwrote an earlier ask, leaving its hook blocked until the
    /// script's own timeout denied it. Every incoming ask still immediately
    /// marks its *session* as `.asking` in the mood aggregate (that session
    /// genuinely is waiting on a human), even while its dialog itself waits
    /// in line to be shown.
    func presentAsk(id: String, event: HookEvent) {
        logEvent(event, route: "ask")
        rememberSessionMeta(for: event)
        // Launching a subagent? Remember its card so an "allow" can start
        // tracking it (in manual mode no separate PreToolUse /event arrives).
        let isSubagent = event.toolName == "Task" || event.toolName == "Agent"
        let card = isSubagent ? subagentCard(for: event) : nil
        if autoAllow {
            if let card { startSubagent(card) }
            resolver?.resolveAsk(id: id, decision: PetDecision(decision: "allow", text: nil))
            return
        }
        setMood(.asking, for: event.sessionId)
        let ask = PendingAsk(
            id: id,
            toolName: event.toolName ?? "Tool",
            summary: event.toolInputSummary.map { truncate($0) },
            subagentCard: card,
            sessionId: event.sessionId,
            conversationName: conversationLabel(for: event)
        )
        let wasEmpty = askQueue.isEmpty
        askQueue.append(ask)
        // Only the head of the queue gets a dialog; a queued-behind ask stays
        // invisible until its turn (see `presentNextAskIfNeeded`). The hook
        // for a queued ask can still be waiting a long time -- if the
        // script's own `/ask` timeout (default 300s/600s, see HookServer)
        // fires first, that request is simply denied without ever being
        // shown; this is documented, accepted behaviour (see TASK 4 note in
        // CLAUDE.md / the project brief), not a bug to fix here.
        if wasEmpty {
            onInteractiveNeeded?(true)
        }
    }

    /// Resolves the human-readable conversation label for an ask's dialog:
    /// the resolved session name if available, else the "#tag" fallback --
    /// same source as `contextLabel(for:)`'s tab portion, without the project
    /// name prefix (the dialog already shows the tool name).
    private func conversationLabel(for event: HookEvent) -> String? {
        if let sessionId = event.sessionId, let name = sessionNames.name(for: sessionId, cwd: event.cwd) {
            return name
        }
        return event.sessionTag.map { "#\($0)" }
    }

    /// Sends the user's decision back to the waiting hook and clears the
    /// dialog, then shows the next queued ask (if any).
    func resolve(_ decision: String, text: String? = nil) {
        guard let ask = askQueue.first else { return }
        askQueue.removeFirst()
        resolver?.resolveAsk(id: ask.id, decision: PetDecision(decision: decision, text: text))
        if decision == "allow", let card = ask.subagentCard {
            startSubagent(card)
        }
        setMood(.idle, for: ask.sessionId)
        presentNextAskOrDismiss()
    }

    /// Called by the server if a request times out or the connection drops.
    /// Removes the ask wherever it sits in the queue -- not just when it's
    /// the one currently shown -- since a queued-but-not-yet-displayed ask
    /// can also hit its own timeout while waiting in line.
    func cancelAsk(id: String) {
        guard let index = askQueue.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = index == 0
        let ask = askQueue.remove(at: index)
        setMood(.idle, for: ask.sessionId)
        if wasCurrent {
            presentNextAskOrDismiss()
        }
    }

    /// After the currently-shown ask is removed (resolved or cancelled), show
    /// the next queued ask if there is one, or drop out of interactive mode.
    private func presentNextAskOrDismiss() {
        if askQueue.isEmpty {
            onInteractiveNeeded?(false)
            updatePassthrough() // keep passthrough on if notices are still visible
        }
        // else: `pendingAsk` (computed from `askQueue.first`) now reflects the
        // next ask automatically; the dialog stays up (still interactive), no
        // separate "present" call needed.
    }

    // MARK: - Interactive questions (AskUserQuestion, blocking)

    /// Presents an `AskUserQuestion` request. Unlike `/ask`, questions are shown
    /// even when approvals are paused — they genuinely need a human answer.
    /// Unlike asks, questions are not queued (out of scope for this pass —
    /// the pre-existing single-slot behaviour is unchanged).
    func presentQuestion(id: String, event: HookEvent) {
        logEvent(event, route: "question")
        rememberSessionMeta(for: event)
        let questions = event.askQuestions
        guard !questions.isEmpty else {
            // Nothing parseable to ask; let the terminal handle it.
            resolver?.resolveQuestion(id: id, answers: nil)
            return
        }
        setMood(.asking, for: event.sessionId)
        pendingQuestion = PendingQuestion(id: id, questions: questions, sessionId: event.sessionId)
        onInteractiveNeeded?(true)
    }

    /// Sends the user's answers back to the waiting hook and clears the dialog.
    func resolveQuestion(_ answers: [String: PetAnswer]) {
        guard let question = pendingQuestion else { return }
        resolver?.resolveQuestion(id: question.id, answers: answers)
        pendingQuestion = nil
        setMood(.idle, for: question.sessionId)
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
        guard let question = pendingQuestion, question.id == id else { return }
        resolver?.resolveQuestion(id: id, answers: nil)
        pendingQuestion = nil
        setMood(.idle, for: question.sessionId)
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
        let sessionId: String?
    }

    struct DebugSessionActivity: Codable {
        let id: String
        let mood: String
        let lastEventAt: Date
    }

    struct DebugSnapshot: Codable {
        /// Aggregate mood (highest-priority mood among all live sessions).
        let mood: String
        let runningTasks: [DebugCard]
        let subagentTasks: [DebugCard]
        let backgroundTasks: [DebugCard]
        let completedNotices: [DebugCard]
        let hasPendingAsk: Bool
        let hasPendingQuestion: Bool
        /// Number of asks waiting in the FIFO queue (including the one shown).
        let pendingAskCount: Int
        /// The `session_id` of the ask currently shown as a dialog (the head
        /// of the FIFO queue), or nil if none. Lets automated tests verify
        /// queue ordering without needing computer-use on the dialog itself.
        let pendingAskSessionId: String?
        /// Every currently-live session's own mood + last-event timestamp.
        let sessions: [DebugSessionActivity]
        /// Session ids in the exact order the per-conversation card stack
        /// renders them (newest event first — see `orderedSessionSummaries`).
        /// `""` stands for the no-session (app notice) bucket.
        let sessionOrder: [String]
        /// The display name each session card shows, aligned with
        /// `sessionOrder` (resolved conversation name, else "#tag" fallback).
        let sessionNames: [String]
    }

    /// Read-only state snapshot for `GET /debug/state`, used by automated
    /// tests that can't see this accessory app's panel via computer-use.
    func debugSnapshot() -> DebugSnapshot {
        func card(_ item: TaskItem) -> DebugCard {
            DebugCard(title: item.title, detail: item.detail,
                      kind: String(describing: item.kind), context: item.context,
                      sessionId: item.sessionId)
        }
        let sessionSnapshots = sessions.map { key, activity in
            DebugSessionActivity(
                id: key == Self.noSessionKey ? "" : key,
                mood: String(describing: activity.mood),
                lastEventAt: activity.lastEventAt
            )
        }
        // Computed once — the grouping walk is O(sessions x items).
        let summaries = orderedSessionSummaries
        return DebugSnapshot(
            mood: String(describing: mood),
            runningTasks: runningTasks.map(card),
            subagentTasks: subagentTasks.map(card),
            backgroundTasks: backgroundTasks.map(card),
            completedNotices: completedNotices.map(card),
            hasPendingAsk: pendingAsk != nil,
            hasPendingQuestion: pendingQuestion != nil,
            pendingAskCount: pendingAskCount,
            pendingAskSessionId: pendingAsk?.sessionId,
            sessions: sessionSnapshots,
            sessionOrder: summaries.map(\.id),
            sessionNames: summaries.map(\.name)
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
    ) -> [(taskId: String, status: BackgroundStatus?)] {
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

        var results: [(String, BackgroundStatus?)] = []
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
                let status: BackgroundStatus?
                if block.contains("<status>completed</status>") { status = .completed }
                else if block.contains("<status>failed</status>") { status = .failed }
                else if block.contains("<status>killed</status>") { status = .killed }
                else { status = nil } // unrecognised status; poll again next time
                results.append((taskId, status))
            }
            cursor = closeRange?.upperBound ?? consumed.endIndex
        }
        return results
    }
}

/// Watches one background task's transcript file for new writes, replacing
/// the old fixed-interval poll with real filesystem events (`PetState`'s
/// `scanTranscript` still does the actual parsing — this class only decides
/// *when* to call it).
///
/// ## Design trade-off: DispatchSource vs FSEvents
///
/// `DispatchSource.makeFileSystemObjectSource` is the lighter-weight, more
/// direct option — it needs only a POSIX file descriptor and delivers
/// `.write`/`.extend`/`.delete`/`.rename` events for that one fd via GCD,
/// which fits neatly into this app's existing dispatch-based hook server.
/// FSEvents is the alternative: it watches a *path* (no fd needed, so it
/// tolerates the file not existing yet out of the box) and is the natural
/// choice for recursively watching a whole directory tree. But it's a
/// heavier, run-loop/CFRunLoop-based API, coalesces and can *drop* events
/// under load (by design — it's meant for "something changed, go look", not
/// a reliable per-write signal), and would mean tracking a second concurrency
/// model alongside GCD for what is here just a handful of known, individual
/// files. Given that trade-off, this uses DispatchSource for the common case
/// (file already exists, tailing new appends) and only falls back to
/// directory-level watching — still via DispatchSource, not FSEvents — for
/// the narrow "file doesn't exist yet" gap that a bare fd-based API can't
/// cover on its own.
///
/// ## Handling "doesn't exist yet" and rotation
///
/// A background task's transcript path is known the moment the task launches
/// (the hook reports it in the same `PostToolUse` payload), but the file
/// itself may not have been created yet by the Claude Code process that will
/// append to it, and in principle it could be rotated/replaced later. So:
/// `init` first tries to open+watch the file directly; if that fails
/// (`ENOENT`), it opens a DispatchSource on the *parent directory* instead —
/// any write there (including the file's own creation) triggers a re-check
/// that promotes to the direct file watch as soon as it succeeds. A
/// `.delete`/`.rename` event on an already-open file watch (rotation) demotes
/// back to the directory watch the same way, so the watcher can never get
/// stuck pointing at a file descriptor for a file that's gone.
///
/// ## Safety net
///
/// Both fd opens can fail for reasons outside this class's control (odd
/// sandboxing, a directory permission edge case, `EMFILE`); rather than treat
/// that as fatal, `ensureWatcher`'s caller also runs a slow 10s poll
/// (`ensureBackgroundSafetyPoll` in `PetState`) for as long as any background
/// task is tracked, so a watcher failure degrades to "same as the old poll",
/// never to "silently stuck".
///
/// Not `@MainActor`: DispatchSource event handlers fire on the `.main` queue,
/// which the Swift 6 concurrency checker doesn't statically treat as
/// main-actor-isolated. `fire()` hops onto the main actor explicitly via
/// `Task { @MainActor in ... }` before touching `PetState` (same pattern
/// `HookServer` uses for its NWListener callbacks). All of this class's own
/// mutable state (`fileSource`/`dirSource`) is only ever touched from
/// handlers scheduled on that same serial `.main` queue, so there is no
/// actual data race — `@unchecked Sendable` documents that guarantee for the
/// compiler, matching the existing convention in `HookServer`.
private final class TranscriptWatcher: @unchecked Sendable {
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private let path: String
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        if !openFileWatch() {
            openDirectoryWatch()
        }
    }

    /// Hops onto the main actor before invoking `onChange`, since this class
    /// itself is not actor-isolated (see the type-level doc comment above).
    private func fire() {
        let onChange = onChange
        Task { @MainActor in onChange() }
    }

    /// Attempts to open the transcript file itself and watch it directly.
    /// Returns `false` (leaving both sources untouched) if the file doesn't
    /// exist yet — the caller falls back to `openDirectoryWatch()`.
    @discardableResult
    private func openFileWatch() -> Bool {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // The file was rotated/removed out from under us: drop this
                // watch and fall back to watching the directory until (if
                // ever) a file at this path exists again.
                self.demoteToDirectoryWatch()
                return
            }
            self.fire()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        return true
    }

    /// Watches the transcript's parent directory: any write there (including
    /// the transcript file's own creation) is a signal to re-check.
    private func openDirectoryWatch() {
        guard dirSource == nil else { return }
        let dir = (path as NSString).deletingLastPathComponent
        let fd = open(dir.isEmpty ? "." : dir, O_EVTONLY)
        guard fd >= 0 else { return } // the 10s safety-net poll covers this
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fileSource == nil, self.openFileWatch() {
                // Promoted to a direct file watch; the directory watch is no
                // longer needed.
                self.dirSource?.cancel()
                self.dirSource = nil
            }
            self.fire()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func demoteToDirectoryWatch() {
        fileSource?.cancel()
        fileSource = nil
        openDirectoryWatch()
        fire() // the rotation itself may be worth a re-scan (new file, new content)
    }

    /// Cancels both sources. Must be called exactly once per watcher, when the
    /// last background task under its transcript retires (see
    /// `PetState.retireWatcherIfUnused`) — cancelling closes the underlying
    /// file descriptors via each source's cancel handler, so this is the only
    /// place those fds are released.
    func cancel() {
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
    }
}
