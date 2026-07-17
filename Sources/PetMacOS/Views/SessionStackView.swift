import SwiftUI

/// One card per Claude Code conversation (Codex-pet style), replacing the old
/// flat per-event card stack. Cards grow from the BOTTOM: the newest card sits
/// right above the pet's head and a new conversation's card pushes the earlier
/// ones upward. The list is purely informational — the system orders it and
/// the user never selects or reorders cards. Interaction is scroll-only:
///   - a "+n more ˄" pill at the TOP appears while older cards sit hidden
///     above the viewport — tapping it scrolls up to them,
///   - a "Latest ˅" pill at the BOTTOM appears while the newest cards sit
///     hidden below (user scrolled up) — tapping it scrolls back down,
///   - tapping a card also scrolls back down to the newest card,
/// plus the in-card toggles (task list, full completion message) and the
/// header ✕ that dismisses the whole card.
///
/// Visibility of both pills is driven by real geometry: every card reports
/// its frame in the scroll viewport's coordinate space via a preference, and
/// a card counts as "hidden" when its vertical midpoint is outside the
/// viewport. This is plain GeometryReader + PreferenceKey — stable on
/// macOS 14, no dependence on the newer scroll-position APIs.
struct SessionStackView: View {
    let summaries: [PetState.SessionSummary]
    let settings: SettingsStore
    let onDismissCard: (String) -> Void
    let onDismissSubagent: (UUID) -> Void
    let onDismissBackground: (UUID) -> Void

    /// Session ids whose task-count line is expanded into the task list.
    @State private var expandedTasks: Set<String> = []
    /// Session ids whose completion message is expanded to full length.
    @State private var expandedMessages: Set<String> = []
    /// Each card's frame in the scroll viewport's coordinate space.
    @State private var cardFrames: [String: CGRect] = [:]
    /// The scroll viewport's own height.
    @State private var viewportHeight: CGFloat = 0

    private static let scrollSpace = "sessionScroll"

    /// Cards mostly hidden above the top edge (older than what's visible).
    private var hiddenAboveCount: Int {
        cardFrames.values.filter { $0.midY < 0 }.count
    }

    /// Cards mostly hidden below the bottom edge (newer than what's visible).
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
                        pill(String(format: tr("+%d more ˄"), hiddenAboveCount)) {
                            guard let oldest = summaries.last?.id else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                proxy.scrollTo(oldest, anchor: .top)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hiddenBelowCount > 0 {
                        pill(tr("Latest ˅")) { scrollToLatest(proxy) }
                            .padding(.bottom, 2)
                    }
                }
        }
        .frame(maxWidth: 264)
        .animation(.easeInOut(duration: 0.15), value: hiddenAboveCount)
        .animation(.easeInOut(duration: 0.15), value: hiddenBelowCount > 0)
    }

    private func scrollBody(_ proxy: ScrollViewProxy) -> some View {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        // `summaries` is newest-first; render reversed so the
                        // newest card lands at the bottom, nearest the pet.
                        ForEach(summaries.reversed()) { summary in
                            SessionCardView(
                                summary: summary,
                                settings: settings,
                                isExpanded: expandedTasks.contains(summary.id),
                                isMessageExpanded: expandedMessages.contains(summary.id),
                                onToggleExpand: { toggle(summary.id, in: &expandedTasks) },
                                onToggleMessage: { toggle(summary.id, in: &expandedMessages) },
                                onDismissCard: onDismissCard,
                                onDismissSubagent: onDismissSubagent,
                                onDismissBackground: onDismissBackground
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
                // Bottom anchor does double duty: short content hugs the
                // bottom edge (cards start just above the pet) and the list
                // opens scrolled to the newest card.
                .defaultScrollAnchor(.bottom)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(CardFramesKey.self) { frames in
                    Task { @MainActor in cardFrames = frames }
                }
                .onPreferenceChange(ViewportHeightKey.self) { height in
                    Task { @MainActor in viewportHeight = height }
                }
                // A session rolling to the front (new event) scrolls itself
                // into view so the newest card is what the user sees by
                // default.
                .onChange(of: summaries.first?.id) { _, _ in
                    scrollToLatest(proxy)
                }
    }

    /// Shared style for the two scroll pills ("+n more ˄" / "Latest ˅").
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
        guard let newest = summaries.first?.id else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            proxy.scrollTo(newest, anchor: .bottom)
        }
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
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
///   1. header — conversation name (bold) + project caption, with a ✕ on the
///      title row that dismisses the whole card,
///   2. subagent/background count (expandable into the task list),
///   3. what's happening right now — the newest running task (2 lines max),
///      or the completed result: 2 lines collapsed, tap to expand to the full
///      message (expansion only exists once the work is done).
/// No status icon: the border colour already carries the state (orange while
/// active, gradient when done, red on error/failure).
private struct SessionCardView: View {
    let summary: PetState.SessionSummary
    let settings: SettingsStore
    let isExpanded: Bool
    let isMessageExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleMessage: () -> Void
    let onDismissCard: (String) -> Void
    let onDismissSubagent: (UUID) -> Void
    let onDismissBackground: (UUID) -> Void

    private static let maxListedTasks = 5
    private static let collapsedMessageLines = 2

    /// Measured heights of the completion message at 2 lines vs unbounded
    /// (via hidden probes) — the expand affordance only appears when the
    /// message actually overflows the collapsed height.
    @State private var collapsedMessageHeight: CGFloat = 0
    @State private var fullMessageHeight: CGFloat = 0

    private var messageOverflows: Bool {
        fullMessageHeight > collapsedMessageHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            taskCountLine
            if isExpanded { taskList }
            messageLine
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
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let project = summary.project {
                    Text(project)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Button {
                onDismissCard(summary.id)
            } label: {
                Text("✕")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Latest activity line

    /// The card's realtime line: the newest running task of this session
    /// (2 lines, no expansion while work is in flight), or — once done — its
    /// newest completed notice, collapsed to 2 lines and tappable to reveal
    /// the full message.
    @ViewBuilder
    private var messageLine: some View {
        if let running = summary.latestRunning {
            Text(joined(running.title, running.detail))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(Self.collapsedMessageLines)
        } else if let done = summary.latestCompleted {
            let message = joined(done.title, done.detail)
            let canExpand = messageOverflows || isMessageExpanded
            Button(action: onToggleMessage) {
                HStack(alignment: .top, spacing: 6) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(isMessageExpanded ? nil : Self.collapsedMessageLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(messageProbes(message))
                    if canExpand {
                        Image(systemName: isMessageExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canExpand)
        }
    }

    /// Two hidden copies of the message — one clamped to the collapsed line
    /// count, one unbounded — laid out at the same width as the visible text,
    /// reporting their heights so `messageOverflows` reflects real truncation.
    private func messageProbes(_ message: String) -> some View {
        ZStack {
            probeText(message)
                .lineLimit(Self.collapsedMessageLines)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { collapsedMessageHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in collapsedMessageHeight = h }
                })
            probeText(message)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { fullMessageHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in fullMessageHeight = h }
                })
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// Probe copy of the message: identical font/width behaviour, no styling.
    private func probeText(_ message: String) -> some View {
        Text(message)
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func joined(_ title: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) — \(detail)"
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
        if !summary.backgrounds.isEmpty { parts.append("\(summary.backgrounds.count) \(tr("background"))") }
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
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
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
