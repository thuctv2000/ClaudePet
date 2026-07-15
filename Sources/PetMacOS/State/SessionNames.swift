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

    static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/history.jsonl", isDirectory: false).path

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

    /// Returns the resolved conversation name for `sessionId`, or `nil` if it
    /// can't be resolved yet (unknown session, or a session whose only
    /// prompt so far has no usable display text). Synchronous file I/O, but
    /// bounded by the "only re-scan on file growth" rule above -- matches the
    /// existing synchronous-on-main-actor pattern used elsewhere in
    /// `PetState` (e.g. `configOverride`, `logEvent`).
    func name(for sessionId: String) -> String? {
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
