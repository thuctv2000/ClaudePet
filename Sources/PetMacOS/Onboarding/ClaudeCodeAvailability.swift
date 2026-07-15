import Foundation

/// Detects whether Claude Code itself appears to be installed on this Mac, so
/// onboarding can tell a "not installed yet" machine apart from a "hooks just
/// aren't connected yet" one (see docs/DISTRIBUTION.md §3).
enum ClaudeCodeAvailability {
    /// True if `~/.claude/` exists or a `claude` binary is reachable on PATH.
    /// Either signal is enough — a fresh install may have one but not the
    /// other yet (e.g. binary installed, no session run so no `~/.claude/`).
    static func isInstalled() -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: claudeDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return findClaudeBinary() != nil
    }

    /// Runs `command -v claude` through the user's login shell so PATH
    /// customizations (nvm, Homebrew, etc.) are picked up the same way a
    /// Terminal session would see them.
    private static func findClaudeBinary() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }

    /// True if the running app bundle is not under `/Applications` — i.e. it's
    /// likely still running from the mounted DMG. Onboarding should nudge the
    /// user to drag it in first, since running from the DMG loses settings and
    /// hook paths on eject/reboot.
    static func isRunningOutsideApplications() -> Bool {
        !Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }
}
