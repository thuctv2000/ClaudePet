import Foundation

/// Resolves a Claude Code `session_id` to the human-readable name of that
/// conversation, sourced from `~/.claude/history.jsonl` -- the same file the
/// `claude --resume` picker reads its list from. Each line is one submitted
/// prompt:
///
///     {"display":"...","pastedContents":{...},"timestamp":123,"project":"...","sessionId":"..."}
///
/// appended in chronological (monotonically increasing `timestamp`) order as
/// the user submits prompts, across every session on the machine. The
/// *first* line for a given `sessionId` is that session's name in the resume
/// picker, so resolving a name reduces to "find the first line whose
/// sessionId matches" and cleaning up its `display` text.
///
/// ## Read strategy: scan-once, tail-after
///
/// The file only grows by appends, lines are already ordered by write time,
/// and a session's first occurrence never needs re-reading once seen. So this
/// keeps one monotonic `scannedOffset` (mirroring
/// `PetState.scanTaskNotifications`'s incremental-tail pattern) and, on a
/// cache miss, scans only the bytes appended since the last scan -- filling
/// in a name (or `nil` for "seen but unusable", e.g. pasted-content-only
/// prompts) for every *new* session id encountered, first occurrence only.
/// The very first lookup pays for scanning the whole file once (a few
/// thousand short lines -- negligible); every lookup after that only re-reads
/// what was appended meanwhile.
///
/// ## Avoiding permanent misses for brand-new sessions
///
/// A pet card can be created from a hook event for a session whose first
/// prompt hasn't made it into `history.jsonl` yet (Claude Code appends it
/// asynchronously). So a miss must not be cached forever. Instead of a TTL,
/// a miss is only worth re-scanning when the file has actually grown past
/// `scannedOffset` -- a single `stat(2)` (`PetState.fileSize`) is far cheaper
/// than opening+parsing, so an unresolvable session costs one stat call per
/// lookup until new data shows up, then one real scan.
final class SessionNameResolver {
    /// sessionId -> resolved display name. A present key with a `nil` value
    /// means "seen in the file, but no usable text" (e.g. the prompt was
    /// pasted content only) -- distinct from "not seen yet", which has no key
    /// at all and therefore stays eligible for re-scanning once the file grows.
    private var names: [String: String?] = [:]
    private var scannedOffset: UInt64 = 0
    /// The path last scanned. Reset detects a config-injected path change
    /// (tests point a *running* app at a fixture file) so the cache doesn't
    /// mix names from two different files.
    private var scannedPath: String?

    /// Incremental per-session scan state for the transcript source (see
    /// `transcriptInfo`). `offset` mirrors the history file's tail-after
    /// strategy: only bytes appended since the last scan are read, so renames
    /// (a new `custom-title` line appended later) are picked up cheaply on the
    /// next lookup without re-parsing the whole file.
    private struct TranscriptScan {
        var offset: UInt64 = 0
        /// Latest `custom-title` seen -- the conversation's real name as shown
        /// in the Claude Code UI (renames append a new line; last one wins).
        var title: String?
        /// First usable user-typed text -- the fallback when no title exists.
        var firstPrompt: String?
    }
    private var transcriptScans: [String: TranscriptScan] = [:]
    /// The projects root last scanned -- mirrors `scannedPath` for the history
    /// cache: a config-injected root change (tests) must not reuse offsets or
    /// names that belong to files under the previous root.
    private var scannedProjectsRoot: String?

    static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/history.jsonl", isDirectory: false).path

