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

    /// Event → mode. `permission` blocks for an allow/deny decision; `question`
    /// blocks for an `AskUserQuestion` answer; `event` is fire-and-forget.
    /// `matcher` is only meaningful for tool events; `timeout` (seconds) is
    /// written per-hook when set.
    private static func plan()
        -> [(event: String, mode: String, matcher: String?, timeout: Int?)] {
        [
            ("UserPromptSubmit", "event", nil, nil),
            // Interactive questions first, so they own the AskUserQuestion tool.
            // The `permission` hook may also see it and exits early.
            ("PreToolUse", "question", "AskUserQuestion", 600),
            // Approval runs on PermissionRequest, which fires only when Claude
            // Code is about to show a permission dialog — i.e. exactly when the
            // terminal would have asked. PreToolUse cannot do this job: it fires
            // *before* the permission check, so it cannot tell whether a prompt
            // was coming, and answering there suppresses the dialog and stops
            // PermissionRequest from ever firing. The two are mutually exclusive.
            ("PermissionRequest", "permission", "*", nil),
            // PreToolUse now only feeds task cards. It used to double as the
            // approval hook, which is why it also carried the /event POST for
            // auto modes; that side of it lives on here.
            ("PreToolUse", "event", "*", nil),
            ("PostToolUse", "event", "*", nil),
            ("Notification", "event", nil, nil),
            ("Stop", "event", nil, nil),
            // SubagentStart is new in Claude Code v2.1.177+ (carries agent_id/
            // agent_type for a subagent that's about to run) and lets PetState
            // retire the *right* SubagentStop card instead of oldest-first
            // (FIFO) guessing — see PetState.handleSubagentStart.
            ("SubagentStart", "event", nil, nil),
            ("SubagentStop", "event", nil, nil),
            ("SessionStart", "event", nil, nil),
            ("SessionEnd", "event", nil, nil),
        ]
    }

    // MARK: - Install

    static func install() throws {
        try writeScript()
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Strip every existing entry of ours first, so re-adding multiple groups
        // for the same event (PreToolUse has two) doesn't clobber siblings.
        // This is also what migrates an older install: the stale `ask` entry is
        // removed here rather than left to fight the PermissionRequest hook.
        for event in hooks.keys {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            hooks[event] = groups
        }

        for entry in plan() {
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            groups.append(group(for: entry))
            hooks[entry.event] = groups
        }

        settings["hooks"] = hooks
        try saveSettings(settings)
    }

    /// The settings.json group one plan entry installs as.
    private static func group(
        for entry: (event: String, mode: String, matcher: String?, timeout: Int?)
    ) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command", "command": "sh \(scriptURL.path) \(entry.mode)",
        ]
        if let timeout = entry.timeout { hook["timeout"] = timeout }
        var group: [String: Any] = ["hooks": [hook]]
        if let matcher = entry.matcher { group["matcher"] = matcher }
        return group
    }

    /// True when what's on disk matches what THIS app version would install:
    /// the script byte-for-byte, and our settings.json groups (marker-scoped)
    /// exactly the plan. After a Sparkle update the app calls `install()` at
    /// launch when this is false, so new hook events/script fixes take effect
    /// without the user ever pressing "Connect" again.
    static var isCurrent: Bool {
        guard let onDisk = try? String(contentsOf: scriptURL, encoding: .utf8),
              onDisk == scriptSource else { return false }
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }

        var actual: [String: [[String: Any]]] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let ours = groups.filter { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if !ours.isEmpty { actual[event] = ours }
        }

        var expected: [String: [[String: Any]]] = [:]
        for entry in plan() {
            expected[entry.event, default: []].append(group(for: entry))
        }
        return canonical(actual) == canonical(expected)
    }

    private static func canonical(_ object: [String: [[String: Any]]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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

    /// True if our hooks are present *and* current.
    ///
    /// Checked against `PermissionRequest` rather than just our marker: an
    /// install from before the PermissionRequest migration still carries the
    /// marker, so a marker-only check would report "connected" while its stale
    /// `PreToolUse`/`ask` entry answers every permission check itself — no
    /// dialog is ever raised, so `PermissionRequest` never fires and the pet is
    /// never asked anything. Such an install reads as not-installed, and
    /// connecting rewrites it.
    static var isInstalled: Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any],
              let permissionRequest = hooks["PermissionRequest"] else { return false }
        return containsOurHook(permissionRequest)
    }

    private static func containsOurHook(_ value: Any) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        return groups.contains { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    // MARK: - Helpers

    enum SettingsError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            tr("~/.claude/settings.json exists but couldn't be parsed — not touching it")
        }
    }

    /// Missing file → fresh empty settings. An EXISTING file that doesn't
    /// parse as a JSON object throws instead: writing in that state would
    /// replace whatever the user had with just our hooks. We never "fix" or
    /// overwrite a file we can't fully read.
    private static func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.unreadable
        }
        return object
    }

    /// Every write to `~/.claude/settings.json` first snapshots the current
    /// file to `~/.petmacos/claude-settings.backup.json` (rolling, one copy).
    /// Combined with marker-scoped edits (only groups whose command contains
    /// `pet-hook.sh` are ever added/removed) and the atomic write below, a bad
    /// day can always be undone by copying the backup back by hand.
    private static func saveSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = PetConfig.directory.appendingPathComponent("claude-settings.backup.json")
            try? FileManager.default.createDirectory(
                at: PetConfig.directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
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
    if [ "$MODE" = "permission" ]; then
        # PermissionRequest fires only when a permission dialog is about to
        # appear, so there is nothing to filter here. Must not be wired to
        # PreToolUse: a decision there suppresses the dialog, and
        # PermissionRequest would never fire.
        TOOL=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        [ "$TOOL" = "AskUserQuestion" ] && exit 0
        RESPONSE=$(curl -s -m 300 -X POST "http://127.0.0.1:$PORT/ask" \\
            -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \\
            --data-binary "$PAYLOAD" 2>/dev/null)
        case "$RESPONSE" in
            *'"decision":"deny"'*)
                printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}\\n' ;;
            *'"decision":"allow"'*)
                printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\\n' ;;
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
