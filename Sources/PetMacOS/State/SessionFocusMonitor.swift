import Foundation

/// Watches the Claude Code desktop app's per-session mapping files
/// (`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`)
/// and reports when the user focuses a conversation, keyed by the CLI
/// `session_id` the pet already tracks from hook events.
///
/// The file format is an undocumented internal of the desktop app, so
/// everything decodes optionally and the monitor simply stays silent when the
/// directory or fields are missing (terminal-only setups, future app builds).
///
/// Known quirk: the desktop app batch-bumps `lastFocusedAt` across many
/// sessions when it restarts/rehydrates. Two guards keep that from mass-
/// dismissing cards: a poll tick where many sessions change at once only
/// re-seeds the baseline, and `PetState.markConversationViewed` additionally
/// requires the focus to be newer than the session's last hook event.
@MainActor
final class SessionFocusMonitor {
    /// Called with the CLI session id and the focus time whenever a
    /// conversation's `lastFocusedAt` moves forward.
    var onFocus: ((String, Date) -> Void)?

    private var timer: Timer?
    /// Baseline `lastFocusedAt` per CLI session id.
    private var known: [String: Date] = [:]
    /// The first scan only seeds the baseline — everything on disk predates us.
    private var primed = false
    /// More sessions than this changing in a single tick is a rehydrate, not
    /// the user clicking through conversations.
    private static let batchBumpThreshold = 3
    private static let pollInterval: TimeInterval = 3

    private struct MappingEntry: Decodable {
        let cliSessionId: String?
        let lastFocusedAt: Double?   // epoch milliseconds
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let latest = scanMappingFiles()
        defer { primed = true }
        guard primed else {
            known = latest
            return
        }
        var advanced: [(String, Date)] = []
        for (sid, date) in latest {
            if let old = known[sid] {
                if date > old { advanced.append((sid, date)) }
            }
            // A session seen for the first time is baseline, not a focus:
            // its card (if any) was spawned by hook events we already have.
            known[sid] = date
        }
        guard advanced.count <= Self.batchBumpThreshold else { return }
        for (sid, date) in advanced { onFocus?(sid, date) }
    }

    /// One pass over `claude-code-sessions/*/*/local_*.json` (account and org
    /// directory names are opaque UUIDs — never hardcoded).
    private func scanMappingFiles() -> [String: Date] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let accounts = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [:] }

        var result: [String: Date] = [:]
        let decoder = JSONDecoder()
        for account in accounts {
            guard let orgs = try? fm.contentsOfDirectory(
                at: account, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }
            for org in orgs {
                guard let files = try? fm.contentsOfDirectory(
                    at: org, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ) else { continue }
                for file in files where file.lastPathComponent.hasPrefix("local_")
                    && file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let entry = try? decoder.decode(MappingEntry.self, from: data),
                          let sid = entry.cliSessionId,
                          let ms = entry.lastFocusedAt else { continue }
                    let date = Date(timeIntervalSince1970: ms / 1000)
                    // Same CLI session can appear in several mapping files —
                    // keep the newest focus.
                    if let existing = result[sid], existing >= date { continue }
                    result[sid] = date
                }
            }
        }
        return result
    }
}
