import SwiftUI

/// Vertical stack of task cards shown above the dog: persistent completed
/// notices on top, transient running tasks below (closest to the pet's head).
struct TaskStackView: View {
    let running: [TaskItem]
    let completed: [TaskItem]
    let settings: SettingsStore
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Completed notices stay until the user closes them.
            ForEach(completed) { item in
                CompletedCard(item: item, gradient: settings.completedGradient,
                              onDismiss: { onDismiss(item.id) })
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }

            // Running tasks: newest on top, older ones shrink and fade for a
            // stacked look. Closest to the dog's head at the bottom.
            VStack(spacing: 6) {
                ForEach(Array(running.enumerated()), id: \.element.id) { index, item in
                    RunningCard(item: item, borderColor: settings.borderColor(for: item.kind))
                        .scaleEffect(scale(for: index))
                        .opacity(opacity(for: index))
                        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: 264)
    }

    private func scale(for index: Int) -> CGFloat {
        switch index {
        case 0: return 1.0
        case 1: return 0.96
        default: return 0.92
        }
    }

    private func opacity(for index: Int) -> Double {
        switch index {
        case 0: return 1.0
        case 1: return 0.85
        default: return 0.7
        }
    }
}

/// A transient running-task card with a solid, kind-coloured border.
private struct RunningCard: View {
    let item: TaskItem
    let borderColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.caption)
                .bold()
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let detail = item.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
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
                .stroke(borderColor, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }
}

/// A persistent completed notice with a gradient border and a close button.
/// Tapping the card toggles between a truncated and a full, scrollable detail.
private struct CompletedCard: View {
    let item: TaskItem
    let gradient: LinearGradient
    let onDismiss: () -> Void

    @State private var isExpanded = false

    /// Roughly the point past which the collapsed 4-line limit starts hiding text.
    private var isLong: Bool { (item.detail?.count ?? 0) > 160 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.primary)
                if let detail = item.detail {
                    if isExpanded {
                        ScrollView {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    } else {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    if isLong {
                        Text(isExpanded ? "thu gọn" : "bấm để xem thêm")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Text("✕")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(gradient, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isLong { withAnimation { isExpanded.toggle() } }
        }
    }
}
