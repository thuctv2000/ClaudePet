import SwiftUI

/// A floating speech bubble rendered above the dog. Sizes itself to its text
/// and points downward toward the pet with a small tail.
struct SpeechBubbleView: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 240, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                )

            Triangle()
                .fill(.regularMaterial)
                .frame(width: 18, height: 10)
                .offset(y: -1)
        }
        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
    }
}

/// Downward-pointing tail for the speech bubble.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
