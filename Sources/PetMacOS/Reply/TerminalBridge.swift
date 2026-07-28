import AppKit
import Foundation

/// Types a reply into a Claude Code session running in a terminal emulator.
///
/// This is the terminal half of the idle case (`DesktopAX` is the other). It
/// exists because a session sitting at its prompt fires no hook, so the queue
/// has nothing to ride on — see `PetState`'s reply section.
///
/// ## Why the tty, and not a name
///
/// The Desktop app can only be addressed by conversation title, which is a
/// guess: two sessions can share a title, and the pet has to refuse rather than
/// risk delivering into the wrong one. Terminals give something far better.
/// The hook script runs as a child of `claude`, so it inherits that session's
/// controlling terminal, and it reports that path back with every event.
/// Terminal.app and iTerm2 both expose the tty of each tab through AppleScript.
/// Matching those two values is exact — an operating-system identity, not a
/// label — so there is no ambiguity to guard against here.
///
/// ## Coverage
///
/// Only scriptable terminals can be reached: Terminal.app and iTerm2. Ghostty,
/// Alacritty, kitty and WezTerm expose no equivalent, so a session in one of
/// those reports `unsupportedTerminal` and its message stays queued for the
/// next hook instead of being silently dropped.
enum TerminalBridge {
    enum SendError: Error, Equatable {
        /// The session isn't in a terminal at all (Desktop app, or no tty).
        case noTty
        /// No running scriptable terminal owns a tab with this tty.
        case tabNotFound(String)
        /// AppleScript itself failed (usually Automation permission denied).
        case scriptFailed(String)
    }

    /// Sends `text` (followed by Return) to whichever Terminal.app or iTerm2
    /// tab is attached to `tty`, e.g. "/dev/ttys003".
    static func send(_ text: String, toTty tty: String) -> Result<Void, SendError> {
        guard tty.hasPrefix("/dev/") else { return .failure(.noTty) }

        if isRunning("com.apple.Terminal") {
            switch runScript(terminalScript(text: text, tty: tty)) {
            case .success(let answer) where answer.hasPrefix("ok"): return .success(())
            case .failure(let error): return .failure(.scriptFailed(error.message))
            case .success: break   // no matching tab here; try the next app
            }
        }
        if isRunning("com.googlecode.iterm2") {
            switch runScript(itermScript(text: text, tty: tty)) {
            case .success(let answer) where answer.hasPrefix("ok"): return .success(())
            case .failure(let error): return .failure(.scriptFailed(error.message))
            case .success: break
            }
        }
        return .failure(.tabNotFound(tty))
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }.isEmpty
    }

    /// `do script … in <tab>` writes the text to that tab's tty and presses
    /// Return, which is precisely what typing the reply by hand would do.
    private static func terminalScript(text: String, tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) is "\(escape(tty))" then
                do script "\(escape(text))" in t
                return "ok"
              end if
            end repeat
          end repeat
          return "notfound"
        end tell
        """
    }

    /// iTerm2 splits it in two: `write text` sends the line (adding the
    /// newline itself), and sessions carry their tty the same way.
    private static func itermScript(text: String, tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (tty of s) is "\(escape(tty))" then
                  tell s to write text "\(escape(text))"
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "notfound"
        end tell
        """
    }

    /// AppleScript string literals only understand backslash escapes for `"`
    /// and `\`; a raw newline inside one is a syntax error. Newlines are turned
    /// into spaces because a message is sent as a single line anyway — the
    /// trailing Return that `do script` adds is what submits it, so an embedded
    /// one would submit half the message.
    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Wraps the AppleScript failure message so it can travel in a `Result`
    /// (a bare `String` is not an `Error`).
    private struct ScriptError: Error { let message: String }

    private static func runScript(_ source: String) -> Result<String, ScriptError> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(ScriptError(message: "could not compile script"))
        }
        let output = script.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            return .failure(ScriptError(message: message))
        }
        return .success(output.stringValue ?? "")
    }
}

// MARK: - Finding the tty without the hook

extension TerminalBridge {
    /// Works out which terminal a session runs in by inspecting live `claude`
    /// processes, for the case where the hook never told us.
    ///
    /// The hook reports the tty on every event, which covers a session that is
    /// still active. It does NOT cover the case this whole feature is about: a
    /// session that has been sitting idle fires no events, so if the pet
    /// restarted — or the session last spoke to an older hook script — the tty
    /// is simply unknown, and the only surface left is the Desktop app, which
    /// then reports `conversationNotFound` for a terminal session.
    ///
    /// Claude Code writes each transcript to `<projects>/<slug(cwd)>/<id>.jsonl`,
    /// and `slug` is a pure function of the path. So slugging a candidate
    /// process's own working directory and comparing it against the folder the
    /// transcript actually sits in answers "is this that session's process?"
    /// exactly — the same trick `PetState.cwdIsProjectRoot` uses to decide
    /// whether a reported cwd can be trusted.
    ///
    /// Returns nil unless exactly one process matches: two sessions started in
    /// the same directory are indistinguishable this way, and delivering into
    /// the wrong terminal is the failure worth avoiding.
    static func discoverTty(projectFolder: String) -> String? {
        let candidates = claudeProcessesWithTty()
        let matches = candidates.filter { candidate in
            guard let cwd = workingDirectory(of: candidate.pid) else { return false }
            return SessionNameResolver.slug(cwd) == projectFolder
        }
        guard matches.count == 1 else { return nil }
        return matches[0].tty
    }

    private struct Candidate { let pid: Int32; let tty: String }

    /// `claude` processes attached to a terminal. A Desktop-app session has no
    /// tty and is filtered out here rather than later.
    private static func claudeProcessesWithTty() -> [Candidate] {
        guard let output = run("/bin/ps", ["-eo", "pid=,tty=,comm="]) else { return [] }
        var found: [Candidate] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  fields[1].hasPrefix("ttys"),
                  fields[2...].joined(separator: " ").hasSuffix("claude")
            else { continue }
            found.append(Candidate(pid: pid, tty: "/dev/\(fields[1])"))
        }
        return found
    }

    private static func workingDirectory(of pid: Int32) -> String? {
        guard let output = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        else { return nil }
        return output.split(separator: "\n")
            .first { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
