import AppKit
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
    /// Releases a held `Stop` hook. `text` non-nil makes the hook answer
    /// `{"decision":"block","reason":…}` so the user's message reaches Claude
    /// and the turn continues; `nil` lets the turn end normally.
    func resolveReply(id: String, text: String?)
}

/// A pending permission request awaiting the user's Allow/Deny on the pet.
struct PendingAsk: Identifiable, Equatable {
    let id: String
    let toolName: String
    let summary: String?
    /// The `session_id` this ask came from, used to route its mood back to the
    /// right per-session bucket on resolve/cancel (see `PetState.sessions`).
    let sessionId: String?
    /// The conversation's resolved name (via `SessionNameResolver`, falling
    /// back to `#tag`), shown in the dialog so the user knows *which*
    /// conversation they're approving when several are running at once.
    let conversationName: String?

    init(id: String, toolName: String, summary: String?,
         sessionId: String? = nil, conversationName: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
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
    /// Claude ended its turn by asking the user something instead of
    /// finishing. There is no hook for this — `QuestionDetector` reads it off
    /// the final reply — so the notice exists to say "your turn", not "done".
    case question
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
    /// Task/Agent) came from. Used to reconcile a not-yet-identified subagent
    /// card with a later `SubagentStart` event that carries the real `agent_id`
    /// -- see `PetState.handleSubagentStart` -- or to retire it if the launch is
    /// denied (`PetState.resolve`).
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

    /// Timestamp of the last hook event received on any route (`/event`,
    /// `/ask`, `/question`). Used by the Diagnostics tab to show "last seen"
    /// and to detect a silently broken hook pipeline (`pet-hook.sh` always
    /// exits 0, so Claude Code never surfaces a connection failure itself).
    private(set) var lastEventAt: Date?

    /// Records an error the app noticed (hook install failure, server start
    /// failure, failed connectivity test…) to `events.log`. There is no in-app
    /// error view anymore — the self-healing path surfaces real breakage as a
    /// plain pet notice, and the log keeps the full trail for support.
    func recordError(_ message: String) {
        appendLog("error \(message)")
    }

    /// Records something that happened but isn't a fault (an install, a
    /// migration). Same log, no "error" prefix to chase in a bug report.
    func recordNote(_ message: String) {
        appendLog(message)
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

    /// Sessions whose card the user closed (header ✕) or retired by viewing
    /// the conversation in the Claude Code desktop app. The card stays hidden
    /// until a hook event newer than the dismissal arrives (`setMood` clears
    /// the entry on every new event, reviving the card with fresh items).
    private var dismissedSessions: [String: Date] = [:]

    /// Display metadata remembered per session key (resolved conversation
    /// name + "#tag" fallback), captured from every event that carries a
    /// `session_id` so the per-session UI card can title itself even for
    /// items whose own `context` caption is missing. Pruned on `SessionEnd`
    /// when no card still references the session (see `pruneMetaIfUnused`).
    private struct SessionMeta {
        var name: String?
        var tag: String?
        var project: String?
        /// Controlling terminal of the session ("/dev/ttys003"), or nil for a
        /// Desktop-app session. Reported by the hook, which inherits it from
        /// `claude` — an exact handle, unlike the Desktop app's title match.
        var tty: String?
        /// Transcript path, kept because the folder it sits in identifies the
        /// session's project directory, which is how a missing `tty` is
        /// recovered later (see `TerminalBridge.discoverTty`).
        var transcriptPath: String?
        /// Cached answer for the card label; see `surface(forKey:)`.
        var surface: SessionSurface?
    }
    private var sessionMeta: [String: SessionMeta] = [:]

    /// Records which terminal a session runs in (nil / empty for the Desktop
    /// app). Refreshed on every event: resuming a session in another window
    /// gives it a new tty, and a stale one would address the wrong tab.
    func rememberTty(_ tty: String?, for sessionId: String?) {
        guard let sid = sessionId else { return }
        var meta = sessionMeta[sid] ?? SessionMeta()
        meta.tty = (tty?.isEmpty == false) ? tty : nil
        sessionMeta[sid] = meta
    }

    /// Captures/refreshes the display metadata for the event's session. The
    /// name is re-resolved on every event (cheap: `SessionNameResolver`
    /// caches) so a session whose first prompt lands in `history.jsonl`
    /// *after* its first hook event still picks up its real name later.
    private func rememberSessionMeta(for event: HookEvent) {
        guard let sid = event.sessionId else { return }
        var meta = sessionMeta[sid] ?? SessionMeta()
        if let name = sessionNames.name(for: sid, cwd: event.cwd, transcriptPath: event.transcriptPath) {
            meta.name = name
        }
        if meta.tag == nil { meta.tag = event.sessionTag }
        if let transcript = event.transcriptPath, !transcript.isEmpty {
            meta.transcriptPath = transcript
        }
        // A session's project never changes, but the reported `cwd` does: the
        // Bash tool keeps a persistent shell, so once a command `cd`s
        // somewhere every following tool event reports *that* folder -- the
        // log shows one session flipping between "ClaudePet" and "scratchpad"
        // from one PostToolUse to the next. `cwdIsProjectRoot` settles it
        // exactly; when it can't (no transcript path), fall back to trusting
        // session-level events, whose cwd never wanders.
        if let project = event.projectName {
            switch cwdIsProjectRoot(event) {
            case true: meta.project = project
            case false: break   // a wandered shell -- never name the session after it
            case nil: if meta.project == nil || !event.isToolEvent { meta.project = project }
            }
        }
        // Resolved here, on an event, and never while a view is drawing: the
        // answer costs a 512KB read of the transcript tail, and the card asks
        // for it on every single redraw. Re-read only until it answers — a
        // session whose transcript has no `entrypoint` yet (no user prompt
        // recorded) retries on the next event, which is exactly when the file
        // has grown.
        if meta.surface == nil, let transcript = meta.transcriptPath {
            let resolved = SessionOrigin.read(transcriptPath: transcript).surface
            if resolved != .unknown { meta.surface = resolved }
        }
        sessionMeta[sid] = meta
    }

    /// Whether the event's `cwd` really is the session's project root, or
    /// `nil` when it can't be told. Claude Code writes the transcript to
    /// `<projects root>/<slug(project cwd)>/<session id>.jsonl`, and `slug` is
    /// a pure function of the path — so slugging the event's own `cwd` and
    /// comparing it to the folder the transcript actually sits in answers the
    /// question exactly, with no guessing about which folder names contain a
    /// `-`.
    private func cwdIsProjectRoot(_ event: HookEvent) -> Bool? {
        guard let cwd = event.cwd, !cwd.isEmpty,
              let transcript = event.transcriptPath, !transcript.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: transcript).deletingLastPathComponent().lastPathComponent
        return folder == SessionNameResolver.slug(cwd)
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
        /// Which program is hosting this conversation, from the transcript's
        /// own `entrypoint`. Shown next to the project because several
        /// conversations in the same folder look identical otherwise — and
        /// because it explains the pet's behaviour: a reply reaches each
        /// surface a different way, and only some of them can be reached
        /// while the conversation sits idle.
        let surface: SessionSurface
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
        /// This session has a blocking `/ask` or `/question` of its own waiting
        /// on the pet. The reply box is disabled meanwhile: the permission
        /// dialog is the thing that needs answering, and a message typed now
        /// could only be delivered after it.
        let isAwaitingApproval: Bool
        /// The session's `Stop` hook is being held open right now (Claude ended
        /// its turn on a question). Anything typed goes straight to Claude and
        /// the turn resumes — so the box says so.
        let isHoldingReply: Bool
        /// Outcome of the most recent message sent from this card, if any.
        let replyStatus: ReplyStatus?
        /// How many messages are still waiting to be delivered to this session.
        ///
        /// The status line above is transient by design (it clears after 20s),
        /// which left the card showing *nothing* for a message that had not
        /// gone anywhere. A count is state, not an event, so it stays until the
        /// queue actually drains.
        let queuedReplies: Int
        /// A card offers a reply box for any conversation that is still alive.
        /// Unlike the tmux prototype there is no transport to detect: delivery
        /// rides the hooks that are already installed, so every live session
        /// can be written to.
        ///
        /// A *sleeping* session takes messages too: quiet for a while is the
        /// exact case idle delivery was built for, and hiding the box there
        /// meant the conversations most in need of it were the ones you could
        /// not type into.
        var canReply: Bool { !id.isEmpty }
    }

    /// What happened to a message sent from a session card.
    enum ReplyStatus: Equatable {
        /// Handed to Claude Code (a held `Stop` was released, or a queued
        /// message was picked up at a tool boundary).
        case sent
        /// Parked in the queue — Claude is mid-turn, so it goes out at the
        /// next `PostToolUse` or when the turn ends.
        case queued
        /// The session is idle and no surface would take the message: it is
        /// still queued, but nothing will deliver it until that session runs
        /// again. Saying "queued" here would be a lie — it is the difference
        /// between "arriving shortly" and "never", and the card used to show
        /// the same word for both.
        case stuck
        /// The route that would carry this message drives another app's window,
        /// and macOS has not granted the pet Accessibility. Its own status
        /// because the fix is one click and belongs on the card: "queued" and
        /// even "stuck" send the user looking for a bug in the wrong place.
        case needsAccess
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
            // Dismissed and quiet since: stay hidden until a newer event.
            if let dismissedAt = dismissedSessions[key], lastEventAt <= dismissedAt { continue }
            result.append(SessionSummary(
                id: key == Self.noSessionKey ? "" : key,
                name: displayName(forKey: key),
                project: sessionMeta[key]?.project,
                surface: surface(forKey: key),
                mood: mood,
                lastEventAt: lastEventAt,
                latestRunning: running.first,       // runningTasks is newest-first
                latestCompleted: completed.first,   // completedNotices is newest-first
                subagents: subs,
                backgrounds: bgs,
                isAwaitingApproval: askQueue.contains { $0.sessionId == key }
                    || pendingQuestion?.sessionId == key,
                isHoldingReply: heldStops[key] != nil,
                replyStatus: replyStatuses[key],
                queuedReplies: replyQueue[key]?.count ?? 0
            ))
        }
        return result.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// Conversations whose turn ended on a question and haven't been answered
    /// yet (`.asking` also covers a live `Notification`). Drives the menu bar
    /// icon: these block the user just as a permission prompt does, only
    /// silently — which is exactly why they need surfacing.
    var waitingSessionCount: Int {
        orderedSessionSummaries.filter { $0.mood == .asking }.count
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
        // New activity revives a dismissed card.
        dismissedSessions.removeValue(forKey: key)
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

    /// Removes the oldest still-running subagent card (FIFO). This is the
    /// fallback used only when a `SubagentStop` carries no `agent_id` at all
    /// (an older Claude Code build that predates `SubagentStart`) -- see
    /// `finishSubagent(agentId:sessionId:)` below. Returns the removed card
    /// for the completion notice.
    @discardableResult
    private func finishOldestSubagent() -> TaskItem? {
        guard !subagentTasks.isEmpty else { return nil }
        let item = subagentTasks.removeFirst()
        updatePassthrough()
        persistInFlightSubagents()
        return item
    }

    /// Removes the subagent card matching `agentId` if one was claimed for it
    /// (see `handleSubagentStart`). An unmatched id retires the oldest
    /// *unclaimed* card of the same session, if any -- that covers a missed
    /// `SubagentStart` -- and otherwise nothing: Claude Code also runs hidden
    /// internal agents whose `SubagentStop` arrives with an id that never
    /// started here, and the old unconditional FIFO fallback let those stops
    /// retire a still-running visible subagent (seen with background Agent
    /// launches). Only a stop with NO id at all (pre-`SubagentStart` builds)
    /// still falls back to plain FIFO. Returns the removed card, if any.
    @discardableResult
    private func finishSubagent(agentId: String?, sessionId: String?) -> TaskItem? {
        guard let agentId else { return finishOldestSubagent() }
        let index = subagentTasks.firstIndex(where: { $0.agentId == agentId })
            ?? subagentTasks.firstIndex(where: { $0.agentId == nil && $0.sessionId == sessionId })
        guard let index else { return nil }
        let item = subagentTasks.remove(at: index)
        updatePassthrough()
        persistInFlightSubagents()
        return item
    }

    /// Handles a `SubagentStart` event (agent_id + agent_type; Claude Code
    /// v2.1.177+). Reconciliation trade-off: `PreToolUse` for the `Task`/`Agent`
    /// tool already creates a subagent card with a nice human-written title
    /// (from `description`), but *no* `agent_id` -- the subagent hasn't been
    /// assigned one yet at that point. `SubagentStart` arrives moments later
    /// with the real `agent_id` but only `agent_type` (no free-text
    /// description) to title a card with. Rather than show two cards for the
    /// same subagent, this "claims" the oldest still-unclaimed card from the
    /// *same session* (FIFO within a session, since parallel Task launches from
    /// one session can't be told apart any other way) by stamping its
    /// `agent_id` on it. Only when no such card exists (e.g. this Claude Code
    /// build sends `SubagentStart` without ever having sent a matching
    /// `PreToolUse` event to us, or the event arrived out of order) does it fall
    /// back to creating a fresh card titled from `agent_type` alone.
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
        let title = event.agentType.map { String(format: tr("Subagent: %@"), $0) } ?? tr("Subagent running")
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
            let context = [record.context, tr("recovered")].compactMap { $0 }.joined(separator: " · ")
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
            title: tr("Background: outcome unknown (tracking timed out)"),
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
            case .completed: return (tr("Background task done"), .done)
            case .failed: return (tr("Background task failed"), .failed)
            case .killed: return (tr("Background task stopped"), .failed)
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

    /// Dismisses one conversation's entire card (header ✕): every item of the
    /// session goes away and the session stays hidden until a newer hook
    /// event revives it. `key` is `SessionSummary.id` ("" = app-notice bucket).
    func dismissSession(key: String) {
        let sessionKey = key.isEmpty ? Self.noSessionKey : key
        dismissedSessions[sessionKey] = Date()
        // Closing the card takes its undelivered messages with it. Leaving them
        // queued meant a message could still arrive minutes later from a card
        // the user had already swept away, with nothing on screen to explain it.
        cancelQueuedReplies(forSession: sessionKey)
        func matches(_ item: TaskItem) -> Bool {
            (item.sessionId ?? Self.noSessionKey) == sessionKey
        }
        runningTasks.removeAll(where: matches)
        completedNotices.removeAll(where: matches)
        subagentTasks.removeAll(where: matches)
        backgroundTasks.removeAll(where: matches)
        updatePassthrough()
        persistInFlightSubagents()
    }

    /// Minimum time a completed card stays on screen before a focus event is
    /// allowed to auto-retire it. Without this grace, the desktop app
    /// refreshing `lastFocusedAt` the instant the user clicks into a
    /// just-finished conversation (to read the answer) hid the card within one
    /// 3s poll of it appearing — the "tasks are hidden" report. 12s is long
    /// enough that the user always registers the result first.
    private static let minCardOnScreenSeconds: TimeInterval = 12

    /// Pending grace-delayed auto-dismiss, one per session (see
    /// `markConversationViewed`). Cancelled/replaced when a newer focus for the
    /// same session arrives, and re-validated before it actually dismisses.
    private var pendingViewedDismiss: [String: Task<Void, Never>] = [:]

    /// Whether a focus at `focusDate` should retire this session's card: it is
    /// done (a completed notice is up, nothing still running) *and* the focus
    /// happened after the session's last event. The latter guards against the
    /// desktop app batch-bumping `lastFocusedAt` on its own restart, and means
    /// the user genuinely looked at the conversation after it finished.
    private func viewedDismissEligible(sessionId: String, focusDate: Date) -> Bool {
        // This rule predates the reply box, and the two collided: the card is
        // no longer only a notice, it is the ONLY place to type an answer. So
        // retiring it because the user is looking at the conversation would
        // take away the reply box at exactly the moment it is needed — and if
        // a Stop hook is being held, it strands that hook until its timeout
        // while nothing on screen says anything is waiting.
        //
        // "Done" therefore has to mean nobody is waiting on anybody, not
        // merely that no task is running.
        guard heldStops[sessionId] == nil else { return false }
        guard replyQueue[sessionId] == nil else { return false }
        guard sessions[sessionId]?.mood != .asking else { return false }

        func mine(_ items: [TaskItem]) -> [TaskItem] {
            items.filter { ($0.sessionId ?? Self.noSessionKey) == sessionId }
        }
        guard mine(runningTasks).isEmpty, mine(subagentTasks).isEmpty,
              mine(backgroundTasks).isEmpty else { return false }
        let completed = mine(completedNotices)
        guard !completed.isEmpty else { return false }
        // A question card is Claude waiting for a human; looking at the
        // conversation is not the same as answering it.
        guard !completed.contains(where: { $0.kind == .question }) else { return false }
        let lastEventAt = sessions[sessionId]?.lastEventAt
            ?? completed.map(\.startedAt).max() ?? .distantPast
        return focusDate > lastEventAt
    }

    /// The user focused this conversation in the Claude Code desktop app.
    /// Retires the session's card once it is done, but only after the card has
    /// been on screen at least `minCardOnScreenSeconds`: a focus arriving
    /// sooner schedules the dismiss for when the grace elapses instead of
    /// firing immediately, so a completed card is never yanked away the instant
    /// the user clicks into the conversation to read its result. The delayed
    /// dismiss re-checks eligibility before acting, so a fresh event that
    /// revived the card (or new work that started) cancels it.
    func markConversationViewed(sessionId: String, at focusDate: Date) {
        guard viewedDismissEligible(sessionId: sessionId, focusDate: focusDate) else { return }
        func mine(_ items: [TaskItem]) -> [TaskItem] {
            items.filter { ($0.sessionId ?? Self.noSessionKey) == sessionId }
        }
        let shownAt = mine(completedNotices).map(\.startedAt).max() ?? focusDate
        let remaining = Self.minCardOnScreenSeconds - Date().timeIntervalSince(shownAt)
        pendingViewedDismiss.removeValue(forKey: sessionId)?.cancel()
        guard remaining > 0 else {
            dismissSession(key: sessionId)
            return
        }
        pendingViewedDismiss[sessionId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.pendingViewedDismiss.removeValue(forKey: sessionId)
            guard self.viewedDismissEligible(sessionId: sessionId, focusDate: focusDate) else { return }
            self.dismissSession(key: sessionId)
        }
    }

    /// Enables click passthrough while notices, subagent/background cards or
    /// an ask are on screen (their manual ✕ must be clickable).
    private func updatePassthrough() {
        // `runningTasks` joins the list because every live session card now
        // carries a reply box, and a card built from a running task alone
        // would otherwise render a TextField the mouse falls straight through.
        onMousePassthroughNeeded?(
            !completedNotices.isEmpty || !subagentTasks.isEmpty
                || !backgroundTasks.isEmpty || !runningTasks.isEmpty || pendingAsk != nil)
    }

    /// Shows a short-lived app notice (connection, sprites) as a session card.
    /// Not tied to any Claude Code session, so its mood is bucketed under the
    /// synthetic "no session" key (see `setMood(_:for:)`).
    func notify(_ title: String, mood: Mood = .idle) {
        setMood(mood, for: nil)
        pushRunning(TaskItem(title: title, kind: .session))
    }

    // MARK: - Reply (delivered through the hooks, no extra transport)

    /// Claude Code has no API for "push text into a running session", but two
    /// hooks already carry text *to the model*: returning
    /// `hookSpecificOutput.additionalContext` from `Stop` re-invokes the model
    /// with that text instead of ending the turn, and the same shape on
    /// `PostToolUse` reaches it at the next tool boundary. That is the whole
    /// transport — which is why replying works identically in the terminal, the
    /// Desktop app and VS Code: they all read the same
    /// `~/.claude/settings.json`. See `HookServer.injectionBody` for why this
    /// and not `decision: "block"`.
    ///
    /// Two delivery moments, so a message is never stranded:
    ///  - **held `Stop`** — when a turn ends on a question (`QuestionDetector`),
    ///    the hook is kept open for `replyHoldSeconds` instead of returning
    ///    immediately. Typing then resumes that same turn.
    ///  - **queue** — anything typed at another moment waits here and goes out
    ///    at the next `PostToolUse`/`Stop` of that session.
    ///
    /// The one rule that must never be broken: **only ever block when there is
    /// a real message**. `stop_hook_active` looks like loop protection but is
    /// only advisory — Claude Code honours a second and third block just fine —
    /// so an unconditional block here would spin the session forever.
    ///
    /// sessionId -> the request id of that session's `Stop` hook being held.
    private var heldStops: [String: String] = [:]
    /// sessionId -> messages typed while nothing was held, oldest first.
    private var replyQueue: [String: [String]] = [:]
    /// sessionId -> outcome of its most recent message (shown on the card).
    private var replyStatuses: [String: ReplyStatus] = [:]
    /// Per-session auto-clear timers for `replyStatuses`.
    private var replyStatusClearTasks: [String: Task<Void, Never>] = [:]
    /// How long a status line stays on the card.
    private static let replyStatusTTL: TimeInterval = 20

    /// Prefix that tells Claude where the text came from. Without it the
    /// message arrives as bare "Stop hook feedback", which reads like a policy
    /// hook talking rather than the person at the keyboard.
    nonisolated private static let replyPreamble =
        "Message from the user, sent from the ClaudePet desktop app:"

    /// Wraps a typed message in the preamble. `nonisolated` so the hook server
    /// can build the response body on its own queue.
    nonisolated static func replyReason(for text: String) -> String {
        "\(replyPreamble)\n\n\(text)"
    }

    /// A `Stop` hook arrived. Registers the hold *before* `apply` so the
    /// settle below can never run first, then lets the normal Stop handling
    /// (cards, mood, `QuestionDetector`) proceed — `settleStop` decides from
    /// inside it whether the hold is kept.
    func presentStop(id: String, event: HookEvent) {
        // Two cases that must resolve immediately, or the hook hangs until the
        // server's timeout: an event `apply` drops on the floor (the pet's own
        // token-refresh runs), and anything that isn't actually a Stop.
        let isRealStop = (event.hookEventName ?? "") == "Stop"
            && event.projectName != UsageMonitor.refreshMarkerDirName
        guard let sid = event.sessionId, isRealStop else {
            apply(event)
            resolver?.resolveReply(id: id, text: nil)
            return
        }
        // One hold per session; a new Stop supersedes a stale one.
        if let previous = heldStops.removeValue(forKey: sid) {
            resolver?.resolveReply(id: previous, text: nil)
        }
        heldStops[sid] = id
        apply(event)
    }

    /// Called from `pushStopNotice` once the turn's reply text is known.
    /// Keeps the hold open only when Claude ended on a question — every other
    /// turn releases at once so the session isn't left looking busy.
    private func settleStop(sessionId: String?, isQuestion: Bool) {
        guard let sid = sessionId, let id = heldStops[sid] else { return }
        if let queued = dequeueReply(forSession: sid) {
            heldStops.removeValue(forKey: sid)
            resolver?.resolveReply(id: id, text: queued)
            setReplyStatus(.sent, forSession: sid)
            return
        }
        guard isQuestion else {
            heldStops.removeValue(forKey: sid)
            resolver?.resolveReply(id: id, text: nil)
            return
        }
        // Question: hold, and let the card show a live reply box.
    }

    /// The server's hold timed out (or the connection died): forget the hold
    /// so a later message queues instead of resolving a dead request.
    func cancelStop(id: String) {
        guard let sid = heldStops.first(where: { $0.value == id })?.key else { return }
        heldStops.removeValue(forKey: sid)
    }

    /// Sends a message typed on a session card. Goes out immediately when that
    /// session's `Stop` is being held, otherwise waits in the queue for the
    /// next hook of that session.
    func sendReply(_ text: String, forSession sessionId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessionId.isEmpty else { return }
        if let id = heldStops.removeValue(forKey: sessionId) {
            resolver?.resolveReply(id: id, text: trimmed)
            setReplyStatus(.sent, forSession: sessionId)
            logReply("typed, went straight into a held hook (\(trimmed.count) chars)",
                     for: sessionId)
        } else {
            logReply("typed, queued (\(trimmed.count) chars,"
                     + " mood \(sessions[sessionId]?.mood ?? .idle))", for: sessionId)
            replyQueue[sessionId, default: []].append(trimmed)
            setReplyStatus(.queued, forSession: sessionId)
            scheduleIdleDelivery(forSession: sessionId)
        }
    }

    /// Gives the hook path first refusal on a queued message, then delivers it
    /// by hand if nothing came to collect it.
    ///
    /// The hook path is the better one wherever it is available — no window is
    /// touched and no focus is stolen — but it only exists while a session is
    /// still running. A session that has finished its turn fires nothing at all
    /// until the user types, so its messages would sit in the queue forever.
    ///
    /// Deciding between the two by mood was wrong, and this is the bug it
    /// caused: mood is a snapshot of the **last event seen**, so a session that
    /// has been sitting idle for an hour still reads `working` from the turn
    /// before, and its message was queued and never delivered. Mood is only a
    /// hint about how long to wait now — a session that looks busy is given
    /// longer for a hook to turn up, and either way the message goes out.
    private func scheduleIdleDelivery(forSession sessionId: String, attempt: Int = 1) {
        let mood = sessions[sessionId]?.mood ?? .idle
        let grace: Double = attempt > 1 ? 6 : ((mood == .working || mood == .thinking) ? 12 : 1.5)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self else { return }
            // Anything a hook already collected is gone from the queue, so
            // there is nothing here to deliver twice. The same check is what
            // makes the retry below safe: a delivery in flight has taken its
            // message out of the queue, so this finds nothing and stands down.
            guard self.replyQueue[sessionId]?.isEmpty == false else { return }
            guard self.heldStops[sessionId] == nil else { return }
            self.deliverToIdleSession(sessionId)
            // One retry. Driving another app's window is timing-dependent — the
            // panel may still be building, or the user may have clicked
            // somewhere mid-flight — and for an idle session a single failure
            // is permanent: no hook will ever come to carry the message
            // instead.
            if attempt < 2 {
                self.scheduleIdleDelivery(forSession: sessionId, attempt: attempt + 1)
            }
        }
    }

    /// Last-resort delivery for an idle conversation: type it into the Claude
    /// Desktop app. Only ever *drains* the queue when the write is confirmed,
    /// so a failure leaves the message waiting for the next hook instead of
    /// silently losing it.
    /// Routes an idle session's message to whichever surface actually hosts
    /// it, as recorded in its own transcript (`SessionOrigin`).
    ///
    /// This used to be a guess — try the terminal if a tty is known, otherwise
    /// offer the message to every window-driving host in turn — and the guess
    /// was not survivable. Offering a session id to VS Code that its extension
    /// cannot place makes it open a **new conversation** and put the reply
    /// there, so a terminal session that the pet failed to reach by tty could
    /// end up starting a stray VS Code session. Each surface is now asked only
    /// about sessions it actually owns.
    private func deliverToIdleSession(_ sessionId: String) {
        let origin = SessionOrigin.read(transcriptPath: sessionMeta[sessionId]?.transcriptPath)
        switch origin.surface {
        case .cli:
            guard let tty = resolvedTty(forSession: sessionId) else {
                noteAttempt("terminal session, but no scriptable terminal owns it", for: sessionId)
                setReplyStatus(.stuck, forSession: sessionId)
                return
            }
            deliverViaTerminal(forSession: sessionId, tty: tty, thenTryHosts: false)
        case .vscode:
            deliverViaVSCode(forSession: sessionId, workspace: origin.cwd)
        case .desktop:
            deliverViaDesktop(forSession: sessionId)
        case .unknown:
            // No transcript, or one too old to carry an entrypoint. The two
            // surfaces that refuse harmlessly when a session isn't theirs.
            if let tty = resolvedTty(forSession: sessionId) {
                deliverViaTerminal(forSession: sessionId, tty: tty, thenTryHosts: true)
            } else {
                deliverViaDesktop(forSession: sessionId)
            }
        }
    }

    /// The session's tty: what the hook reported, or — when it never did —
    /// worked out from the running `claude` processes. The second path matters
    /// precisely here: an idle session emits no events, so a pet restart (or a
    /// session that last spoke to an older hook script) leaves the reported
    /// value nil for exactly the sessions this feature exists to reach.
    private func resolvedTty(forSession sessionId: String) -> String? {
        if let known = sessionMeta[sessionId]?.tty { return known }
        guard let transcript = sessionMeta[sessionId]?.transcriptPath else { return nil }
        let folder = URL(fileURLWithPath: transcript).deletingLastPathComponent().lastPathComponent
        guard let found = TerminalBridge.discoverTty(projectFolder: folder) else { return nil }
        sessionMeta[sessionId]?.tty = found
        return found
    }

    private func deliverViaTerminal(
        forSession sessionId: String, tty: String, thenTryHosts: Bool
    ) {
        let cancelToken = replyCancelToken[sessionId, default: 0]
        guard let text = dequeueReply(forSession: sessionId) else {
            noteAttempt("skipped: nothing queued", for: sessionId)
            return
        }
        noteAttempt("trying terminal \(tty)", for: sessionId)
        Task { [weak self] in
            let result = await Task.detached { TerminalBridge.send(text, toTty: tty) }.value
            guard let self else { return }
            switch result {
            case .success:
                self.setReplyStatus(.sent, forSession: sessionId)
                self.noteAttempt("delivered to terminal \(tty)", for: sessionId)
            case .failure(let error):
                self.requeueReply(text, forSession: sessionId, unlessCancelledSince: cancelToken)
                self.noteAttempt("terminal \(tty) failed: \(error)", for: sessionId)
                // A tty the pet cannot script (VS Code's integrated terminal,
                // Ghostty, kitty…) has no idle route at all. Only a session of
                // unknown origin is worth offering to the hosts after this; a
                // transcript that says `cli` has already ruled them out.
                if thenTryHosts {
                    self.deliverViaDesktop(forSession: sessionId)
                } else {
                    // A tty that no scriptable terminal owns is usually VS
                    // Code's integrated one — the tty is real, the terminal
                    // just isn't AppleScript-able.
                    self.deliverViaVSCodeTerminal(forSession: sessionId, tty: tty)
                }
            }
        }
    }

    /// Host apps whose prompt the pet can drive, tried in order. Each one is
    /// asked whether it owns a conversation by this name; the first that says
    /// yes takes the message, and a host that doesn't recognise it fails with
    /// `conversationNotFound` and costs nothing.
    private static let promptHosts: [(name: String, bundle: String)] = [
        ("Claude Desktop", DesktopAX.bundleID),
    ]

    private func deliverViaDesktop(forSession sessionId: String) {
        guard DesktopAX.isTrusted else {
            reportMissingAccessibility(for: sessionId)
            return
        }
        guard let title = sessionMeta[sessionId]?.name else {
            noteAttempt("skipped: no resolved conversation name for this session",
                        for: sessionId)
            return
        }
        let cancelToken = replyCancelToken[sessionId, default: 0]
        guard let text = dequeueReply(forSession: sessionId) else {
            noteAttempt("skipped: nothing queued", for: sessionId)
            return
        }
        noteAttempt("trying: \(title)", for: sessionId)
        let hosts = Self.promptHosts
        Task { [weak self] in
            let outcome = await Task.detached { () -> (String, Bool) in
                var notes: [String] = []
                for host in hosts {
                    switch DesktopAX.send(text, toConversationTitled: title, bundle: host.bundle) {
                    case .success(let channel):
                        return ("delivered to \(title) via \(host.name) (\(channel))", true)
                    case .failure(let error):
                        notes.append("\(host.name): \(error)")
                    }
                }
                return ("no host took \(title) — " + notes.joined(separator: "; "), false)
            }.value
            guard let self else { return }
            if outcome.1 {
                self.setReplyStatus(.sent, forSession: sessionId)
            } else {
                self.requeueReply(text, forSession: sessionId, unlessCancelledSince: cancelToken)
                self.setReplyStatus(.stuck, forSession: sessionId)
            }
            // On failure the message goes back in the queue on purpose: the
            // next hook still gets to deliver it.
            self.noteAttempt(outcome.0, for: sessionId)
        }
    }

    /// Delivery into a VS Code extension session. Addressed by **session id**,
    /// the only exact identifier any of these surfaces accepts — the others
    /// have to match a conversation title and refuse when it is ambiguous.
    /// Hands the message to the bundled VS Code extension, which calls VS Code's
    /// own `Terminal.sendText` and writes straight into the pty. Returns whether
    /// it landed.
    ///
    /// Every other idle route drives a window and therefore needs Accessibility;
    /// this one is a loopback HTTP call and needs **nothing**. So it is tried
    /// before any trust check — a machine that never granted Accessibility can
    /// still reach every session running in VS Code's terminal, which is where
    /// the pet's own author runs Claude Code.
    private func tryVSCodeBridge(forSession sessionId: String, tty: String) -> Bool {
        guard let text = replyQueue[sessionId]?.first else { return false }
        switch VSCodeBridge.send(text, toTty: tty) {
        case .success(let name):
            _ = dequeueReply(forSession: sessionId)
            setReplyStatus(.sent, forSession: sessionId)
            noteAttempt("delivered to \(name) via the VS Code bridge extension",
                        for: sessionId)
            return true
        case .failure(let error):
            noteAttempt("bridge extension: \(error)", for: sessionId)
            return false
        }
    }

    private func deliverViaVSCode(forSession sessionId: String, workspace: String?) {
        // A `claude-vscode` session may be running in the integrated terminal
        // rather than the extension panel, and the two are told apart only by
        // trying. The bridge goes first because it costs one loopback request
        // and, unlike everything below, works with no permissions at all.
        if let tty = resolvedTty(forSession: sessionId),
           tryVSCodeBridge(forSession: sessionId, tty: tty) { return }
        guard DesktopAX.isTrusted else {
            reportMissingAccessibility(for: sessionId)
            return
        }
        let cancelToken = replyCancelToken[sessionId, default: 0]
        guard let text = dequeueReply(forSession: sessionId) else {
            noteAttempt("skipped: nothing queued", for: sessionId)
            return
        }
        let label = sessionMeta[sessionId]?.name ?? String(sessionId.prefix(8))
        noteAttempt("trying VS Code: \(label)", for: sessionId)
        Task { [weak self] in
            let result = await Task.detached {
                DesktopAX.sendToVSCode(text, sessionId: sessionId, workspace: workspace,
                                       conversation: label)
            }.value
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.setReplyStatus(.sent, forSession: sessionId)
                self.noteAttempt("delivered to \(label) via VS Code (\(channel))",
                                 for: sessionId)
            case .failure(let error):
                // Back in the queue: the next hook this session fires can
                // still carry it.
                self.requeueReply(text, forSession: sessionId, unlessCancelledSince: cancelToken)
                self.setReplyStatus(.stuck, forSession: sessionId)
                self.noteAttempt("VS Code \(label) failed: \(error)", for: sessionId)
            }
        }
    }

