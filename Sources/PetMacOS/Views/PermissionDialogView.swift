import SwiftUI

/// Allow/Deny dialog shown above the dog when Claude Code requests permission.
struct PermissionDialogView: View {
    let ask: PendingAsk
    let onAllow: (String) -> Void
    let onDeny: (String) -> Void

    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Claude xin quyền")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(ask.toolName)
                .font(.system(size: 14, weight: .bold))

            if let conversationName = ask.conversationName {
                Text(conversationName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let summary = ask.summary {
                ScrollView {
                    Text(summary)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.06))
                )
            }

            TextField("Ghi chú cho Claude (tùy chọn)", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                Button { onDeny(note) } label: {
                    Text("Từ chối").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button { onAllow(note) } label: {
                    Text("Cho phép").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 264)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        )
        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
    }
}
