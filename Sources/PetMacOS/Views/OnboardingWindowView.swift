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
                Button(tr("Skip")) { finish() }
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
            Text(tr("Welcome to Desktop Pet"))
                .font(.title2).bold()
            Text(tr("Desktop Pet is a desktop dog that reflects what Claude Code is doing — thinking, running a tool, waiting on a permission decision, or just finished. Connecting only takes about a minute."))
                .fixedSize(horizontal: false, vertical: true)

            if ClaudeCodeAvailability.isRunningOutsideApplications() {
                calloutBox(tone: .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("The app is running from a temporary location (not yet in /Applications)"))
                            .bold()
                        Text(tr("Drag Desktop Pet into the Applications folder before connecting, so the install and hook aren't lost when you eject the DMG or restart your Mac."))
                            .font(.callout)
                    }
                }
            }
        }
    }

    private var claudeCodeCheckStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Checking for Claude Code"))
                .font(.title2).bold()

            if claudeCodeInstalled {
                calloutBox(tone: .green) {
                    Text(tr("Found Claude Code on this Mac. You can move on to the next step."))
                }
            } else {
                Text(String(format: tr("Claude Code wasn't found on this Mac (%@ or the claude command). Claude Code is the command-line tool running in Terminal that Desktop Pet watches — it needs to be installed before connecting."), HomeDirCaption.claudeDir))
                    .fixedSize(horizontal: false, vertical: true)

                Link(tr("Claude Code install guide (claude.com/claude-code)"),
                     destination: URL(string: "https://claude.com/claude-code")!)

                Button(tr("Check again")) { refreshChecks() }
            }
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Connect Claude Code"))
                .font(.title2).bold()
            Text(tr("Press the button below to install the hook into ~/.claude/settings.json. This only adds a few hook entries — it doesn't touch any of your other settings."))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(delegate.isConnected ? tr("Connected") : tr("Connect Claude Code")) {
                    delegate.connectClaudeCode()
                    delegate.testHookConnection()
                }
                .disabled(delegate.isConnected && delegate.diagnosticTestResult?.success == true)
                .keyboardShortcut(.defaultAction)

                if delegate.diagnosticTestRunning {
                    ProgressView().controlSize(.small)
                    Text(tr("Testing connection…")).foregroundStyle(.secondary)
                }
            }

            if let result = delegate.diagnosticTestResult {
                calloutBox(tone: result.success ? .green : .orange) {
                    Text(result.message)
                }
            } else if delegate.isConnected {
                calloutBox(tone: .green) {
                    Text(tr("The hook is installed. Press \"Connect Claude Code\" again for the pet to confirm it, or move on to the next step."))
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Done! Now let's see the pet react"))
                .font(.title2).bold()
            Text(tr("Open Terminal (or your IDE's integrated one), run \"claude\" to start a session, then type any command, for example:"))
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("list the files in the current directory"))
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(tr("The dog on screen will change expression when Claude Code starts thinking, runs a tool, or needs you to approve a permission. If you still don't see anything after a few minutes, open Settings → the \"Diagnostics\" tab to check."))
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
            Button(tr("Done")) { finish() }
                .buttonStyle(.borderedProminent)
        } else {
            Button(tr("Continue")) { advance() }
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
