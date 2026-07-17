import Foundation
import Observation

/// Polls Claude's usage-limit endpoint (the same data `/usage` shows in
/// Claude Code) and publishes the 5-hour and weekly utilization percentages.
///
/// Auth reuses Claude Code's own OAuth token: `~/.claude/.credentials.json`
/// when present, else the macOS Keychain item "Claude Code-credentials".
/// The token is never stored; Claude Code refreshes it by itself.
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
        do {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 401:
                    lastError = tr("Token expired — open Claude Code to refresh it")
                case 429:
                    // Honour Retry-After (observed: 3600s) and go quiet until
                    // then; keep showing the previous numbers meanwhile.
                    let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                        ?? 3600
                    let wait = min(max(retryAfter, 60), 2 * 3600)
                    pausedUntil = Date().addingTimeInterval(wait)
                    lastError = String(
                        format: tr("Rate limited — retrying in %d min"), Int(wait / 60))
                default:
                    lastError = String(format: tr("Server returned %d"), http.statusCode)
                }
                return
            }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = tr("Couldn't read the response data")
                return
            }
            fiveHour = Self.window(from: object["five_hour"])
            sevenDay = Self.window(from: object["seven_day"])
            lastUpdated = Date()
            lastError = nil
            saveCache()
        } catch {
            lastError = error.localizedDescription
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
}
