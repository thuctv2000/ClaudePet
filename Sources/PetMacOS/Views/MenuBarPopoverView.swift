import AppKit
import SwiftUI

/// The panel that drops down when the menu bar icon is clicked.
///
/// It replaces the old plain `NSMenu`: instead of a list of verbs it shows what
/// the pet actually knows — which conversations are live, what each is doing
/// right now (with a running timer), how much of the Claude quota is gone — and
/// keeps only the switches worth reaching for every day. Everything else lives
/// one click away in Settings.
struct MenuBarPopoverView: View {
    var delegate: PetAppDelegate
    var state: PetState
    var usage: UsageMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            if state.pendingAskCount > 0 {
                pendingAskBanner
                separator
            }
            sessionSection
            separator
            usageSection
            separator
            controlSection
            separator
            footer
        }
        .frame(width: 320)
        .onAppear { delegate.refreshConnectionStatus() }
    }

    private var separator: some View {
        Divider().overlay(Color.primary.opacity(0.06))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "ClaudePet")
                    .font(.system(size: 14, weight: .bold))
                HStack(spacing: 5) {
                    StatusDot(color: delegate.isConnected ? .green : .secondary, size: 6)
                    Text(connectionLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(delegate.isConnected ? tr("Disconnect") : tr("Connect")) {
                delegate.isConnected ? delegate.disconnectClaudeCode() : delegate.connectClaudeCode()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The active pet's own face, so the panel belongs to *this* pet — falling
    /// back to the paw mark before any pet has frames.
    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.systemAccent.opacity(0.18))
            .frame(width: 32, height: 32)
            .overlay {
                if let image = delegate.petStore.pets.first(where: { $0.id == delegate.petStore.activeID })?.avatar {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.systemAccent)
                }
            }
    }

    private var connectionLine: String {
        guard delegate.isConnected else { return tr("Not connected") }
        if let port = delegate.serverPort {
            return String(format: tr("Connected · port %@"), String(port))
        }
        return tr("Connected")
    }

    // MARK: - Pending permission

    /// The one thing that must never be buried: Claude is blocked on the user.
    private var pendingAskBanner: some View {
        HStack(spacing: 9) {
            StatusDot(color: .orange, size: 8)
            Text(state.pendingAskCount == 1
                 ? tr("A permission request is waiting on the pet")
                 : String(format: tr("%d permission requests are waiting on the pet"), state.pendingAskCount))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Sessions

    private var sessions: [PetState.SessionSummary] { state.orderedSessionSummaries }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                EyebrowLabel(tr("Conversations"))
                Spacer()
                if !sessions.isEmpty {
                    Button(tr("Clear all")) {
                        for session in sessions { state.dismissSession(key: session.id) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 6)

            if sessions.isEmpty {
                Text(delegate.isConnected
                     ? tr("Nothing running right now.")
                     : tr("Connect Claude Code to see your conversations here."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                // Enough for a busy machine, but the panel must never grow into
                // a wall — the pet itself shows the full stack.
                ForEach(sessions.prefix(5)) { session in
                    SessionRow(summary: session) { state.dismissSession(key: session.id) }
                }
                if sessions.count > 5 {
                    Text(String(format: tr("+%d more"), sessions.count - 5))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 2)
                }
                Color.clear.frame(height: 8)
            }
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EyebrowLabel(tr("Claude usage"))
                Spacer()
                Button {
                    Task { await usage.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Refresh"))
            }
            UsageBar(title: tr("5-hour window"), window: usage.fiveHour, showsReset: false)
            UsageBar(title: tr("Week"), window: usage.sevenDay, showsReset: false)
            if let error = usage.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Controls

    private var controlSection: some View {
        VStack(spacing: 0) {
            controlRow(icon: "pawprint.fill", label: tr("Show pet"), isOn: Binding(
                get: { delegate.isVisible },
                set: { delegate.setPetVisible($0) }
            ))
            controlRow(icon: "hand.tap.fill", label: tr("Click-through"), isOn: Binding(
                get: { delegate.isClickThrough },
                set: { delegate.setClickThrough($0) }
            ))
        }
        .padding(.vertical, 4)
    }

    private func controlRow(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label).font(.system(size: 13))
            Spacer()
            AccentSwitch(isOn: isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            footerButton(icon: "gearshape.fill", label: tr("Settings")) {
                delegate.openSettingsWindow()
            }
            footerButton(icon: "arrow.triangle.2.circlepath", label: tr("Updates")) {
                delegate.updaterController?.checkForUpdates(nil)
            }
            .disabled(delegate.updaterController == nil)
            Spacer()
            footerButton(icon: "power", label: tr("Quit")) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - One conversation

/// A conversation as one line: mood dot, name + what it's doing, and either the
/// elapsed time (while live) or the time of its last event.
private struct SessionRow: View {
    let summary: PetState.SessionSummary
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: PetTheme.color(for: summary.mood))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(summary.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Only when it adds something: a session named after its
                    // own conversation in the same folder would just repeat.
                    if let project = summary.project, project != summary.name {
                        Text(project)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: activity.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(activity.tint)
                    Text(activity.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Visible here as well as on the card: with "Show pet" off the
            // cards are the one place this state used to live, and a message
            // can be waiting precisely because nothing is on screen.
            if summary.queuedReplies > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "tray.full.fill")
                    Text("\(summary.queuedReplies)")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .help(tr("Waiting to be delivered"))
            }
            Spacer(minLength: 8)
            if hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(tr("Dismiss this conversation"))
            } else {
                elapsed
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Live means work is genuinely in flight — those rows count up instead of
    /// showing a wall-clock stamp.
    private var isLive: Bool {
        switch summary.mood {
        case .working, .thinking, .asking: return true
        default: return !summary.subagents.isEmpty || !summary.backgrounds.isEmpty
        }
    }

    /// What this conversation is doing, as one icon + one line.
    ///
    /// Written against what the hooks actually deliver (see the card titles in
    /// `PetState.handle`): a running tool already carries a human title
    /// ("Query live pet state") plus its raw command as `detail` — the command
    /// is noise here, so only the title is shown. A finished session is the
    /// opposite: its title is the generic "Completed" and the *detail* holds
    /// Claude's whole markdown reply, so the first real line of that is what
    /// gets shown, stripped of markup.
    private var activity: (icon: String, tint: Color, text: String) {
        if let running = summary.latestRunning {
            return (icon(for: running.kind), tint(for: running.kind),
                    running.title.isEmpty ? (running.detail ?? "") : running.title)
        }
        let extra = summary.subagents.count + summary.backgrounds.count
        if extra > 0 {
            let newest = (summary.subagents + summary.backgrounds).max(by: { $0.startedAt < $1.startedAt })
            return ("person.2.fill", .blue,
                    newest.map { extra == 1 ? $0.title : "\($0.title) +\(extra - 1)" }
                        ?? String(format: tr("%d task(s) running"), extra))
        }
        if let done = summary.latestCompleted {
            let message = done.detail.map { PlainText.firstLine(of: $0) } ?? ""
            return (icon(for: done.kind), tint(for: done.kind),
                    message.isEmpty ? done.title : message)
        }
        return ("circle.dashed", .secondary, PetTheme.label(for: summary.mood))
    }

    private func icon(for kind: TaskKind) -> String {
        switch kind {
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver.fill"
        case .notification: return "bell.badge.fill"
        case .question: return "questionmark.bubble.fill"
        case .session: return "info.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .subagent: return "person.2.fill"
        case .background: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for kind: TaskKind) -> Color {
        switch kind {
        case .done: return .green
        case .failed: return .red
        case .notification, .question: return .orange
        case .thinking: return .purple
        default: return .blue
        }
    }

    /// How long this conversation has been at it, counting up live — or the
    /// time of its last event once it stops.
    ///
    /// The live case is `Text(timerInterval:)`, **not** a `TimelineView` or a
    /// `Timer`, because this row lives inside a `MenuBarExtra`: every tick that
    /// changes SwiftUI state there re-evaluates the whole scene, the icon's
    /// label included, and the status item visibly blinks once a second. Worse,
    /// the panel's window is kept alive after it is dismissed, so the blinking
    /// carried on forever once the panel had been opened a single time.
    /// `Text(timerInterval:)` is drawn by the system: the digits advance with
    /// no state change, so the icon is left alone (measured: label rebuilds
    /// drop from 1/s forever to 0).
    @ViewBuilder
    private var elapsed: some View {
        if isLive {
            let start = summary.latestRunning?.startedAt
                ?? summary.subagents.first?.startedAt
                ?? summary.backgrounds.first?.startedAt
                ?? summary.lastEventAt
            Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
                .monospacedDigit()
        } else {
            Text(summary.lastEventAt.formatted(date: .omitted, time: .shortened))
        }
    }
}

// MARK: - The menu bar icon itself

/// Draws the status item image. The paw alone when nothing needs the user, the
/// paw plus a count while conversations are live, and the whole thing tinted
/// orange the moment a permission is blocking Claude — so the menu bar answers
/// "does the pet need me?" without opening anything.
@MainActor
enum MenuBarIcon {
    private static var cacheKey: String = ""
    private static var cached: NSImage?

    /// How many times the status item has been rebuilt. Exposed in
    /// `/debug/state` — the only way to tell "the icon is flashing" from
    /// "the icon is fine and something else is moving".
    static private(set) var redraws = 0

    static func image(count: Int, waiting: Bool) -> NSImage {
        redraws += 1
        let key = "\(count)-\(waiting)"
        if key == cacheKey, let cached { return cached }

        let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "ClaudePet")
            ?? NSImage(size: NSSize(width: 16, height: 16))

        let result: NSImage
        if count <= 0 {
            paw.isTemplate = true
            result = paw
        } else {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let text = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let textSize = text.size(withAttributes: attributes)
            let pawSize = paw.size
            let gap: CGFloat = 3
            let width = ceil(pawSize.width + gap + textSize.width)
            let height = ceil(max(pawSize.height, textSize.height))

            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            paw.draw(in: NSRect(x: 0, y: (height - pawSize.height) / 2,
                                width: pawSize.width, height: pawSize.height))
            text.draw(at: NSPoint(x: pawSize.width + gap, y: (height - textSize.height) / 2),
                      withAttributes: attributes)
            if waiting {
                // Paint the whole glyph orange, keeping its alpha — a template
                // image can't carry colour, so this one opts out of templating.
                NSColor.systemOrange.set()
                NSRect(x: 0, y: 0, width: width, height: height).fill(using: .sourceAtop)
            }
            image.unlockFocus()
            image.isTemplate = !waiting
            result = image
        }

        cacheKey = key
        cached = result
        return result
    }
}
