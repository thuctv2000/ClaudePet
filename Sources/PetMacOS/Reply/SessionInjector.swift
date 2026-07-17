import Foundation

/// Sends a user-typed message into a running Claude Code session via tmux
/// (Reply v1 — see docs/RESEARCH_PET_REPLY.md). Transport:
///
///   1. verify the pane is alive: `tmux display-message -p -t <pane>` — the
///      most reliable single check (`has-session` only takes a *session*
///      target and answers true for the whole session even after the specific
///      pane closed; `display-message -t %N` fails precisely when that pane is
///      gone, and also fails when the whole server is down),
///   2. inject the text,
///   3. wait ~0.15s (lets the TUI's input loop consume the text before the
///      submit keypress arrives), then `tmux send-keys -t <pane> Enter`.
///
/// ## Multi-line decision (paste-buffer, not literal send-keys)
///
/// Single-line text goes through `send-keys -l -- <text>`: `-l` sends the
/// string literally (no key-name lookup), which keeps Vietnamese/Unicode
/// intact, and `--` stops a message starting with "-" from being parsed as a
/// flag. For text CONTAINING newlines, `send-keys -l` is the wrong tool: tmux
/// translates the embedded `\n` into individual C-m (Enter) key events, so the
/// TUI would submit at the first line break instead of receiving one
/// multi-line message. The reliable path is tmux's paste pipeline instead:
/// `load-buffer -` (text via stdin, no escaping problems at all) followed by
/// `paste-buffer -d -p -t <pane>` — `-p` uses bracketed-paste, which Claude
/// Code's TUI (like any modern readline) recognises as "this is a paste, do
/// not treat newlines as submits". NOTE: tmux is not installed on the dev
/// machine this was written on, so the multi-line path is chosen from tmux's
/// documented semantics rather than a live experiment (the spec's "phương án
/// B đáng tin hơn"); the single-line path is the only one the v1 UI (a
/// one-line TextField) can produce anyway.
enum SessionInjector {
    enum InjectorError: Error, Equatable {
        /// `tmux` is not installed / not on PATH.
        case tmuxMissing
        /// The target pane (or the whole tmux server) is gone.
        case paneGone
        /// tmux exists and the pane was alive, but an injection command failed.
        case sendFailed(String)

        /// Short Vietnamese reason for the card's status line.
        var shortReason: String {
            switch self {
            case .tmuxMissing: return "tmux chưa cài"
            case .paneGone: return "pane tmux đã đóng"
            case .sendFailed(let detail): return detail.isEmpty ? "tmux lỗi" : detail
            }
        }
    }

    /// Sends `text` (then Enter) into tmux pane `pane` (e.g. "%12").
    /// Runs the blocking Process work off the caller's executor.
    static func send(_ text: String, toPane pane: String) async -> Result<Void, InjectorError> {
        await Task.detached { sendSync(text, toPane: pane) }.value
    }

    private nonisolated static func sendSync(_ text: String, toPane pane: String)
        -> Result<Void, InjectorError> {
        // 1. Pane liveness (doubles as the tmux-installed check: /usr/bin/env
        //    exits 127 when the command doesn't exist).
        let probe = run(["tmux", "display-message", "-p", "-t", pane, "ok"])
        if probe.status == 127 { return .failure(.tmuxMissing) }
        guard probe.status == 0 else { return .failure(.paneGone) }

        // 2. Inject the text (see the type doc comment for the single- vs
        //    multi-line rationale).
        if text.contains("\n") {
            let load = run(["tmux", "load-buffer", "-b", "petreply", "-"], stdin: text)
            guard load.status == 0 else {
                return .failure(.sendFailed(trimmedStderr(load) ?? "load-buffer lỗi"))
            }
            let paste = run(["tmux", "paste-buffer", "-d", "-p", "-b", "petreply", "-t", pane])
            guard paste.status == 0 else {
                return .failure(.sendFailed(trimmedStderr(paste) ?? "paste-buffer lỗi"))
            }
        } else {
            let keys = run(["tmux", "send-keys", "-t", pane, "-l", "--", text])
            guard keys.status == 0 else {
                return .failure(.sendFailed(trimmedStderr(keys) ?? "send-keys lỗi"))
            }
        }

        // 3. Give the TUI a beat to consume the text, then dismiss the
        //    autocomplete popup with Escape BEFORE submitting: Claude Code's
        //    Ink-based prompt intercepts a bare Enter while its suggestion
        //    popup is open, so text lands in the field but never submits.
        //    Escape-then-Enter is the field-proven sequence from
        //    anthropics/claude-code#15553 (10-agent tmux systems rely on it).
        //    Escape is harmless when no popup is open.
        usleep(300_000)
        _ = run(["tmux", "send-keys", "-t", pane, "Escape"])
        usleep(100_000)
        let enter = run(["tmux", "send-keys", "-t", pane, "Enter"])
        guard enter.status == 0 else {
            return .failure(.sendFailed(trimmedStderr(enter) ?? "send-keys Enter lỗi"))
        }
        return .success(())
    }

    private struct ProcessResult {
        let status: Int32
        let stderr: String
    }

    /// Runs `arguments` through /usr/bin/env (so tmux is found via PATH),
    /// optionally feeding `stdin`, and waits for it to exit.
    private nonisolated static func run(_ arguments: [String], stdin: String? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        if stdin != nil { process.standardInput = stdinPipe }
        do {
            try process.run()
        } catch {
            // env itself failed to launch — treat like a missing tool.
            return ProcessResult(status: 127, stderr: error.localizedDescription)
        }
        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    private nonisolated static func trimmedStderr(_ result: ProcessResult) -> String? {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}
