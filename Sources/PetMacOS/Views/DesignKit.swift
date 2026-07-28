import AppKit
import SwiftUI

/// Small shared building blocks for the menu bar popover and the settings
/// window, so both surfaces look like one app: the same accent, the same
/// status dots, the same switch, the same section headers.
extension Color {
    /// The real system accent colour. Unlike `Color.accentColor` it does not
    /// desaturate to grey when the window isn't key — which our non-activating
    /// panel and the menu bar popover never are.
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }
}

enum PetTheme {
    /// One colour per mood, shared by the popover's session dots and the
    /// settings window, so a state always reads the same everywhere.
    @MainActor
    static func color(for mood: PetState.Mood) -> Color {
        switch mood {
        case .asking: return .orange
        case .error: return .red
        case .working: return .blue
        case .thinking: return .purple
        case .talking: return .green
        case .sleep: return .gray
        case .idle: return .secondary
        }
    }

    @MainActor
    static func label(for mood: PetState.Mood) -> String {
        switch mood {
        case .asking: return tr("Waiting for you")
        case .error: return tr("Error")
        case .working: return tr("Running a tool")
        case .thinking: return tr("Thinking")
        case .talking: return tr("Replying")
        case .sleep: return tr("Session ended")
        case .idle: return tr("Idle")
        }
    }

    /// Colour for a usage percentage: calm until it actually matters.
    static func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .orange
        }
    }
}

/// A small status dot. Deliberately static.
///
/// It used to breathe (a `repeatForever` ring) for live states, and that is
/// what made the menu bar panel flash: every label in the panel dropped out and
/// came back, over and over, for as long as one conversation was live.
/// Measured — 10 khung liên tiếp của panel: với vòng pulse, 36–86% pixel đổi
/// giữa các khung; bỏ nó ra, 0 pixel đổi. A `repeatForever` animation inside a
/// `MenuBarExtra` window is not worth it: the live cue is already carried by
/// the mood colour, the line saying what is running, and the counting timer.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// A switch drawn with explicit colours so its ON state keeps the system accent
/// even in a non-key window (AppKit's own switch greys out there).
struct AccentSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        // A Button rather than a tap gesture: inside a Form row or a popover a
        // gesture on a bare shape is regularly swallowed by the row itself.
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? Color.systemAccent : Color(nsColor: .quaternaryLabelColor))
                .frame(width: 34, height: 19)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.18), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

/// Small uppercase tracked section header ("SESSIONS", "USAGE"…).
struct EyebrowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.tertiary)
    }
}

/// A thin labelled usage meter — the 5-hour and weekly windows at a glance.
struct UsageBar: View {
    let title: String
    let window: UsageMonitor.Window?
    var showsReset = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if let window {
                    Text("\(Int(window.utilization.rounded()))%")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(PetTheme.usageColor(window.utilization))
                } else {
                    Text(tr("no data yet"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                let fraction = min(max((window?.utilization ?? 0) / 100, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(PetTheme.usageColor(window?.utilization ?? 0))
                        .frame(width: max(fraction * geo.size.width, fraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 5)
            if showsReset, let resets = window?.resetsAt {
                Text(String(format: tr("reset %@"), resets.formatted(date: .abbreviated, time: .shortened)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Turns a card's message into one clean line fit for a narrow row.
///
/// Completed notices carry Claude's whole reply — real markdown, headings,
/// code fences, several paragraphs (see the `.done` cards in
/// `PetState.pushStopNotice`). Rendered raw in a 320pt row that reads as
/// `"## Kết quả **Panel** menu bar…"`. This takes the first line that actually
/// says something and strips the markup off it.
enum PlainText {
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#)

    static func firstLine(of text: String) -> String {
        var inFence = false
        // A reply that opens with "## Kết quả" says more in the sentence under
        // the heading than in the heading itself, so headings are only used
        // when nothing else follows.
        var heading: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            let isHeading = line.hasPrefix("#")
            // Leading block markers: headings, quotes, bullets, "1." lists.
            while let first = line.first, "#>-*•".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let dot = line.firstIndex(of: "."),
               line[line.startIndex..<dot].allSatisfy(\.isNumber), dot > line.startIndex {
                line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            line = inlineStripped(line)
            if line.isEmpty { continue }
            if isHeading {
                if heading == nil { heading = line }
                continue
            }
            return line
        }
        return heading ?? ""
    }

    /// Emphasis, inline code and link syntax — the markup that survives inside
    /// a line once its leading marker is gone.
    private static func inlineStripped(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        var result = link.stringByReplacingMatches(in: line, range: range, withTemplate: "$1")
        for token in ["**", "__", "`", "*", "_"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Rounded translucent card used for the hero blocks in Settings.
struct CardBackground: ViewModifier {
    var corner: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func petCard(corner: CGFloat = 14) -> some View { modifier(CardBackground(corner: corner)) }
}
