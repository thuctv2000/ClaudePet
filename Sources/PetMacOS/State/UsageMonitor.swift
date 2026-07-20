import Foundation
import Observation

/// Polls Claude's usage-limit endpoint (the same data `/usage` shows in
/// Claude Code) and publishes the 5-hour and weekly utilization percentages.
///
/// Auth reuses Claude Code's own OAuth token: `~/.claude/.credentials.json`
/// when present, else the macOS Keychain item "Claude Code-credentials".
/// The token is never stored. When it has expired (401), the monitor spawns a
/// cheap `claude` run so Claude Code refreshes its own token, then retries --
/// see `triggerClaudeRefresh`. It never performs the OAuth refresh itself, to
/// avoid clobbering the login through refresh-token rotation.
@MainActor
@Observable
final class UsageMonitor {
    struct Window: Equatable, Codable {
        let utilization: Double   // 0–100
        let resetsAt: Date?
    }

    private(set) var fiveHour: Window?
    private(set) var sevenDay: Window?
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?

    /// Endpoint enforces an HOURLY quota and answers a breach with 429 +
    /// Retry-After 3600 — a 10-minute cadence stays far under it while the
    /// numbers are still fresh enough for a glanceable badge.
    private let pollInterval: TimeInterval = 600
    private var pollTask: Task<Void, Never>?
    /// Set from a 429's Retry-After: no request leaves before this instant,
    /// or the continued polling would keep re-tripping the hourly ban.
    private var pausedUntil: Date?

    /// After an auto-refresh attempt (spawning `claude` to renew its token), no
    /// further attempt is made before this instant. Without it a login that
    /// stays broken -- e.g. the refresh token itself expired -- would respawn
    /// `claude` on every poll.
    private var refreshCooldownUntil: Date?
    private let refreshCooldown: TimeInterval = 30 * 60

    /// One decoded outcome of a usage request. Kept free of `tr()` so the fetch
    /// can run off the main actor; the main-actor `apply(_:)` formats messages.
    private enum UsageResult {
        case ok([String: Any])
        case unauthorized
        case rateLimited(TimeInterval)
        case httpError(Int)
        case badData
        case transport(String)
    }

    /// Snapshot persisted across launches, so the badge shows the last known
    /// numbers right away instead of staying blank until the first successful
    /// poll (the endpoint 429s easily — e.g. right after several restarts).
    private struct CachedUsage: Codable {
        let fiveHour: Window?
        let sevenDay: Window?
        let at: Date
    }
    private static let cacheKey = "usage.lastSnapshot"

