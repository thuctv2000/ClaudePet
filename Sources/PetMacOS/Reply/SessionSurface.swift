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

    /// What to call it on a card. Deliberately the name of the app the user
    /// would go to, not the value in the file.
    var label: String? {
        switch self {
        case .cli: return "Terminal"
        case .desktop: return "Claude"
        case .vscode: return "VS Code"
        case .unknown: return nil
        }
    }

    /// SF Symbol for the same.
    var symbol: String? {
        switch self {
        case .cli: return "terminal"
        case .desktop: return "bubble.left.and.bubble.right"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .unknown: return nil
        }
    }
}

/// What the transcript says about where a session lives.
struct SessionOrigin {
    let surface: SessionSurface
    /// The session's real working directory, as recorded alongside the
    /// entrypoint. Used to pick the right VS Code window; unlike the `cwd` in
    /// a hook payload this one is not disturbed by a `cd` inside a Bash tool
    /// call, because it is written when the user's prompt is recorded.
    let cwd: String?
    /// The name Claude Code gives this session in the terminal title, from the
    /// transcript's newest `ai-title` record.
    ///
    /// This is not the same string as the pet's own session name, which comes
    /// from the first prompt: a session whose pet card reads "hi" showed up in
    /// VS Code's terminal as "Dự án này là gì". Matching the wrong one is how
    /// the pet failed to find the terminal it was looking straight at.
    let terminalTitle: String?

    static let unknown = SessionOrigin(surface: .unknown, cwd: nil, terminalTitle: nil)

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

        var surface: SessionSurface?
        var cwd: String?
        var terminalTitle: String?
        for line in text.split(separator: "\n").reversed() {
            let hasEntrypoint = line.contains("\"entrypoint\"")
            let hasTitle = line.contains("\"ai-title\"")
            guard hasEntrypoint || hasTitle,
                  let object = try? JSONSerialization
                    .jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if surface == nil, let entrypoint = object["entrypoint"] as? String {
                surface = SessionSurface(rawValue: entrypoint) ?? .unknown
                cwd = object["cwd"] as? String
            }
            if terminalTitle == nil, let title = object["aiTitle"] as? String {
                terminalTitle = title
            }
            if surface != nil, terminalTitle != nil { break }
        }
        guard let surface else { return .unknown }
        return SessionOrigin(surface: surface, cwd: cwd, terminalTitle: terminalTitle)
    }
}
