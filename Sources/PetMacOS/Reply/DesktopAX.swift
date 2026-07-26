import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility access to the Claude Desktop app.
///
/// Hooks can reach a session only at a boundary — mid-turn (`PostToolUse`) or
/// at the end of one (`Stop`). A session sitting idle at its prompt fires no
/// hook at all, and nothing in Claude Code can wake it: `FileChanged` and the
/// `idle_prompt` `Notification` both run while idle but carry no way to inject
/// (measured, not assumed), and Claude.app opens no local port. So the idle
/// case has to be driven through the UI, the same way tmux drives a terminal.
///
/// This file is the reconnaissance half: read Claude.app's accessibility tree
/// and work out (a) whether the prompt box is reachable at all and (b) whether
/// anything identifies WHICH conversation is on screen. (b) is the one that
/// decides whether typing on the user's behalf is safe: the pet knows a
/// `session_id`, and putting a message into the wrong conversation is worse
/// than not delivering it.
enum DesktopAX {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's own Accessibility prompt when not yet trusted.
    /// The option key is spelled out rather than read from
    /// `kAXTrustedCheckOptionPrompt`: that symbol is an imported `var`, which
    /// Swift 6 rejects as shared mutable state. The string is API-stable.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    // MARK: - Attribute helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    // MARK: - Dump

    /// Walks Claude.app's window tree and returns it as indented text.
    ///
    /// Electron builds its accessibility tree lazily — Chromium only populates
    /// it once an assistive client asks — so `AXManualAccessibility` is set
    /// first and the walk waits a beat for the tree to appear. Without that the
    /// app looks like it has zero windows even when trust is granted.
    static func dump(maxDepth: Int = 24) -> String {
        var out: [String] = ["trusted: \(isTrusted)"]
        guard isTrusted else {
            out.append("not trusted — grant Accessibility to PetMacOS and retry")
            return out.joined(separator: "\n")
        }
        guard let app = runningApp else {
            out.append("Claude.app is not running")
            return out.joined(separator: "\n")
        }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)

