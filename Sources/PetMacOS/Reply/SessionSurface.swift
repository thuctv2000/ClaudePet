import Foundation

/// Which program is hosting a session: a terminal, the Desktop app, or the
/// VS Code extension.
///
/// Routing a reply used to guess this — a tty meant "terminal", anything else
/// was tried against every window-driving host in turn. Guessing is not good
/// enough, because the hosts are not equally harmless when they are wrong:
/// asking Claude Desktop about a conversation it doesn't have costs nothing,
/// but handing a session id to VS Code that its extension doesn't recognise
/// makes it **start a brand new conversation** (see `DesktopAX.sendToVSCode`).
///
/// Claude Code writes the answer down. Every prompt record in the transcript
/// carries `entrypoint`, which is one of `cli`, `claude-desktop` or
/// `claude-vscode` — the same file the pet already reads to name a session.
enum SessionSurface: String {
    case cli
    case desktop = "claude-desktop"
    case vscode = "claude-vscode"
    case unknown = "?"
}

/// What the transcript says about where a session lives.
struct SessionOrigin {
    let surface: SessionSurface
    /// The session's real working directory, as recorded alongside the
    /// entrypoint. Used to pick the right VS Code window; unlike the `cwd` in
    /// a hook payload this one is not disturbed by a `cd` inside a Bash tool
    /// call, because it is written when the user's prompt is recorded.
    let cwd: String?

    static let unknown = SessionOrigin(surface: .unknown, cwd: nil)

    /// Reads the newest record that carries an `entrypoint`.
    ///
    /// Only the tail is read: these files grow to megabytes and the answer is
    /// on every user prompt, so the last window always holds one for any
    /// session worth replying to. Scanning backwards also means a session that
    /// moved surface (resumed in a terminal after starting in the app) reports
    /// where it is *now*, not where it began.
    static func read(transcriptPath: String?) -> SessionOrigin {
        guard let path = transcriptPath, !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return .unknown }
        // Decoding (rather than String(data:encoding:)) so that a tail cutting
        // through a multi-byte character degrades that one character instead of
        // throwing the whole read away.
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"entrypoint\"") else { continue }
            guard let object = try? JSONSerialization
                .jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let entrypoint = object["entrypoint"] as? String else { continue }
            return SessionOrigin(
                surface: SessionSurface(rawValue: entrypoint) ?? .unknown,
                cwd: object["cwd"] as? String
            )
        }
        return .unknown
    }
}
