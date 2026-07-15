import SwiftUI

/// First-run "Kết nối Claude Code" wizard. Shown automatically the first time
/// the app launches with no hook installed and no onboarding flag set (see
/// `PetAppDelegate.shouldShowOnboarding`), and reachable afterwards from
/// Settings → "Mở lại hướng dẫn". Text-only, matches the rest of the app.
struct OnboardingWindowView: View {
    var delegate: PetAppDelegate
    /// Called when the window should close (Xong / Bỏ qua, or the window's
    /// own close button via `onDisappear`).
    var onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case intro, claudeCodeCheck, connect, done
    }

    @State private var step: Step = .intro
    @State private var claudeCodeInstalled = ClaudeCodeAvailability.isInstalled()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)

            Divider()

            HStack {
                Button("Bỏ qua") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                stepDots

                Spacer()

                navigationButton
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .onAppear { refreshChecks() }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: introStep
        case .claudeCodeCheck: claudeCodeCheckStep
        case .connect: connectStep
        case .done: doneStep
        }
    }

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chào mừng đến với Desktop Pet")
                .font(.title2).bold()
            Text("Desktop Pet là một chú chó để bàn phản ánh trạng thái làm việc của Claude Code — đang suy nghĩ, đang chạy tool, đang chờ bạn quyết định quyền, hay vừa xong việc. Chỉ mất khoảng 1 phút để kết nối.")
                .fixedSize(horizontal: false, vertical: true)

            if ClaudeCodeAvailability.isRunningOutsideApplications() {
                calloutBox(tone: .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("App đang chạy từ nơi tạm (chưa ở /Applications)")
                            .bold()
                        Text("Nên kéo Desktop Pet vào thư mục Applications trước khi kết nối, để cài đặt và hook không bị mất khi bạn đóng ổ đĩa DMG hoặc khởi động lại máy.")
                            .font(.callout)
                    }
                }
            }
        }
    }

    private var claudeCodeCheckStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kiểm tra Claude Code")
                .font(.title2).bold()

            if claudeCodeInstalled {
                calloutBox(tone: .green) {
                    Text("Đã tìm thấy Claude Code trên máy này. Có thể qua bước tiếp theo.")
                }
            } else {
                Text("Chưa tìm thấy Claude Code trên máy này (\(HomeDirCaption.claudeDir) hoặc lệnh claude). Claude Code là công cụ dòng lệnh chạy trong Terminal mà Desktop Pet theo dõi — cần cài nó trước khi kết nối.")
                    .fixedSize(horizontal: false, vertical: true)

                Link("Hướng dẫn cài Claude Code (claude.com/claude-code)",
                     destination: URL(string: "https://claude.com/claude-code")!)

                Button("Kiểm tra lại") { refreshChecks() }
            }
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kết nối Claude Code")
                .font(.title2).bold()
            Text("Bấm nút bên dưới để cài hook vào ~/.claude/settings.json. Việc này chỉ thêm một vài mục hook — không đụng tới cài đặt khác của bạn.")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(delegate.isConnected ? "Đã kết nối" : "Kết nối Claude Code") {
                    delegate.connectClaudeCode()
                    delegate.testHookConnection()
                }
                .disabled(delegate.isConnected && delegate.diagnosticTestResult?.success == true)
                .keyboardShortcut(.defaultAction)

                if delegate.diagnosticTestRunning {
                    ProgressView().controlSize(.small)
                    Text("Đang kiểm tra kết nối…").foregroundStyle(.secondary)
                }
            }

            if let result = delegate.diagnosticTestResult {
                calloutBox(tone: result.success ? .green : .orange) {
                    Text(result.message)
                }
            } else if delegate.isConnected {
                calloutBox(tone: .green) {
                    Text("Hook đã cài. Bấm \"Kết nối Claude Code\" một lần nữa để pet tự xác nhận, hoặc qua bước tiếp theo.")
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Xong! Giờ thử xem pet phản ứng")
                .font(.title2).bold()
            Text("Mở Terminal (hoặc IDE tích hợp), chạy \"claude\" để bắt đầu một phiên, rồi gõ thử một lệnh bất kỳ, ví dụ:")
                .fixedSize(horizontal: false, vertical: true)
            Text("liệt kê các file trong thư mục hiện tại")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Chú chó trên màn hình sẽ đổi biểu cảm khi Claude Code bắt đầu suy nghĩ, chạy tool, hoặc cần bạn duyệt quyền. Nếu sau vài phút vẫn không thấy gì, mở Cài đặt → tab \"Chẩn đoán\" để kiểm tra.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chrome

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var navigationButton: some View {
        if step == .done {
            Button("Xong") { finish() }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Tiếp tục") { advance() }
                .buttonStyle(.borderedProminent)
                .disabled(step == .claudeCodeCheck && !claudeCodeInstalled)
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
        if next == .claudeCodeCheck { refreshChecks() }
    }

    private func refreshChecks() {
        claudeCodeInstalled = ClaudeCodeAvailability.isInstalled()
        delegate.refreshConnectionStatus()
    }

    private func finish() {
        PetConfig.markOnboardingCompleted()
        onFinished()
    }

    @ViewBuilder
    private func calloutBox<Content: View>(tone: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(tone == .green ? Color.green : Color.orange)
    }
}

/// Small caption helper so the "not found" message stays readable without
/// hardcoding "~/.claude" twice.
private enum HomeDirCaption {
    static let claudeDir = "~/.claude"
}