    static let defaultProjectsRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true).path

    /// Reads the optional `historyPath` override from `~/.petmacos/config.json`
    /// (same override mechanism as `PetState.talkingDecaySeconds`) fresh on
    /// every call, falling back to the real `~/.claude/history.jsonl`. The app
    /// itself never writes this field -- only tests do, to point a running
    /// instance at a fixture file without touching the user's real history.
    static func configuredPath() -> String {
        guard let data = try? Data(contentsOf: PetConfig.fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["historyPath"] as? String, !value.isEmpty
        else { return defaultPath }
        return value
    }

    /// Reads the optional `projectsRoot` override from `~/.petmacos/config.json`,
    /// falling back to the real `~/.claude/projects`. Same rationale as
    /// `configuredPath()`: only tests set this, to point a running instance at
    /// a fixture directory tree instead of the user's real transcripts.
    static func configuredProjectsRoot() -> String {
        guard let data = try? Data(contentsOf: PetConfig.fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["projectsRoot"] as? String, !value.isEmpty
        else { return defaultProjectsRoot }
        return value
    }

    /// Returns the resolved conversation name for `sessionId`, or `nil` if it
    /// can't be resolved yet. Tries `history.jsonl` first (the same file
    /// `claude --resume` lists sessions under -- covers the terminal CLI), and
    /// when that has nothing falls back to reading the session's own
    /// transcript JSONL directly (covers the Claude Code **desktop app**,
    /// whose sessions are verified to never get appended to `history.jsonl`).
    /// The transcript fallback needs `cwd` to locate the right project folder
    /// under `~/.claude/projects` -- callers that can't supply it (none
    /// currently) simply don't get the fallback.
    func name(for sessionId: String, cwd: String? = nil) -> String? {
        // The transcript's `custom-title` is the conversation's *actual* name
        // (what the Claude Code UI shows in its sidebar; auto-generated or
        // user-renamed) -- it beats every other source. The first prompt is
        // only a stand-in when no title has been written yet.
        let transcript = (cwd?.isEmpty == false)
            ? transcriptInfo(for: sessionId, cwd: cwd!) : nil
        if let title = transcript?.title { return title }
        if let historyName = historyName(for: sessionId) { return historyName }
        return transcript?.firstPrompt
    }

    /// The original `~/.claude/history.jsonl`-only lookup, unchanged. Returns
    /// `nil` both for "not seen yet" and "seen but unusable" -- callers that
    /// want the transcript fallback for either case use `name(for:cwd:)`.
    private func historyName(for sessionId: String) -> String? {
        let path = Self.configuredPath()
        if path != scannedPath {
            scannedPath = path
            scannedOffset = 0
            names.removeAll()
        }
        if let cached = names[sessionId] { return cached }

        let currentSize = PetState.fileSize(path: path)
        guard currentSize > scannedOffset else { return nil } // nothing new; known miss stays a miss
        scan(path: path)
        return names[sessionId] ?? nil
    }

    /// Scans the session's own transcript (`<projectsRoot>/<slug(cwd)>/
    /// <sessionId>.jsonl`) for the two name sources it can contain: the latest
    /// `{"type":"custom-title","customTitle":...}` line (the conversation's
    /// real name -- renames append a new line, so last occurrence wins) and
    /// the first usable user-typed text (`queue-operation`/`enqueue` content,
    /// or a `user` message) as a fallback. Incremental: only bytes appended
    /// since the previous scan are read, so the first lookup pays for one full
    /// pass and later lookups (including picking up renames) are cheap. The
    /// substring pre-filter avoids JSON-parsing every appended line once the
    /// first prompt is known.
    private func transcriptInfo(for sessionId: String, cwd: String) -> TranscriptScan? {
        let root = Self.configuredProjectsRoot()
        if root != scannedProjectsRoot {
            scannedProjectsRoot = root
            transcriptScans.removeAll()
        }
        let path = "\(root)/\(Self.slug(cwd))/\(sessionId).jsonl"
        var state = transcriptScans[sessionId] ?? TranscriptScan()
        let currentSize = PetState.fileSize(path: path)
        guard currentSize > state.offset else { return transcriptScans[sessionId] }
        guard let handle = FileHandle(forReadingAtPath: path) else { return transcriptScans[sessionId] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else { return transcriptScans[sessionId] }

        // Leave an incomplete trailing line (still being written) for the next
        // scan, exactly like `scan(path:)` below.
        guard let lastNewline = text.range(of: "\n", options: .backwards) else {
            return transcriptScans[sessionId]
        }
        let consumed = text[text.startIndex..<lastNewline.upperBound]
        state.offset += UInt64(consumed.utf8.count)

        for line in consumed.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains("custom-title") {
                // Cheap substring pre-filter, deliberately loose (whitespace
                // in the JSON varies by writer); the parse below rejects lines
                // that merely *mention* custom-title inside message content.
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["type"] as? String == "custom-title",
                      let raw = object["customTitle"] as? String,
                      let cleaned = Self.cleanedName(from: raw)
                else { continue }
                state.title = cleaned
            } else if state.firstPrompt == nil {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let candidate = Self.extractCandidateText(from: object),
                      !Self.isNoise(candidate),
                      let cleaned = Self.cleanedName(from: candidate)
                else { continue }
                state.firstPrompt = cleaned
            }
        }
        transcriptScans[sessionId] = state
        return state
    }

    /// Pulls out the raw candidate text from one transcript line: a
    /// `queue-operation`/`enqueue` line's `content`, or a `user` line's
    /// message text (string, or the first `text` block of an array).
    private static func extractCandidateText(from object: [String: Any]) -> String? {
        let type = object["type"] as? String
        if type == "queue-operation", object["operation"] as? String == "enqueue" {
            return object["content"] as? String
        }
        guard type == "user", let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if part["type"] as? String == "text", let text = part["text"] as? String {
                    return text
                }
            }
        }
        return nil
    }

    /// True for candidate text that is a system/tool injection rather than
    /// something the user actually typed, per the caller's spec: task
    /// notifications (`<...>`), the CLI's pasted-caveat banner, and the
    /// "request interrupted" marker Claude Code inserts on ESC-cancel.
    private static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<")
            || trimmed.hasPrefix("Caveat:")
            || trimmed.hasPrefix("[Request interrupted")
    }

    /// Builds the `~/.claude/projects` folder-name slug Claude Code derives
    /// from a working directory: every character that isn't an ASCII letter
    /// or digit becomes `-` (verified against real folder names on this
    /// machine, e.g. `/Users/a/Flutter web` -> `-Users-a-Flutter-web` and
    /// `/Users/a/Downloads/remix_-voice-library` ->
    /// `-Users-a-Downloads-remix--voice-library`, the double dash coming from
    /// "_" and "-" each independently mapping to "-").
    static func slug(_ cwd: String) -> String {
        String(cwd.map { char -> Character in
            let isAlphanumericASCII = char.isASCII && (char.isLetter || char.isNumber)
            return isAlphanumericASCII ? char : "-"
        })
    }

    /// Parses whatever complete lines were appended since `scannedOffset`,
    /// recording the first display name seen for each new session id. An
    /// incomplete trailing line (still being written) is left for the next
    /// scan rather than dropped, exactly like `scanTaskNotifications`.
    private func scan(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: scannedOffset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else { return }

        guard let lastNewline = text.range(of: "\n", options: .backwards) else {
            return // no complete line yet; retry once the file grows further
        }
        let consumed = text[text.startIndex..<lastNewline.upperBound]
        scannedOffset += UInt64(consumed.utf8.count)

        for line in consumed.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = object["sessionId"] as? String
            else { continue }
            if names[sessionId] != nil { continue } // keep first occurrence only
            let rawDisplay = (object["display"] as? String) ?? ""
            names[sessionId] = Self.cleanedName(from: rawDisplay)
        }
    }

    /// Strips the `[Pasted text #N +X lines]` placeholder Claude Code's CLI
    /// inserts for pasted content, trims whitespace, and truncates to a
    /// caption-friendly length. Returns `nil` if nothing usable remains (e.g.
    /// a prompt that was pure pasted content).
    static func cleanedName(from display: String) -> String? {
        var cleaned = display.replacingOccurrences(
            of: #"\[Pasted text #\d+(?:\s*\+\s*\d+\s*lines?)?\]"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return truncate(cleaned, maxLength: 40)
    }

    /// Truncates to `maxLength`, breaking on the nearest preceding word
    /// boundary when there is one past the halfway point (so short trailing
    /// words don't get orphaned), appending "…".
    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let prefix = text.prefix(maxLength)
        if let lastSpace = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: lastSpace) > maxLength / 2 {
            return String(prefix[prefix.startIndex..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
