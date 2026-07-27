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

    static var runningApp: NSRunningApplication? { app(bundleID) }

    static func app(_ identifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == identifier }
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
    static func dump(bundle: String = bundleID, maxDepth: Int = 24) -> String {
        var out: [String] = ["trusted: \(isTrusted)"]
        guard isTrusted else {
            out.append("not trusted — grant Accessibility to PetMacOS and retry")
            return out.joined(separator: "\n")
        }
        guard let app = app(bundle) else {
            out.append("\(bundle) is not running")
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

    /// Types `text` into the prompt of the conversation named `title` in one
    /// of the supported host apps, and submits it.
    ///
    /// Every step is checked rather than assumed, because the failure this
    /// guards against is delivering into the WRONG conversation. The two hosts
    /// identify a conversation differently:
    ///  - Claude Desktop lists them in a sidebar, so the matching row is
    ///    pressed to open it (exactly one row must match, or this gives up),
    ///  - VS Code gives each session its own window titled "<name> — <folder>",
    ///    so the matching window is used directly and nothing is clicked.
    static func send(
        _ text: String, toConversationTitled title: String, bundle: String = bundleID
    ) -> Result<Void, SendError> {
        guard isTrusted else { return .failure(.notTrusted) }
        guard let app = app(bundle) else { return .failure(.appNotRunning) }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let allWindows = (attribute(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []

        // Scope: for VS Code the session IS a window; for Claude Desktop every
        // window is a candidate and the sidebar row picks the conversation.
        var scope = allWindows
        if bundle != bundleID {
            let matching = allWindows.filter { window in
                guard let windowTitle = string(window, kAXTitleAttribute as String) else { return false }
                return windowTitle == title || windowTitle.hasPrefix(title + " — ")
                    || windowTitle.hasPrefix(title + " - ")
            }
            guard !matching.isEmpty else { return .failure(.conversationNotFound(title)) }
            guard matching.count == 1 else {
                return .failure(.ambiguousConversation(title, matching.count))
            }
            scope = matching
        } else {
            var rows: [AXUIElement] = []
            for window in allWindows { collectRows(window, title: title, into: &rows, depth: 0) }
            guard !rows.isEmpty else { return .failure(.conversationNotFound(title)) }
            guard rows.count == 1 else {
                return .failure(.ambiguousConversation(title, rows.count))
            }
            AXUIElementPerformAction(rows[0], kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.8)
        }

        // Deliberately NOT via `AXFocusedUIElement`: that only answers while
        // the host app is active, so a background pet always got nil back.
        // Poking each web area builds its tree instead, after which the prompt
        // is an ordinary walkable element — no need to steal the user's focus.
        var webAreas: [AXUIElement] = []
        for window in scope { collectWebAreas(window, into: &webAreas, depth: 0) }
        for area in webAreas {
            AXUIElementSetAttributeValue(area, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 2.0)

        var prompts: [AXUIElement] = []
        for window in scope { collectPrompts(window, into: &prompts, depth: 0) }
        guard prompts.count == 1 else {
            return .failure(.promptNotFocused("prompts=\(prompts.count)"))
        }
        let prompt = prompts[0]

        // Which controls are live BEFORE typing. Both hosts disable their send
        // button while the box is empty, so the button that switches on after
        // the write is the send control — a far sturdier signal than matching
        // a label (VS Code's is literally described "-"), and it doubles as
        // proof that the app registered the text rather than just displaying it.
        let before = enabledButtonIDs(in: scope)
        let previous = string(prompt, kAXValueAttribute as String) ?? ""

        // Writing through AXSelectedText rather than AXValue. A raw AXValue
        // write paints the characters but fires no input event, so a React
        // editor still believes the box is empty — visible yet unsendable,
        // which is exactly the "typed but no Enter" symptom.
        AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.2)
        let existing = (string(prompt, kAXValueAttribute as String) ?? "").utf16.count
        var whole = CFRangeMake(0, existing)
        if let range = AXValueCreate(.cfRange, &whole) {
            AXUIElementSetAttributeValue(prompt, kAXSelectedTextRangeAttribute as CFString, range)
        }
        AXUIElementSetAttributeValue(prompt, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        Thread.sleep(forTimeInterval: 0.4)
        if string(prompt, kAXValueAttribute as String) != text {
            AXUIElementSetAttributeValue(prompt, kAXValueAttribute as CFString, text as CFTypeRef)
            Thread.sleep(forTimeInterval: 0.3)
            guard string(prompt, kAXValueAttribute as String) == text else {
                return .failure(.verificationFailed)
            }
        }

        Thread.sleep(forTimeInterval: 0.4)
        if let send = newlyEnabledButton(in: scope, comparedTo: before) {
            AXUIElementPerformAction(send, kAXPressAction as CFString)
            return .success(())
        }
        // Named fallback, for a host that keeps its send button always enabled.
        var named: [AXUIElement] = []
        for window in scope { collectSendButtons(window, into: &named, depth: 0) }
        if let send = named.first {
            AXUIElementPerformAction(send, kAXPressAction as CFString)
            return .success(())
        }
        // Nothing became pressable. In VS Code that is not a missing button —
        // it is the send control staying DISABLED with text visibly in the box,
        // which proves the extension never registered the write: AX painted the
        // characters into the DOM but the editor's own state stayed empty. So
        // reading the value back is not proof of anything; this button is.
        //
        // Put the box back the way it was found. Leaving the text behind is
        // worse than not delivering: it silently pollutes the user's own prompt
        // with a message that was never sent, and the next attempt stacks
        // another one on top.
        AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var restoreRange = CFRangeMake(0, text.utf16.count)
        if let range = AXValueCreate(.cfRange, &restoreRange) {
            AXUIElementSetAttributeValue(prompt, kAXSelectedTextRangeAttribute as CFString, range)
        }
        AXUIElementSetAttributeValue(prompt, kAXSelectedTextAttribute as CFString, "" as CFTypeRef)
        AXUIElementSetAttributeValue(prompt, kAXValueAttribute as CFString, previous as CFTypeRef)

        // Last resort: type it the way a person would. The AX write is
        // invisible to this app's editor, but real key events are not — they
        // go through the same path as the keyboard, so the editor's own state
        // updates and its send button comes alive.
        //
        // The catch is that Chromium only accepts key events while it is the
        // active app (postToPid alone is dropped), so the app has to be brought
        // forward for the moment it takes to type. The previously-active app is
        // put back straight after, so the interruption is a blink rather than a
        // change of context.
        if typeWithRealKeys(text, into: prompt, app: app) {
            return .success(())
        }
        return .failure(.notSubmitted)
    }


    /// Types `text` into `prompt` with real key events and presses Return.
    /// Returns false if the app could not be brought forward.
    private static func typeWithRealKeys(
        _ text: String, into prompt: AXUIElement, app: NSRunningApplication
    ) -> Bool {
        let previouslyActive = NSWorkspace.shared.frontmostApplication
        guard app.activate(options: []) else { return false }
        Thread.sleep(forTimeInterval: 0.5)
        // Put the caret in the message box rather than wherever the app last
        // had focus — activating a window does not choose a field.
        AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.3)

        let source = CGEventSource(stateID: .hidSystemState)
        // Sent as unicode payloads rather than key codes: the message can hold
        // any script (Vietnamese, emoji) and there is no layout that maps those
        // to virtual keys. Chunked because a single event carries a limited
        // string, and paced so a busy renderer does not drop characters.
        for chunk in text.chunks(ofUTF16Length: 16) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            else { continue }
            var utf16 = Array(chunk.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.35)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)

        previouslyActive?.activate(options: [])
        return true
    }


    // MARK: - VS Code: the extension's own URI handler

    /// Delivers into a VS Code session through the extension's registered URI
    /// handler, then presses its send button.
    ///
    /// Writing the prompt with accessibility does not work here: the text
    /// appears in the box but the editor never registers it, and its send
    /// button stays disabled. Both states were observed side by side in the
    /// same window — an AX-written box with a dead button, and a URI-written
    /// box with a live one.
    ///
    /// The extension registers `vscode://<id>/open?session=…&prompt=…`
    /// (`registerUriHandler` in its bundle, routing to
    /// `claude-vscode.primaryEditor.open`). That is the app's own input path,
    /// so the text lands properly — it just isn't submitted, which is what the
    /// button press is for. It also takes the **session id**, so this is the
    /// only surface addressed by an exact identifier rather than a title.
    static func sendViaVSCodeURI(_ text: String, sessionId: String) -> Result<Void, SendError> {
        guard isTrusted else { return .failure(.notTrusted) }
        guard let app = app(vscodeBundleID) else { return .failure(.appNotRunning) }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows = (attribute(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        var areas: [AXUIElement] = []
        for window in windows { collectWebAreas(window, into: &areas, depth: 0) }
        for area in areas {
            AXUIElementSetAttributeValue(area, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 1.0)
        // The send button is disabled while the box is empty, so whichever one
        // switches on after the prompt arrives is the one belonging to it.
        let before = enabledButtonIDs(in: windows)

        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "prompt", value: text),
        ]
        guard let url = components.url else { return .failure(.verificationFailed) }
        NSWorkspace.shared.open(url)
        Thread.sleep(forTimeInterval: 3.0)

        // Re-read: opening the URI can create a new panel/window.
        windows = (attribute(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        areas = []
        for window in windows { collectWebAreas(window, into: &areas, depth: 0) }
        for area in areas {
            AXUIElementSetAttributeValue(area, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 1.5)

        var prompts: [AXUIElement] = []
        for window in windows { collectPrompts(window, into: &prompts, depth: 0) }
        if prompts.contains(where: { string($0, kAXValueAttribute as String) == text }) {
            guard let send = newlyEnabledButton(in: windows, comparedTo: before) else {
                // Text is in the box and properly registered — the user can
                // send it by hand — but the control to do it wasn't found.
                return .failure(.notSubmitted)
            }
            AXUIElementPerformAction(send, kAXPressAction as CFString)
            return .success(())
        }

        // The prompt was dropped, which happens for the case this feature is
        // actually about. The extension applies a URI prompt only when it
        // CREATES a panel; for a session already on screen it reveals the panel
        // and discards the text outright:
        //
        //   if (panel) { panel.reveal();
        //                if (prompt) showInformationMessage(
        //                  "Session is already open. Your prompt was not applied…") }
        //
        // The reveal is still worth having — it brought the right session's
        // panel to the front — so typing carries on from there. Real key events
        // are used because an accessibility write is invisible to this editor
        // (its send button stays disabled), and they only land while the app is
        // active, which the reveal has just arranged.
        guard let focusedRef = attribute(ax, kAXFocusedUIElementAttribute as String) else {
            return .failure(.promptNotFocused("revealed but no focused element"))
        }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
        guard promptDescriptions.contains(string(focused, kAXDescriptionAttribute as String) ?? "")
        else {
            // Refuse rather than type into whatever else holds focus.
            return .failure(.promptNotFocused(
                "focus is on \(string(focused, kAXDescriptionAttribute as String) ?? "?")"))
        }
        guard typeWithRealKeys(text, into: focused, app: app) else {
            return .failure(.notSubmitted)
        }
        return .success(())
    }

    static let vscodeBundleID = "com.microsoft.VSCode"

    /// Identity of every enabled button in scope. AXUIElement isn't Hashable,
    /// so buttons are keyed by position+size+label, which is stable across the
    /// few hundred milliseconds between the two scans.
    private static func enabledButtonIDs(in scope: [AXUIElement]) -> Set<String> {
        var ids = Set<String>()
        for window in scope { collectButtonIDs(window, into: &ids, depth: 0, enabledOnly: true) }
        return ids
    }

    private static func newlyEnabledButton(
        in scope: [AXUIElement], comparedTo before: Set<String>
    ) -> AXUIElement? {
        var candidates: [(String, AXUIElement)] = []
        for window in scope { collectButtons(window, into: &candidates, depth: 0) }
        return candidates.first { id, _ in !before.contains(id) }?.1
    }

    private static func buttonIdentity(_ element: AXUIElement) -> String {
        let label = string(element, kAXDescriptionAttribute as String)
            ?? string(element, kAXTitleAttribute as String) ?? "-"
        var point = CGPoint.zero
        var size = CGSize.zero
        if let raw = attribute(element, kAXPositionAttribute as String) {
            AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point)
        }
        if let raw = attribute(element, kAXSizeAttribute as String) {
            AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size)
        }
        return "\(label)@\(Int(point.x)),\(Int(point.y)) \(Int(size.width))x\(Int(size.height))"
    }

    private static func collectButtonIDs(
        _ element: AXUIElement, into ids: inout Set<String>, depth: Int, enabledOnly: Bool
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == (kAXButtonRole as String) {
            let enabled = (attribute(element, kAXEnabledAttribute as String) as? NSNumber)?
                .boolValue ?? true
            if !enabledOnly || enabled { ids.insert(buttonIdentity(element)) }
        }
        for child in children(element) {
            collectButtonIDs(child, into: &ids, depth: depth + 1, enabledOnly: enabledOnly)
        }
    }

    private static func collectButtons(
        _ element: AXUIElement, into found: inout [(String, AXUIElement)], depth: Int
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == (kAXButtonRole as String),
           (attribute(element, kAXEnabledAttribute as String) as? NSNumber)?.boolValue ?? true {
            found.append((buttonIdentity(element), element))
        }
        for child in children(element) { collectButtons(child, into: &found, depth: depth + 1) }
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

    /// How each host app labels its message box. Claude Desktop says "Prompt";
    /// the VS Code extension says "Message input".
    static let promptDescriptions: Set<String> = ["Prompt", "Message input"]

    /// The message box of whichever conversation is open, identified by role +
    /// one of the known descriptions.
    private static func collectPrompts(
        _ element: AXUIElement, into found: inout [AXUIElement], depth: Int
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == (kAXTextAreaRole as String),
           let desc = string(element, kAXDescriptionAttribute as String),
           promptDescriptions.contains(desc) {
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

private extension String {
    /// Splits into pieces of at most `length` UTF-16 units, without cutting a
    /// character in half (an emoji is several units and must stay whole).
    func chunks(ofUTF16Length length: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in self {
            if current.utf16.count + character.utf16.count > length, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