    func start() {
        guard pollTask == nil else { return }
        loadCache()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 180))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One fetch; keeps the previous values on any failure.
    func refresh() async {
        if let until = pausedUntil {
            guard Date() >= until else {
                let minutes = max(1, Int(until.timeIntervalSinceNow / 60))
                lastError = String(format: tr("Rate limited — retrying in %d min"), minutes)
                return
            }
            pausedUntil = nil
        }
        guard let token = await Task.detached(operation: { Self.readAccessToken() }).value else {
            lastError = tr("Couldn't find a Claude Code login token")
            return
        }
        var result = await Self.fetchUsage(token: token)

        // Expired access token: rather than wait for the user to open Claude
        // Code, ask Claude Code to renew its own token with a cheap Haiku call,
        // re-read the token, and retry once. The pet never touches the refresh
        // token itself -- Claude Code owns rotation -- so this can't invalidate
        // the login the way a self-refresh could. Cooldown-gated so a login
        // that stays broken doesn't respawn `claude` on every poll.
        if case .unauthorized = result, canAttemptRefresh() {
            refreshCooldownUntil = Date().addingTimeInterval(refreshCooldown)
            lastError = tr("Refreshing login…")
            let renewed = await Task.detached(operation: { Self.triggerClaudeRefresh() }).value
            if renewed, let newToken = await Task.detached(operation: { Self.readAccessToken() }).value {
                result = await Self.fetchUsage(token: newToken)
            }
        }

        apply(result)
    }

    private func canAttemptRefresh() -> Bool {
        guard let until = refreshCooldownUntil else { return true }
        return Date() >= until
    }

    private func apply(_ result: UsageResult) {
        switch result {
        case .ok(let object):
            fiveHour = Self.window(from: object["five_hour"])
            sevenDay = Self.window(from: object["seven_day"])
            lastUpdated = Date()
            lastError = nil
            refreshCooldownUntil = nil
            saveCache()
        case .unauthorized:
            lastError = tr("Token expired — open Claude Code to refresh it")
        case .rateLimited(let retryAfter):
            // Honour Retry-After (observed: 3600s) and go quiet until then;
            // keep showing the previous numbers meanwhile.
            let wait = min(max(retryAfter, 60), 2 * 3600)
            pausedUntil = Date().addingTimeInterval(wait)
            lastError = String(format: tr("Rate limited — retrying in %d min"), Int(wait / 60))
        case .httpError(let code):
            lastError = String(format: tr("Server returned %d"), code)
        case .badData:
            lastError = tr("Couldn't read the response data")
        case .transport(let message):
            lastError = message
        }
    }

    /// The bare HTTP round-trip, isolated from actor state so it can run off the
    /// main actor and be retried with a fresh token.
    nonisolated private static func fetchUsage(token: String) async -> UsageResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .badData
            }
            switch http.statusCode {
            case 200:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .badData
                }
                return .ok(object)
            case 401:
                return .unauthorized
            case 429:
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 3600
                return .rateLimited(retryAfter)
            default:
                return .httpError(http.statusCode)
            }
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    // MARK: - Cross-launch snapshot

    private func loadCache() {
        guard fiveHour == nil, sevenDay == nil,
              let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedUsage.self, from: data)
        else { return }
        // Usage older than a day says nothing useful — start blank instead.
        guard Date().timeIntervalSince(cached.at) < 24 * 60 * 60 else { return }
        fiveHour = cached.fiveHour
        sevenDay = cached.sevenDay
        lastUpdated = cached.at
    }

    private func saveCache() {
        let snapshot = CachedUsage(fiveHour: fiveHour, sevenDay: sevenDay, at: Date())
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private static func window(from value: Any?) -> Window? {
        guard let dict = value as? [String: Any],
              let raw = dict["utilization"] as? Double else { return nil }
        var resets: Date?
        if let text = dict["resets_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resets = formatter.date(from: text)
            if resets == nil {
                formatter.formatOptions = [.withInternetDateTime]
                resets = formatter.date(from: text)
            }
        }
        return Window(utilization: min(max(raw, 0), 100), resetsAt: resets)
    }

    // MARK: - Token lookup (off the main actor)

    /// Reads Claude Code's current OAuth access token. File first, Keychain second.
    nonisolated private static func readAccessToken() -> String? {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL), let token = accessToken(fromJSON: data) {
            return token
        }

        // Keychain item written by Claude Code on macOS.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return accessToken(fromJSON: output)
    }

    nonisolated private static func accessToken(fromJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    // MARK: - Token refresh via Claude Code (off the main actor)

    /// Folder name the refresh run executes in. Hooks are installed globally,
    /// so this hidden `claude` run fires them like any session would — the pet
    /// recognises this marker as its own plumbing and drops those events
    /// (`PetState.apply`), keeping phantom "hi" conversation cards off screen.
    nonisolated static let refreshMarkerDirName = "petmacos-token-refresh"

    /// Spawns a minimal `claude` run so Claude Code renews its own OAuth token
    /// into the Keychain (it refreshes lazily on the first authenticated
    /// request). Uses Haiku and a single turn to keep the quota cost trivial.
    /// Returns true only on a clean exit; the caller then re-reads the token.
    ///
    /// We do NOT drive the refresh ourselves: letting Claude Code own the
    /// refresh-token rotation avoids invalidating the very login the pet reads.
    nonisolated private static func triggerClaudeRefresh() -> Bool {
        guard let claude = claudeBinaryPath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "hi", "--model", "haiku", "--max-turns", "1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // A GUI app has no meaningful cwd; run inside the marker folder so the
        // pet can tell these hook events apart from real sessions (see
        // `refreshMarkerDirName`).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(refreshMarkerDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        process.currentDirectoryURL = dir

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return false }
        if done.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// Locates the `claude` executable. A menu-bar app launched from Finder has
    /// a bare PATH, so the usual install locations are probed directly before
    /// falling back to a login shell that sources the user's profile.
    nonisolated private static func claudeBinaryPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        guard shell.terminationStatus == 0 else { return nil }
        let resolved = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolved, !resolved.isEmpty, fm.isExecutableFile(atPath: resolved) {
            return resolved
        }
        return nil
    }
}
