import SwiftUI

/// Compact, always-visible badge showing the Claude usage-limit percentages
/// (5-hour window and weekly window), like Claude Code's /usage.
/// Styled as a dark HUD pill so it stays readable over any wallpaper.
struct UsageBadgeView: View {
    var usage: UsageMonitor

    var body: some View {
        HStack(spacing: 10) {
            meter(label: "5h", window: usage.fiveHour)
            Rectangle()
                .fill(.white.opacity(0.25))
                .frame(width: 1, height: 12)
            meter(label: "Tuần", window: usage.sevenDay)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.62)))
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        .help(usage.lastError ?? "Mức sử dụng Claude (5 giờ / tuần)")
    }

    @ViewBuilder
    private func meter(label: String, window: UsageMonitor.Window?) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .bold()
                .foregroundStyle(.white.opacity(0.85))
            if let window {
                bar(fraction: window.utilization / 100)
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.caption)
                    .bold()
                    .monospacedDigit()
                    .foregroundStyle(color(for: window.utilization))
            } else {
                Text("—")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func bar(fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22))
            Capsule()
                .fill(color(for: fraction * 100))
                .frame(width: max(4, 46 * min(max(fraction, 0), 1)))
        }
        .frame(width: 46, height: 6)
    }

    /// Bright variants that hold up against the dark pill.
    private func color(for percent: Double) -> Color {
        switch percent {
        case ..<70: return Color(red: 0.35, green: 0.90, blue: 0.55)
        case ..<90: return Color(red: 1.0, green: 0.72, blue: 0.25)
        default: return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }
}