    /// Types into a session running in VS Code's integrated terminal.
    ///
    /// Alone among the surfaces this one cannot be read back — the terminal is
    /// not in the accessibility tree — so `DesktopAX` can only report that the
    /// keys were sent. The confirmation comes from the session instead: a
    /// message that landed makes Claude Code fire `UserPromptSubmit` within a
    /// second or two, and that event arrives through the hook already
    /// installed. No event means the keys went nowhere useful.
    private func deliverViaVSCodeTerminal(forSession sessionId: String, tty: String) {
        if tryVSCodeBridge(forSession: sessionId, tty: tty) { return }
        guard DesktopAX.isTrusted else {
            reportMissingAccessibility(for: sessionId)
            return
        }
        // Found by the title CLAUDE CODE gave the session, not by the pet's own
        // name for it — the two are different strings and only the first is on
        // screen.
        let origin = SessionOrigin.read(transcriptPath: sessionMeta[sessionId]?.transcriptPath)
        guard let name = origin.terminalTitle else {
            noteAttempt("skipped: transcript has no ai-title to find the terminal by",
                        for: sessionId)
            setReplyStatus(.stuck, forSession: sessionId)
            return
        }
        let cancelToken = replyCancelToken[sessionId, default: 0]
        guard let text = dequeueReply(forSession: sessionId) else {
            noteAttempt("skipped: nothing queued", for: sessionId)
            return
        }
        noteAttempt("trying VS Code terminal: \(name)", for: sessionId)
        Task { [weak self] in
            guard let self else { return }
            let before = self.sessions[sessionId]?.lastEventAt
            let result = await Task.detached {
                DesktopAX.sendToVSCodeTerminal(text, sessionName: name)
            }.value
            if case .failure(let error) = result {
                self.noteAttempt("VS Code terminal \(name) failed: \(error)", for: sessionId)
                self.requeueReply(text, forSession: sessionId, unlessCancelledSince: cancelToken)
                self.setReplyStatus(.stuck, forSession: sessionId)
                return
            }
            try? await Task.sleep(for: .seconds(6))
            if let after = self.sessions[sessionId]?.lastEventAt, after != before {
                self.setReplyStatus(.sent, forSession: sessionId)
                self.noteAttempt("delivered to \(name) via VS Code terminal"
                                 + " (confirmed by the session's own hook)", for: sessionId)
            } else {
                self.noteAttempt("VS Code terminal \(name): keys sent, no hook followed",
                                 for: sessionId)
                self.requeueReply(text, forSession: sessionId, unlessCancelledSince: cancelToken)
                self.setReplyStatus(.stuck, forSession: sessionId)
            }
        }
    }

