import SwiftUI

/// One card per Claude Code conversation (Codex-pet style), replacing the old
/// flat per-event card stack. The list is purely informational — the system
/// orders it by newest event (newest on top) and the user never selects or
/// reorders cards. Interaction is scroll-only:
///   - a "Latest ˄" pill at the TOP appears while newer cards sit hidden
///     above the viewport (user scrolled down) — tapping it scrolls back up,
///   - a "+n more ˅" pill at the BOTTOM appears while older cards sit hidden
///     below — tapping it scrolls down to them,
///   - tapping a card also scrolls back up to the newest card,
/// plus the in-card expand toggle on the subagent/background count line.
///
/// Visibility of both pills is driven by real geometry: every card reports
/// its frame in the scroll viewport's coordinate space via a preference, and
/// a card counts as "hidden" when its vertical midpoint is outside the
/// viewport. This is plain GeometryReader + PreferenceKey — stable on
/// macOS 14, no dependence on the newer scroll-position APIs.
struct SessionStackView: View {
    let summaries: [PetState.SessionSummary]
    let settings: SettingsStore
    let onDismissNotice: (UUID) -> Void
    let onDismissSubagent: (UUID) -> Void
    let onDismissBackground: (UUID) -> Void
    /// Reply v1: (sessionId, text) — send `text` into the session's tmux pane.
    let onSendReply: (String, String) -> Void

    /// Session ids whose task-count line is expanded into the task list.
    @State private var expandedTasks: Set<String> = []
    /// Each card's frame in the scroll viewport's coordinate space.
    @State private var cardFrames: [String: CGRect] = [:]
    /// The scroll viewport's own height.
    @State private var viewportHeight: CGFloat = 0

    private static let scrollSpace = "sessionScroll"

    /// Cards mostly hidden above the top edge (newer than what's visible).
    private var hiddenAboveCount: Int {
        cardFrames.values.filter { $0.midY < 0 }.count
    }

    /// Cards mostly hidden below the bottom edge (older than what's visible).
    private var hiddenBelowCount: Int {
        guard viewportHeight > 0 else { return 0 }
        return cardFrames.values.filter { $0.midY > viewportHeight }.count
    }

    var body: some View {
        ScrollViewReader { proxy in
            // The pills float OVER the scroll viewport (top/bottom aligned)
            // instead of stacking around it: if they took part in layout,
            // their appearance would resize the viewport and could flip a
            // boundary card's hidden/visible state right back — an
            // oscillation loop.
            scrollBody(proxy)
                .overlay(alignment: .top) {
                    if hiddenAboveCount > 0 {
                        pill("Latest ˄") { scrollToLatest(proxy) }
                            .padding(.top, 2)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hiddenBelowCount > 0 {
                        pill("+\(hiddenBelowCount) more ˅") {
                            guard let last = summaries.last?.id else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
        }
        .frame(maxWidth: 264)
        .animation(.easeInOut(duration: 0.15), value: hiddenAboveCount > 0)
        .animation(.easeInOut(duration: 0.15), value: hiddenBelowCount)
    }

    private func scrollBody(_ proxy: ScrollViewProxy) -> some View {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(summaries) { summary in
                            SessionCardView(
                                summary: summary,
                                settings: settings,
                                isExpanded: expandedTasks.contains(summary.id),
                                onToggleExpand: { toggleExpand(summary.id) },
                                onDismissNotice: onDismissNotice,
                                onDismissSubagent: onDismissSubagent,
                                onDismissBackground: onDismissBackground,
                                onSendReply: { text in onSendReply(summary.id, text) }
                            )
                            .id(summary.id)
                            .contentShape(Rectangle())
                            // A card is just text — tapping it only scrolls
                            // the list back to the newest card (no selection,
                            // no reordering; inner buttons still win the tap).
                            .onTapGesture { scrollToLatest(proxy) }
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardFramesKey.self,
                                    value: [summary.id: geo.frame(in: .named(Self.scrollSpace))]
                                )
                            })
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(CardFramesKey.self) { frames in
                    Task { @MainActor in cardFrames = frames }
                }
                .onPreferenceChange(ViewportHeightKey.self) { height in
                    Task { @MainActor in viewportHeight = height }
                }
                // A session rolling to the top (new event) scrolls itself
                // into view so the newest card is what the user sees by
                // default.
                .onChange(of: summaries.first?.id) { _, _ in
                    scrollToLatest(proxy)
                }
    }

    /// Shared style for the two scroll pills ("Latest ˄" / "+n more ˅").
    private func pill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(.secondary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let first = summaries.first?.id else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            proxy.scrollTo(first, anchor: .top)
        }
    }

    private func toggleExpand(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if expandedTasks.contains(id) {
                expandedTasks.remove(id)
            } else {
                expandedTasks.insert(id)
            }
        }
    }
}