        let windows = (attribute(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        out.append("pid: \(app.processIdentifier)  windows: \(windows.count)")

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth else { return }
            let role = string(element, kAXRoleAttribute as String) ?? "?"
            var line = String(repeating: "  ", count: depth) + role
            if let sub = string(element, kAXSubroleAttribute as String) { line += "/\(sub)" }
            if let ident = string(element, kAXIdentifierAttribute as String) { line += " id=\(ident)" }
            if (attribute(element, kAXFocusedAttribute as String) as? NSNumber)?.boolValue == true {
                line += " [FOCUSED]"
            }
            let title = string(element, kAXTitleAttribute as String)
            if let title { line += " title=\(clip(title))" }
            if let desc = string(element, kAXDescriptionAttribute as String), desc != title {
                line += " desc=\(clip(desc))"
            }
            if let value = string(element, kAXValueAttribute as String) {
                line += " value=\(clip(value, 160))"
            }
            out.append(line)
            for child in children(element) { walk(child, depth: depth + 1) }
        }

        for (index, window) in windows.enumerated() {
            out.append("=== WINDOW \(index) title=\(string(window, kAXTitleAttribute as String) ?? "?")")
            walk(window, depth: 1)
        }

        // The session pane lives in a second web view whose tree starts out
        // unbuilt (the sidebar's built on the first poke, this one didn't).
        // Poke every web area individually and re-walk: if the prompt shows up
        // this way it can be addressed directly, with no need to activate the
        // app and read AXFocusedUIElement.
        var webAreas: [AXUIElement] = []
        func collectWebAreas(_ element: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            if string(element, kAXRoleAttribute as String) == "AXWebArea" {
                webAreas.append(element)
            }
            for child in children(element) { collectWebAreas(child, depth: depth + 1) }
        }
        for window in windows { collectWebAreas(window, depth: 0) }
        out.append("=== WEB AREAS: \(webAreas.count) — poking each for accessibility")
        for area in webAreas {
            AXUIElementSetAttributeValue(area, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(area, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 2.5)
        var textAreas = 0
        func countInputs(_ element: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            let role = string(element, kAXRoleAttribute as String) ?? ""
            if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
                textAreas += 1
                out.append("  INPUT role=\(role)"
                    + " desc=\(string(element, kAXDescriptionAttribute as String) ?? "-")"
                    + " value=\(string(element, kAXValueAttribute as String).map { clip($0, 60) } ?? "-")")
            }
            for child in children(element) { countInputs(child, depth: depth + 1) }
        }
        for window in windows { countInputs(window, depth: 0) }
        out.append("  text inputs reachable by walking: \(textAreas)")

        // Setting the prompt's value works but Return posted to the pid does
        // not submit (Chromium drops key events when it isn't frontmost). A
        // button we can AXPress would avoid activating the app at all, so list
        // every control in the conversation pane and what it can do.
        out.append("=== CONTROLS IN THE CONVERSATION PANE")
        func listControls(_ element: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            let role = string(element, kAXRoleAttribute as String) ?? ""
            if role == (kAXButtonRole as String) || role == (kAXPopUpButtonRole as String)
                || role == (kAXCheckBoxRole as String) {
                let desc = string(element, kAXDescriptionAttribute as String)
                    ?? string(element, kAXTitleAttribute as String) ?? "-"
                var actions: CFArray?
                let names = AXUIElementCopyActionNames(element, &actions) == .success
                    ? ((actions as? [String]) ?? []).joined(separator: ",")
                    : "-"
                let enabled = (attribute(element, kAXEnabledAttribute as String) as? NSNumber)?
                    .boolValue ?? true
                out.append("  \(role) desc=\(clip(desc, 60)) enabled=\(enabled) actions=\(names)")
            }
            for child in children(element) { listControls(child, depth: depth + 1) }
        }
        // Only the pane that actually holds a prompt — the sidebar's buttons
        // are already known and would just be noise here.
        for area in webAreas {
            var found: [AXUIElement] = []
            collectPrompts(area, into: &found, depth: 0)
            guard !found.isEmpty else { continue }
            listControls(area, depth: 0)
        }

        // The focused element is a
        // separate question: some Electron apps answer it even when their tree
        // is unwalkable, and a focused text element would be enough to write
        // into without hunting for coordinates.
        out.append("=== FOCUSED ELEMENT")
        if let focused = attribute(ax, kAXFocusedUIElementAttribute as String) {
            // CFTypeRef -> AXUIElement is only safe once we know it is one.
            let element = unsafeBitCast(focused, to: AXUIElement.self)
            let role: String = string(element, kAXRoleAttribute as String) ?? "?"
            let sub: String = string(element, kAXSubroleAttribute as String) ?? "-"
            let title: String = string(element, kAXTitleAttribute as String) ?? "-"
            let desc: String = string(element, kAXDescriptionAttribute as String) ?? "-"
            let value: String = string(element, kAXValueAttribute as String) ?? "-"
            out.append("  role=\(role) sub=\(sub)")
            out.append("  title=\(clip(title))  desc=\(clip(desc))")
            out.append("  value=\(clip(value, 160))")
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            out.append("  AXValue settable: \(settable.boolValue)")
            var names: CFArray?
            if AXUIElementCopyAttributeNames(element, &names) == .success,
               let list = names as? [String] {
                out.append("  attributes: \(list.joined(separator: ", "))")
            }
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success,
               let list = actions as? [String] {
                out.append("  actions: \(list.joined(separator: ", "))")
            }
        } else {
            out.append("  (none reported)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Delivery to an idle Desktop session

    enum SendError: Error, Equatable {
        case notTrusted
        case appNotRunning
        /// No sidebar row carried this conversation's title.
        case conversationNotFound(String)
        /// More than one row had the same title — refusing to guess which.
        case ambiguousConversation(String, Int)
        /// Selecting the row didn't put focus in a prompt box.
        case promptNotFocused(String)
        /// The text went in but reading it back didn't match.
        case verificationFailed
        /// Text is in the prompt but nothing submitted it — the message is
        /// sitting there for the user to send by hand.
        case notSubmitted
    }

    /// Types `text` into the Desktop app's prompt for the conversation named
    /// `title`, and submits it.
    ///
    /// Every step is checked rather than assumed, because the failure this
    /// guards against is delivering a message into the WRONG conversation:
    ///  - the sidebar row must match the title EXACTLY once (zero or several
    ///    matches abort — the pet keeps the message queued instead),
    ///  - after pressing the row, the focused element must actually be the
    ///    prompt (`AXTextArea` described "Prompt"), not whatever else the app
    ///    focused,
    ///  - the text is read back before the Return key is sent, so nothing is
    ///    submitted that we cannot see.
    static func send(_ text: String, toConversationTitled title: String) -> Result<Void, SendError> {
        guard isTrusted else { return .failure(.notTrusted) }
        guard let app = runningApp else { return .failure(.appNotRunning) }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = (attribute(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []

        var matches: [AXUIElement] = []
        for window in windows { collectRows(window, title: title, into: &matches, depth: 0) }
        guard !matches.isEmpty else { return .failure(.conversationNotFound(title)) }
        guard matches.count == 1 else {
            return .failure(.ambiguousConversation(title, matches.count))
        }

        AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.8)

        // Deliberately NOT via `AXFocusedUIElement`: that only answers while
        // Claude.app is the active application, so a background pet always got
        // nil back and gave up. Poking each web area builds its tree instead,
        // after which the prompt is an ordinary walkable element — no need to
        // steal the user's focus.
        var webAreas: [AXUIElement] = []
        for window in windows { collectWebAreas(window, into: &webAreas, depth: 0) }
        for area in webAreas {
            AXUIElementSetAttributeValue(area, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 2.0)

        var prompts: [AXUIElement] = []
        for window in windows { collectPrompts(window, into: &prompts, depth: 0) }
        // Exactly one prompt is expected: only the open conversation has one.
        // Anything else means the app is in a shape this code doesn't model,
        // and typing blind into it is precisely what must not happen.
        guard prompts.count == 1 else {
            return .failure(.promptNotFocused("prompts=\(prompts.count)"))
        }
        let prompt = prompts[0]

        // Writing through AXSelectedText rather than AXValue. A raw AXValue
        // write paints the characters but fires no input event, so a React
        // editor still believes the box is empty — the text is visible and yet
        // unsendable, which is exactly the "typed but no Enter" symptom.
        // Replacing the selection is the path a real keystroke takes.
        AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.2)
        let existing = (string(prompt, kAXValueAttribute as String) ?? "").utf16.count
        var whole = CFRangeMake(0, existing)
        if let range = AXValueCreate(.cfRange, &whole) {
            AXUIElementSetAttributeValue(prompt, kAXSelectedTextRangeAttribute as CFString, range)
        }
        AXUIElementSetAttributeValue(prompt, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        Thread.sleep(forTimeInterval: 0.3)
        if string(prompt, kAXValueAttribute as String) != text {
            // Fall back to the blunt write; better a visible message the user
            // can send by hand than nothing at all.
            AXUIElementSetAttributeValue(prompt, kAXValueAttribute as CFString, text as CFTypeRef)
            Thread.sleep(forTimeInterval: 0.25)
            guard string(prompt, kAXValueAttribute as String) == text else {
                return .failure(.verificationFailed)
            }
        }

        // Prefer the app's own send control: pressing it needs no key events
        // and no activation. While Claude is working that button reads "Stop",
        // so it is matched by name and never pressed blind by position.
        var buttons: [AXUIElement] = []
        for window in windows { collectSendButtons(window, into: &buttons, depth: 0) }
        if let send = buttons.first {
            AXUIElementPerformAction(send, kAXPressAction as CFString)
            return .success(())
        }

        // No send control found: Return aimed at the process. This is the path
        // that did NOT submit in testing (Chromium ignores key events while it
        // isn't frontmost), so it is the fallback rather than the plan.
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.postToPid(app.processIdentifier)
        up?.postToPid(app.processIdentifier)
        return .failure(.notSubmitted)
    }

    /// Buttons that look like the prompt's send control. "Send feedback" is
    /// excluded explicitly — it sits in the sidebar and would fire a support
    /// form instead of the message.
    private static func collectSendButtons(
        _ element: AXUIElement, into found: inout [AXUIElement], depth: Int
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == (kAXButtonRole as String) {
            let label = (string(element, kAXDescriptionAttribute as String)
                ?? string(element, kAXTitleAttribute as String) ?? "").lowercased()
            let enabled = (attribute(element, kAXEnabledAttribute as String) as? NSNumber)?
                .boolValue ?? true
            if enabled, label.contains("send"), !label.contains("feedback") {
                found.append(element)
            }
        }
        for child in children(element) {
            collectSendButtons(child, into: &found, depth: depth + 1)
        }
    }

    private static func collectWebAreas(
        _ element: AXUIElement, into found: inout [AXUIElement], depth: Int
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == "AXWebArea" { found.append(element) }
        for child in children(element) { collectWebAreas(child, into: &found, depth: depth + 1) }
    }

    /// The message box of whichever conversation is open, identified by the
    /// role + "Prompt" description seen on the real app.
    private static func collectPrompts(
        _ element: AXUIElement, into found: inout [AXUIElement], depth: Int
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == (kAXTextAreaRole as String),
           string(element, kAXDescriptionAttribute as String) == "Prompt" {
            found.append(element)
        }
        for child in children(element) { collectPrompts(child, into: &found, depth: depth + 1) }
    }

    /// Collects sidebar rows whose own label equals `title`.
    ///
    /// Matched on the row's `AXStaticText` child rather than the button's
    /// title: the button title is prefixed with the run state ("Running Fix
    /// the parser"), which changes as the session runs, while the static text
    /// is the conversation name alone and lines up with what the pet resolved
    /// from the transcript.
    private static func collectRows(
        _ element: AXUIElement, title: String, into found: inout [AXUIElement], depth: Int
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == (kAXButtonRole as String) {
            let labels = children(element).compactMap { child -> String? in
                guard string(child, kAXRoleAttribute as String) == (kAXStaticTextRole as String)
                else { return nil }
                return string(child, kAXValueAttribute as String)
            }
            if labels.contains(title) { found.append(element) }
        }
        for child in children(element) {
            collectRows(child, title: title, into: &found, depth: depth + 1)
        }
    }

    private static func clip(_ text: String, _ limit: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
