import Foundation

/// Installs/uninstalls the Claude Code hooks that drive the pet.
/// Writes `pet-hook.sh` into `~/.petmacos/` and merges hook entries into
/// `~/.claude/settings.json` without disturbing the user's other settings.
enum HookInstaller {
    /// Marker that identifies our hook entries so uninstall can remove them.
    private static let marker = "pet-hook.sh"

    /// Path of the installed script. Also used by the Diagnostics tab to run
    /// a real connectivity test through the actual installed script.
    static let scriptURL = PetConfig.directory.appendingPathComponent("pet-hook.sh")

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Event → mode. `ask` blocks for a decision; `question` blocks for an
    /// `AskUserQuestion` answer; `event` is fire-and-forget. `matcher` is only
    /// meaningful for tool events; `timeout` (seconds) is written per-hook when set.
    private static func plan(writeToolsOnly: Bool)
        -> [(event: String, mode: String, matcher: String?, timeout: Int?)] {
        let toolMatcher = writeToolsOnly ? "Bash|Write|Edit|MultiEdit|NotebookEdit" : "*"
        return [
            ("UserPromptSubmit", "event", nil, nil),
            // Interactive questions first, so they own the AskUserQuestion tool.
            // The `ask` hook below also matches it under "*" but exits early.
            ("PreToolUse", "question", "AskUserQuestion", 600),
            ("PreToolUse", "ask", toolMatcher, nil),
            ("PostToolUse", "event", toolMatcher, nil),
            ("Notification", "event", nil, nil),
            ("Stop", "event", nil, nil),
            // SubagentStart is new in Claude Code v2.1.177+ (carries agent_id/
            // agent_type for a subagent that's about to run) and lets PetState
            // retire the *right* SubagentStop card instead of oldest-first
            // (FIFO) guessing — see PetState.handleSubagentStart. There is no
            // version-hash / auto-migrate mechanism for installed hooks in this
            // app (`isInstalled` only checks presence of our marker, not which
            // events are wired up), so an existing install won't pick this up
            // on its own: the user must reconnect (Ngắt kết nối rồi Kết nối
            // lại Claude Code, or "Cài lại hook" in Chẩn đoán) for it to take
            // effect.
            ("SubagentStart", "event", nil, nil),
            ("SubagentStop", "event", nil, nil),
            ("SessionStart", "event", nil, nil),
            ("SessionEnd", "event", nil, nil),
        ]
    }

    // MARK: - Install

    static func install(writeToolsOnly: Bool) throws {
        try writeScript()
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Strip every existing entry of ours first, so re-adding multiple groups
        // for the same event (PreToolUse has two) doesn't clobber siblings.
        for event in hooks.keys {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            hooks[event] = groups
        }

        for entry in plan(writeToolsOnly: writeToolsOnly) {
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            var hook: [String: Any] = [
                "type": "command", "command": "sh \(scriptURL.path) \(entry.mode)",
            ]
            if let timeout = entry.timeout { hook["timeout"] = timeout }
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[entry.event] = groups
        }

        settings["hooks"] = hooks
        try saveSettings(settings)
    }

    // MARK: - Uninstall

    static func uninstall() throws {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in hooks.keys {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }

        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        try saveSettings(settings)
    }

    /// True if our hooks are currently present in settings.json.
    static var isInstalled: Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
        }
    }

    // MARK: - Helpers

    private static func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func saveSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func writeScript() throws {
        try FileManager.default.createDirectory(
            at: PetConfig.directory, withIntermediateDirectories: true)
        try Self.scriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// The `pet-hook.sh` contents, embedded so the app is self-contained.
    /// Keep in sync with `hooks/pet-hook.sh` in the repo.
    private static let scriptSource = """
    #!/bin/sh
    # pet-hook.sh — bridges a Claude Code hook to the running Pet macOS app.
    # Installed by PetMacOS. Do not edit; regenerated on connect.
    MODE="${1:-event}"
    CONFIG="$HOME/.petmacos/config.json"
    [ -f "$CONFIG" ] || exit 0
    # Whitespace-tolerant: config.json may be compact ("port":58318) or
    # pretty-printed ("port": 58318) depending on how it was written.
    PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$CONFIG")
    TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$CONFIG")
    [ -n "$PORT" ] || exit 0
    PAYLOAD=$(cat)
    if [ "$MODE" = "question" ]; then
        # AskUserQuestion: block for the user's answer regardless of permission
        # mode. Server returns the full hookSpecificOutput JSON; print verbatim.
        RESPONSE=$(curl -s -m 570 -X POST "http://127.0.0.1:$PORT/question" \\
            -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \\
            --data-binary "$PAYLOAD" 2>/dev/null)
        [ -n "$RESPONSE" ] && printf '%s\\n' "$RESPONSE"
        exit 0
    fi
    if [ "$MODE" = "ask" ]; then
        # AskUserQuestion is handled by the `question` hook; stay out of the way.
        TOOL=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        [ "$TOOL" = "AskUserQuestion" ] && exit 0
        PMODE=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"permission_mode"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        if [ -n "$PMODE" ] && [ "$PMODE" != "default" ]; then
            curl -s -m 3 -X POST "http://127.0.0.1:$PORT/event" \\
                -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \\
                --data-binary "$PAYLOAD" >/dev/null 2>&1
            exit 0
        fi
        RESPONSE=$(curl -s -m 300 -X POST "http://127.0.0.1:$PORT/ask" \\
            -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \\
            --data-binary "$PAYLOAD" 2>/dev/null)
        NOTE=$(printf '%s' "$RESPONSE" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | tr -d '"\\\\')
        case "$RESPONSE" in
            *'"decision":"deny"'*)
                REASON="Từ chối trên Pet"; [ -n "$NOTE" ] && REASON="$REASON: $NOTE"
                printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\\n' "$REASON" ;;
            *'"decision":"allow"'*)
                REASON="Cho phép trên Pet"; [ -n "$NOTE" ] && REASON="$REASON: $NOTE"
                printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\\n' "$REASON" ;;
            *) exit 0 ;;
        esac
        exit 0
    fi
    curl -s -m 3 -X POST "http://127.0.0.1:$PORT/event" \\
        -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \\
        --data-binary "$PAYLOAD" >/dev/null 2>&1
    exit 0
    """
}