    /// What happened on the most recent delivery attempt, surfaced in
    /// `/debug/state`. Every abort path above writes here — silent skips made
    /// the first round of testing unreadable.
    private(set) var lastDesktopAttempt: String?

    /// The same note, but kept per session.
    ///
    /// One shared field was not enough to debug with: several sessions can be
    /// queued at once, so the note explaining why a message did not go out gets
    /// overwritten by the next session's attempt before anyone reads it. That
    /// happened on the first real failure report and left nothing to go on.
    private(set) var replyAttempts: [String: String] = [:]

    /// One line of the user-facing send log.
    struct ReplyLogEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        /// The conversation's card name, so the log reads like the UI rather
        /// than like a session id.
        let session: String
        let note: String
    }

    /// The last `replyLogLimit` things that happened to messages typed on a
    /// card, newest first.
    ///
    /// `events.log` has had all of this since the feature existed, but only on
    /// disk: the card shows three words ("Sent"/"Queued"/"Can't reach") and
    /// nothing about **where** a message went or **why** it didn't. That is
    /// exactly what is needed when delivery works on one machine and not on
    /// another — so the same lines are kept in memory and shown in Settings,
    /// with a button that copies them for pasting into a bug report.
    ///
    /// Message *text* is deliberately never stored — only its length. The log
    /// is for routing, and a window listing everything the user has ever typed
    /// into their agent is not something to leave lying around.
    private(set) var replyLog: [ReplyLogEntry] = []
    private static let replyLogLimit = 80

    /// Writes one line to both logs: `events.log` (timestamped, permanent) and
    /// the in-memory ring the Settings window shows.
    private func logReply(_ note: String, for sessionId: String) {
        appendLog("reply session=\(Self.shortId(sessionId)) \(note)")
        replyLog.insert(ReplyLogEntry(at: Date(),
                                      session: displayName(forKey: sessionId),
                                      note: note), at: 0)
        if replyLog.count > Self.replyLogLimit { replyLog.removeLast() }
    }

    /// The whole log as text, for the "Copy" button.
    func replyLogText() -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return replyLog.reversed()
            .map { "\(stamp.string(from: $0.at))  [\($0.session)] \($0.note)" }
            .joined(separator: "\n")
    }

    /// Whether the pet has already shown macOS's Accessibility prompt this run.
    /// Asking once per message would be a permission-dialog machine gun.
    private var didAskForAccessibility = false

    /// The chosen route drives another app's window and the pet is not trusted.
    ///
    /// Silence here was the bug: the message stayed on the card as "Queued",
    /// which reads as "arriving shortly" when in fact nothing would ever carry
    /// it, and macOS never asks for a permission an app does not request. Now
    /// the card says what is missing and the system prompt comes up once —
    /// right after the user pressed send, which is the only moment the request
    /// makes sense to them.
    private func reportMissingAccessibility(for sessionId: String) {
        noteAttempt("skipped: Accessibility not granted"
                    + (didAskForAccessibility ? "" : " — asking for it now"),
                    for: sessionId)
        setReplyStatus(.needsAccess, forSession: sessionId)
        guard !didAskForAccessibility else { return }
        didAskForAccessibility = true
        DesktopAX.requestTrust()
    }

    /// Watches for the Accessibility switch being flipped, so what is waiting
    /// can go out. nil when nothing is watching.
    @ObservationIgnored private var accessibilityWatch: Task<Void, Never>?

    /// Sends the user to the Accessibility switch and picks the delivery back
    /// up once they flip it.
    ///
    /// Without the second half, granting the permission fixed nothing you could
    /// see: an idle session fires no hooks, so the message that prompted the
    /// request would sit in the queue until something else happened to that
    /// conversation — which, for an idle one, may be never.
    func grantAccessibilityThenRetry() {
        Self.openAccessibilitySettings()
        guard accessibilityWatch == nil else { return }
        accessibilityWatch = Task { [weak self] in
            // Two minutes of two-second checks: long enough to find the switch
            // in System Settings, short enough not to poll forever.
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard DesktopAX.isTrusted else { continue }
                self.accessibilityWatch = nil
                for (sid, queue) in self.replyQueue where !queue.isEmpty {
                    self.noteAttempt("Accessibility granted — retrying", for: sid)
                    self.scheduleIdleDelivery(forSession: sid)
                }
                return
            }
            self?.accessibilityWatch = nil
        }
    }

    /// Opens System Settings at the Accessibility list (the card's status line
    /// is a button once the permission is what's missing).
    static func openAccessibilitySettings() {
        DesktopAX.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func noteAttempt(_ note: String, for sessionId: String) {
        lastDesktopAttempt = note
        replyAttempts[sessionId] = note
        // Also to the logs, because the map above only keeps the LATEST note
        // per session and has no clock. A failure followed by a success reads
        // exactly like a session that never failed — which is precisely the
        // question "it works sometimes" needs answered. The log has timestamps
        // and keeps the whole run.
        logReply(note, for: sessionId)
    }

    private static func shortId(_ sessionId: String) -> String {
        String(sessionId.prefix(8))
    }

    /// Where a conversation lives, for the card label. A plain lookup: the
    /// answer is worked out when the event arrives (`rememberSessionMeta`),
    /// never here — this is called from inside a view body, where reading a
    /// file would cost a 512KB parse per redraw and writing the result back
    /// would mutate observed state mid-draw.
    ///
    /// Delivery deliberately does NOT use this cache: a session that gets
    /// resumed somewhere else changes surface, and routing a message by a
    /// stale answer is how a reply ends up in the wrong window.
    private func surface(forKey key: String) -> SessionSurface {
        sessionMeta[key]?.surface ?? .unknown
    }

    /// Throws away everything still queued for a session.
    ///
    /// Without this a failed delivery was a trap: the text goes back in the
    /// queue, the card says "stuck", and the natural reaction — type it again,
    /// or go say it in the terminal — meant Claude eventually received the same
    /// instruction twice, oldest first. There has to be a way to take it back.
    func cancelQueuedReplies(forSession sessionId: String) {
        // Bumped even when the queue looks empty: a delivery in flight is
        // holding its message *outside* the queue and would otherwise put it
        // back the moment it failed, resurrecting the very message that was
        // just discarded.
        replyCancelToken[sessionId, default: 0] += 1
        guard let pending = replyQueue.removeValue(forKey: sessionId), !pending.isEmpty else { return }
        replyStatuses.removeValue(forKey: sessionId)
        replyStatusClearTasks.removeValue(forKey: sessionId)?.cancel()
        logReply("cancelled \(pending.count) queued message(s)", for: sessionId)
    }

    /// Pops the next queued message for a session (used by the `PostToolUse`
    /// route). Returns nil — never blocks — when the queue is empty.
    func takeQueuedReply(forSession sessionId: String?) -> String? {
        guard let sid = sessionId, let text = dequeueReply(forSession: sid) else { return nil }
        setReplyStatus(.sent, forSession: sid)
        logReply("collected by a hook (\(text.count) chars)", for: sid)
        return text
    }

    /// Puts a message back at the head of the queue after a failed delivery.
    ///
    /// Delivery takes the message OUT of the queue before it starts, because
    /// typing it into a window takes seconds and a hook arriving in the middle
    /// would otherwise collect the same message and send it twice. Whatever
    /// fails then has to hand it back.
    private func requeueReply(_ text: String, forSession sessionId: String) {
        replyQueue[sessionId, default: []].insert(text, at: 0)
    }

    /// Puts a message back only if it wasn't discarded while the delivery was
    /// running. `token` is what `replyCancelToken` said when the message left
    /// the queue.
    private func requeueReply(_ text: String, forSession sessionId: String, unlessCancelledSince token: Int) {
        guard replyCancelToken[sessionId, default: 0] == token else {
            logReply("delivery failed, but the message had been discarded — dropping it",
                     for: sessionId)
            return
        }
        requeueReply(text, forSession: sessionId)
    }

    /// Bumped every time the user discards a session's queue; see
    /// `requeueReply(_:forSession:unlessCancelledSince:)`.
    private var replyCancelToken: [String: Int] = [:]

    private func dequeueReply(forSession sessionId: String) -> String? {
        guard var pending = replyQueue[sessionId], !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        if pending.isEmpty { replyQueue.removeValue(forKey: sessionId) }
        else { replyQueue[sessionId] = pending }
        return next
    }

    /// How long a `Stop` may be held waiting for the user. Same live-override
    /// mechanism as the decay timings so tests can shorten it on a running app.
    var replyHoldSeconds: TimeInterval {
        Self.configOverride(key: "replyHoldSeconds") ?? 120
    }

    private func setReplyStatus(_ status: ReplyStatus, forSession sessionId: String) {
        replyStatuses[sessionId] = status
        replyStatusClearTasks[sessionId]?.cancel()
        // Only an *outcome* fades. "Stuck" and "needs permission" describe the
        // message's current state — clearing them on a timer left a card that
        // looked like nothing had ever been typed while the message sat in the
        // queue. They go when the queue does.
        guard status != .stuck, status != .needsAccess else {
            replyStatusClearTasks.removeValue(forKey: sessionId)
            return
        }
        replyStatusClearTasks[sessionId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.replyStatusTTL))
            guard !Task.isCancelled else { return }
            self?.clearReplyState(forSession: sessionId, keepQueue: true)
        }
    }

    /// Drops a session's reply state. `keepQueue` distinguishes the status
    /// line expiring (queue must survive — the message hasn't been delivered
    /// yet) from the session ending (everything goes).
    private func clearReplyState(forSession sessionId: String, keepQueue: Bool) {
        replyStatuses.removeValue(forKey: sessionId)
        replyStatusClearTasks.removeValue(forKey: sessionId)?.cancel()
        guard !keepQueue else { return }
        // Say so: the card's waiting chip is about to disappear, and "the
        // conversation ended before your message went out" is the only honest
        // explanation for that.
        if let dropped = replyQueue.removeValue(forKey: sessionId), !dropped.isEmpty {
            logReply("session ended with \(dropped.count) message(s) undelivered", for: sessionId)
        }
        if let id = heldStops.removeValue(forKey: sessionId) {
            resolver?.resolveReply(id: id, text: nil)
        }
    }

    // MARK: - Hook events

    /// Appends one line per received event to ~/.petmacos/events.log so hook
    /// delivery can be debugged (which events arrive, from which agent).
    private func logEvent(_ event: HookEvent, route: String) {
        lastEventAt = Date()
        appendLog("\(route) \(event.hookEventName ?? "?")"
            + " tool=\(event.toolName ?? "-")"
            + " agent=\(event.agentId ?? "-")/\(event.agentType ?? "-")"
            + " cwd=\(event.projectName ?? "-")")
    }

    /// Records what happened to a permission ask (`allow`/`deny`/`timeout`) so
    /// a "pet didn't show it" report can be told apart from "shown but answered
    /// elsewhere / timed out". `outcome` is the resolution; `queued` is how many
    /// asks were already ahead of it (i.e. it wasn't the visible one).
    private func logAskOutcome(_ ask: PendingAsk, outcome: String, queuedAhead: Int) {
        appendLog("ask-\(outcome) tool=\(ask.toolName)"
            + " session=\(ask.sessionId ?? "-")"
            + (queuedAhead > 0 ? " queuedAhead=\(queuedAhead)" : ""))
    }

    /// The log file, also reachable from Settings ("Show events.log").
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".petmacos/events.log")
    /// Hard ceiling; on breach the oldest half is dropped (see `appendLog`) so
    /// recent history survives instead of the whole file being wiped.
    private static let maxLogSize = 1_000_000
    private static let logTrimTo = 500_000

    /// Appends one timestamped line to events.log, trimming the file from the
    /// front when it grows past `maxLogSize` so it stays bounded without ever
    /// discarding the most recent lines (which is exactly what a live bug
    /// report needs).
    private func appendLog(_ body: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(body)\n"
        let url = Self.logURL
        if Self.fileSize(path: url.path) > UInt64(Self.maxLogSize),
           let data = try? Data(contentsOf: url), data.count > Self.logTrimTo {
            // Keep the last `logTrimTo` bytes, realigned to the next line start.
            var tail = data.suffix(Self.logTrimTo)
            if let nl = tail.firstIndex(of: 0x0A) {
                tail = tail[(nl + 1)...]
            }
            try? Data(tail).write(to: url, options: .atomic)
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
        if let sessionId = event.sessionId,
           let name = sessionNames.name(for: sessionId, cwd: event.cwd, transcriptPath: event.transcriptPath) {
            tab = name
        } else {
            tab = event.sessionTag.map { "#\($0)" }
        }
        // The session's first-seen project, not this event's `cwd` — see
        // `rememberSessionMeta` for why they drift apart.
        let project = event.sessionId.flatMap { sessionMeta[$0]?.project } ?? event.projectName
        let parts = [project, tab].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Applies an incoming hook event to the pet's presentation.
    func apply(_ event: HookEvent) {
        // The pet's own plumbing: UsageMonitor renews the OAuth token by
        // spawning a hidden `claude` run inside a marker folder. Its hook
        // events would otherwise paint a phantom conversation card.
        if event.projectName == UsageMonitor.refreshMarkerDirName { return }
        logEvent(event, route: "event")
        rememberSessionMeta(for: event)
        let context = contextLabel(for: event)
        let sid = event.sessionId
        switch event.hookEventName ?? "" {
        case "UserPromptSubmit":
            setMood(.thinking, for: sid)
            pushRunning(TaskItem(title: tr("Thinking…"), kind: .thinking, context: context, sessionId: sid))
        case "PreToolUse":
            // Fires in every permission mode now that it is only a card feed;
            // approval lives on the PermissionRequest hook.
            setMood(.working, for: sid)
            // Tools running inside a subagent are internal noise; the parent
            // subagent card already represents the work.
            if event.isFromSubagent { return }
            if event.toolName == "Task" || event.toolName == "Agent" {
                // A subagent is starting: keep its card until SubagentStop. This
                // runs before the permission check, so the launch could still be
                // denied — `resolve` retires the card in that case.
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
            if let taskId = event.backgroundTaskId, let path = event.transcriptPath {
                startBackgroundTask(
                    taskId: taskId,
                    title: String(format: tr("Background: %@"), event.intentTitle),
                    detail: event.intentDetail.map { truncate($0) },
                    context: context,
                    transcriptPath: path,
                    sessionId: sid
                )
            }
        case "Notification":
            setMood(.asking, for: sid)
            pushRunning(TaskItem(title: event.message ?? tr("Claude needs attention"),
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
            clearRunning(sessionId: sid)
            // The mood is decided inside `pushStopNotice`, not here: a turn
            // that ended in a question is Claude *waiting*, not Claude done,
            // and that is only knowable once the reply text is in hand (it may
            // still have to be read from the transcript).
            pushStopNotice(for: event)
        case "SubagentStart":
            // New in Claude Code v2.1.177+: carries the real agent_id/agent_type
            // for a subagent that's about to start, and creates its card — see
            // `handleSubagentStart` for why the card is made here rather than at
            // `PreToolUse`.
            setMood(.working, for: sid)
            handleSubagentStart(event)
        case "SubagentStop":
            let card = finishSubagent(agentId: event.agentId, sessionId: event.sessionId)
            // A stop that retired nothing while carrying an id belongs to a
            // hidden internal agent -- no card of ours, so no mood flip and no
            // "finished" notice either (it used to fabricate one mid-run).
            guard card != nil || event.agentId == nil else { break }
            setMood(subagentTasks.isEmpty ? .talking : .working, for: sid)
            let title = event.agentType.map { String(format: tr("Subagent %@ finished"), $0) }
                ?? tr("Subagent finished")
            // Fall back to the launch card's purpose when the stop event carries
            // no final message, so the notice still says what the work was.
            let detail = event.lastAssistantMessage.map { truncate($0, limit: Self.completedDetailLimit) }
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
            // Nothing can deliver a queued message to a conversation that has
            // ended, and a still-held Stop must be released or its hook sits
            // there until the server's timeout.
            if let sid { clearReplyState(forSession: sid, keepQueue: false) }
            pruneMetaIfUnused(sessionId: sid)
        default:
            if let message = event.message {
                pushRunning(TaskItem(title: message, kind: .session, context: context, sessionId: sid))
            }
        }
    }

    /// Builds the persistent running card for a Task/Agent launch. No
    /// `agent_id` is available yet at this point (`PreToolUse` precedes the
    /// subagent actually starting) — `sessionId` is stamped instead so a later
    /// `SubagentStart` can claim this exact card (see `handleSubagentStart`),
    /// or so `resolve` can retire it if the launch is denied.
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
            let isQuestion = QuestionDetector.looksLikeQuestion(text ?? "")
            // Runs on both paths below and exactly once per Stop, which is what
            // lets it own the held hook's fate — see `settleStop`.
            settleStop(sessionId: sid, isQuestion: isQuestion)
            if isQuestion {
                // No "happy" burst and no decay back to idle: the pet stays in
                // `.asking` until the user actually answers (the next
                // UserPromptSubmit), which is the whole point of the card.
                setMood(.asking, for: sid)
            } else if subagentTasks.isEmpty && backgroundTasks.isEmpty {
                happyID = UUID()
                setMood(.talking, for: sid)
            } else {
                setMood(.working, for: sid)
            }
            pushCompleted(TaskItem(
                title: isQuestion ? tr("Claude is waiting for your answer") : tr("Completed"),
                detail: truncate(text ?? tr("Claude replied"), limit: Self.completedDetailLimit),
                kind: isQuestion ? .question : .done,
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

    /// Presents a permission request. It arrives from the `PermissionRequest`
    /// hook, which fires only when Claude Code was about to raise a dialog
    /// itself, so anything reaching here genuinely needs a human. When an
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
        setMood(.asking, for: event.sessionId)
        let ask = PendingAsk(
            id: id,
            toolName: event.toolName ?? "Tool",
            summary: event.toolInputSummary.map { truncate($0) },
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
        if let sessionId = event.sessionId,
           let name = sessionNames.name(for: sessionId, cwd: event.cwd, transcriptPath: event.transcriptPath) {
            return name
        }
        return event.sessionTag.map { "#\($0)" }
    }

    /// Sends the user's decision back to the waiting hook and clears the
    /// dialog, then shows the next queued ask (if any).
    func resolve(_ decision: String) {
        guard let ask = askQueue.first else { return }
        askQueue.removeFirst()
        logAskOutcome(ask, outcome: decision, queuedAhead: 0)
        resolver?.resolveAsk(id: ask.id, decision: PetDecision(decision: decision))
        if decision == "deny" { retireDeniedCard(for: ask) }
        setMood(.idle, for: ask.sessionId)
        presentNextAskOrDismiss()
    }

    /// Drops the card `PreToolUse` optimistically created for a launch the user
    /// then denied. Only subagents need this: an ordinary tool card ages out on
    /// its own TTL, but a subagent card lives until `SubagentStop` -- which
    /// never comes for a subagent that was never allowed to run, so the card
    /// would sit there forever.
    ///
    /// Matches the newest unclaimed card of the session (no `agent_id` yet, so
    /// it never steals one a `SubagentStart` already claimed). Newest, because
    /// the denied launch is the most recent one; with several parallel Task
    /// launches from one session there is nothing finer to match on -- the same
    /// limitation `handleSubagentStart` has going the other way.
    private func retireDeniedCard(for ask: PendingAsk) {
        guard ask.toolName == "Task" || ask.toolName == "Agent" else { return }
        guard let index = subagentTasks.lastIndex(where: {
            $0.agentId == nil && $0.sessionId == ask.sessionId
        }) else { return }
        subagentTasks.remove(at: index)
        persistInFlightSubagents()
    }

    /// Called by the server if a request times out or the connection drops.
    /// Removes the ask wherever it sits in the queue -- not just when it's
    /// the one currently shown -- since a queued-but-not-yet-displayed ask
    /// can also hit its own timeout while waiting in line.
    func cancelAsk(id: String) {
        guard let index = askQueue.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = index == 0
        let ask = askQueue.remove(at: index)
        // Timed out after `askTimeout` (300s) with no click: the user either
        // never saw the pet dialog or answered on Claude Code's own dialog.
        logAskOutcome(ask, outcome: "timeout", queuedAhead: index)
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

    /// Cap for a completed notice's message. The card shows the full stored
    /// text when expanded, so this only guards against pathological transcripts
    /// (a plain reply never gets near it).
    private static let completedDetailLimit = 4000

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
        /// Session ids whose `Stop` hook the pet is holding open right now,
        /// waiting for the user to type an answer.
        let heldStopSessions: [String]
        /// Session ids with at least one message still waiting to be delivered
        /// at the next hook boundary.
        let queuedReplySessions: [String]
        /// Each card's reply status ("sent"/"queued"), aligned with
        /// `sessionOrder`; nil where the card shows none.
        let sessionReplyStatuses: [String?]
        /// Whether the pet holds Accessibility rights — the Desktop fallback
        /// needs them.
        let desktopTrusted: Bool
        /// How many times the menu bar icon has been rebuilt since launch.
        /// A rate, not a value: divide two readings to see whether the status
        /// item is being redrawn when nothing about it changed.
        let menuBarRedraws: Int
        /// Outcome of the most recent Desktop delivery attempt, if any. Every
        /// abort path writes here; silent skips made the first round of
        /// testing unreadable.
        let lastDesktopAttempt: String?
        /// Per-session delivery notes, `"<sessionId>: <note>"` sorted by id.
        let replyAttempts: [String]
        /// Which surface each card reports, aligned with `sessionOrder`.
        let sessionSurfaces: [String]
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
            sessionNames: summaries.map(\.name),
            heldStopSessions: heldStops.keys.sorted(),
            queuedReplySessions: replyQueue.keys.sorted(),
            sessionReplyStatuses: summaries.map { $0.replyStatus.map { String(describing: $0) } },
            desktopTrusted: DesktopAX.isTrusted,
            menuBarRedraws: MenuBarIcon.redraws,
            lastDesktopAttempt: lastDesktopAttempt,
            replyAttempts: replyAttempts.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" },
            sessionSurfaces: summaries.map { $0.surface.rawValue }
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