/// Collects every card's frame (keyed by session id) in the scroll viewport's
/// coordinate space.
private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Reports the scroll viewport's height.
private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One conversation's card, top to bottom:
///   1. header — conversation name (bold) + project caption,
///   2. subagent/background count (expandable into the task list),
///   3. what's happening right now (newest running task or completed notice).
/// No status icon: the border colour already carries the state (orange while
/// active, gradient when done, red on error/failure).
private struct SessionCardView: View {
    let summary: PetState.SessionSummary
    let settings: SettingsStore
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onDismissNotice: (UUID) -> Void
    let onDismissSubagent: (UUID) -> Void
    let onDismissBackground: (UUID) -> Void
    /// Reply v1: send the typed text into this session's tmux pane.
    let onSendReply: (String) -> Void

    /// Text typed into this card's reply box (Reply v1).
    @State private var replyText = ""

    private static let maxListedTasks = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            taskCountLine
            if isExpanded { taskList }
            messageLine
            replyStatusLine
            replyBox
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderStyle, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary.name)
                .font(.caption)
                .bold()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let project = summary.project {
                Text(project)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Latest activity line

    /// The card's realtime line: the newest running task of this session, or
    /// (when nothing is running) its newest completed notice, with a ✕ so
    /// persistent notices can still be dismissed.
    @ViewBuilder
    private var messageLine: some View {
        if let running = summary.latestRunning {
            Text(joined(running.title, running.detail))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if let done = summary.latestCompleted {
            HStack(alignment: .top, spacing: 6) {
                Text(joined(done.title, done.detail))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onDismissNotice(done.id)
                } label: {
                    Text("✕")
                        .font(.caption2)
                        .bold()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func joined(_ title: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) — \(detail)"
    }

    // MARK: Reply v1 (tmux send-keys)

    /// Outcome of the most recent reply sent from this card — auto-clears in
    /// PetState (~20s, or on the session's next UserPromptSubmit).
    @ViewBuilder
    private var replyStatusLine: some View {
        if let status = summary.replyStatus {
            Group {
                switch status {
                case .sent:
                    Text("Đã gửi")
                        .foregroundStyle(.green)
                case .queued:
                    Text("Đã xếp hàng — Claude đang bận")
                        .foregroundStyle(.orange)
                case .failed(let reason):
                    Text("Không gửi được: \(reason)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
        }
    }

    /// One-line reply field, shown only when the session is reachable — via a
    /// live tmux pane (Reply v1) or a live channel bridge (Reply v1.1).
    /// Disabled (with an explanatory placeholder) while this session's
    /// own permission/question dialog is pending so a stray Enter can never
    /// land in the TUI's dialog.
    @ViewBuilder
    private var replyBox: some View {
        if summary.canReply {
            HStack(spacing: 6) {
                TextField(
                    summary.isAwaitingApproval ? "Đang chờ duyệt quyền…" : "Nhắn cho session…",
                    text: $replyText
                )
                .textFieldStyle(.plain)
                .font(.caption2)
                .disabled(summary.isAwaitingApproval)
                .onSubmit(sendReply)
                Button(action: sendReply) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(canSend ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .padding(.top, 2)
        }
    }

    private var canSend: Bool {
        !summary.isAwaitingApproval
            && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendReply() {
        guard canSend else { return }
        onSendReply(replyText.trimmingCharacters(in: .whitespacesAndNewlines))
        replyText = ""
    }

    // MARK: Task count + expandable list

    private var taskCount: Int { summary.subagents.count + summary.backgrounds.count }

    @ViewBuilder
    private var taskCountLine: some View {
        if taskCount > 0 {
            Button(action: onToggleExpand) {
                HStack(spacing: 4) {
                    Text(countText)
                        .font(.caption2)
                        .bold()
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var countText: String {
        var parts: [String] = []
        if !summary.subagents.isEmpty { parts.append("\(summary.subagents.count) subagent") }
        if !summary.backgrounds.isEmpty { parts.append("\(summary.backgrounds.count) chạy nền") }
        return parts.joined(separator: " · ")
    }

    private var taskList: some View {
        let all = summary.subagents.map { ($0, true) } + summary.backgrounds.map { ($0, false) }
        let shown = all.prefix(Self.maxListedTasks)
        let overflow = all.count - shown.count
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.0.id) { item, isSubagent in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isSubagent ? "person.2.fill" : "terminal.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        if isSubagent { onDismissSubagent(item.id) } else { onDismissBackground(item.id) }
                    } label: {
                        Text("✕")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Border

    /// Keeps the existing colour DNA: red for error/failed, the configured
    /// "completed" gradient when the session is done showing a result, and
    /// the configured (orange-default) tool colour while active.
    private var borderStyle: AnyShapeStyle {
        if summary.mood == .error || summary.latestCompleted?.kind == .failed {
            return AnyShapeStyle(Color.red.opacity(0.85))
        }
        let isDone = summary.latestRunning == nil && summary.latestCompleted != nil
            && (summary.mood == .idle || summary.mood == .talking || summary.mood == .sleep)
        if isDone {
            return AnyShapeStyle(settings.completedGradient)
        }
        return AnyShapeStyle(settings.borderColor(for: .tool))
    }
}
