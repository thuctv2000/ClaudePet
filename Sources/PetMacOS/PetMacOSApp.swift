import AppKit
import Sparkle
import SwiftUI

@main
struct PetMacOSApp: App {
    @NSApplicationDelegateAdaptor(PetAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Desktop Pet", systemImage: "pawprint.fill") {
            Group {
                Button(appDelegate.isVisible ? tr("Hide pet") : tr("Show pet")) {
                    appDelegate.togglePet()
                }

                Toggle(tr("Click-through"), isOn: Binding(
                    get: { appDelegate.isClickThrough },
                    set: { appDelegate.setClickThrough($0) }
                ))

                Divider()

                if appDelegate.isConnected {
                    Button(tr("Disconnect Claude Code")) {
                        appDelegate.disconnectClaudeCode()
                    }
                } else {
                    Button(tr("Connect Claude Code")) {
                        appDelegate.connectClaudeCode()
                    }
                }

                Divider()

                Button(tr("Open sprites folder")) {
                    appDelegate.openSpritesFolder()
                }
                Button(tr("Reload sprites")) {
                    appDelegate.reloadSprites()
                }

                Divider()

                Button(tr("Settings…")) {
                    appDelegate.openSettingsWindow()
                }

                Divider()

                Button("Quit Desktop Pet") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .onAppear { appDelegate.refreshConnectionStatus() }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
@Observable
final class PetAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PetPanel?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private(set) var isVisible = false
    private(set) var isClickThrough = false

    /// Whether our hooks are currently present in `~/.claude/settings.json`.
    /// Stored (not computed) so changes are observable by SwiftUI; refreshed
    /// on connect/disconnect and whenever the menu or settings window opens.
    private(set) var isConnected = HookInstaller.isInstalled

    /// Port the loopback hook server is listening on, once known. `nil` until
    /// the listener reports ready.
    private(set) var serverPort: Int?

    let petState = PetState()
    let sprites = SpriteLibrary()
    let petStore = PetStore()
    let settings = SettingsStore()
    let usage = UsageMonitor()
    /// Sparkle auto-updater (feed + EdDSA key in Info.plist). nil under
    /// `swift run`: a bare executable has no bundle to update, and Sparkle
    /// would otherwise assert on the missing Info.plist keys.
    let updaterController: SPUStandardUpdaterController? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
    private let focusMonitor = SessionFocusMonitor()
    private var hookServer: HookServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Order matters: migrating the legacy sprites folder into the first
        // pet decides what `SpriteLibrary.root` resolves to below.
        petStore.migrateLegacyIfNeeded()
        petStore.reload()
        SpriteLibrary.ensureScaffold()
        sprites.reload()
        petState.recoverInFlightSubagents()
        showPet()
        // Decide (and persist) the onboarding flag *before* starting the hook
        // server: its onReady callback rewrites config.json with a fresh
        // port/token off the network queue, racing this decision if it ran
        // second — reading the flag back out from a half-written file.
        let needsOnboarding = Self.shouldShowOnboarding()
        startHookServer()
        usage.start()
        // Auto-retire a done card once the user opens that conversation in
        // the Claude Code desktop app.
        focusMonitor.onFocus = { [petState] sessionId, date in
            petState.markConversationViewed(sessionId: sessionId, at: date)
        }
        focusMonitor.start()
        startConnectionSelfHealing()
        if needsOnboarding {
            openOnboardingWindow()
        }
    }

    /// First-run detection: only show the wizard when hooks aren't installed
    /// *and* the onboarding flag hasn't been set yet. A machine that already
    /// had hooks installed before this feature shipped (or any already-
    /// connected machine) is treated as onboarded without ever popping the
    /// window, so existing users aren't interrupted.
    private static func shouldShowOnboarding() -> Bool {
        if PetConfig.readOnboardingCompleted() { return false }
        if HookInstaller.isInstalled {
            PetConfig.markOnboardingCompleted()
            return false
        }
        return true
    }

    /// Re-reads hook installation state from disk. Call before showing any UI
    /// that displays the connection status.
    func refreshConnectionStatus() {
        isConnected = HookInstaller.isInstalled
    }

    /// Relaunches the app (used to apply a language change). A bare `swift
    /// run` binary has no bundle to reopen — it just quits.
    func relaunchApp() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func reloadSprites() {
        sprites.reload()
        let count = sprites.clips.count
        petState.notify(count > 0
            ? String(format: tr("Loaded %d animations"), count)
            : tr("No pet yet — add one in Settings → Pet"))
    }

    func openSpritesFolder() {
        SpriteLibrary.ensureScaffold()
        NSWorkspace.shared.open(SpriteLibrary.root)
    }

    private func startHookServer() {
        let token = PetConfig.makeToken()
        let server = HookServer(petState: petState, token: token)
        hookServer = server
        petState.resolver = server
        petState.onInteractiveNeeded = { [weak self] needed in
            guard let self, let panel = self.panel else { return }
            if needed {
                // A dialog needs real clicks/typing: accept mouse events and take
                // key focus so SwiftUI buttons and the text field respond.
                panel.ignoresMouseEvents = false
                self.isVisible = true
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.ignoresMouseEvents = self.isClickThrough
                panel.orderFrontRegardless()
                // Hand active status back to whatever the user was using.
                NSApp.deactivate()
            }
        }
        petState.onMousePassthroughNeeded = { [weak self] needed in
            guard let self, let panel = self.panel else { return }
            // Accept clicks (so the user can close a notice) without stealing
            // focus; fall back to the user's click-through preference otherwise.
            panel.ignoresMouseEvents = needed ? false : self.isClickThrough
        }
        do {
            try server.start { [weak self] port in
                // Called on the network queue; persist the handshake file.
                let onboardingCompleted = PetConfig.readOnboardingCompleted()
                try? PetConfig(port: port, token: token, onboardingCompleted: onboardingCompleted).write()
                Task { @MainActor in self?.serverPort = Int(port) }
            }
        } catch {
            NSLog("PetMacOS: failed to start hook server: \(error)")
            petState.recordError(String(format: tr("Could not start the internal server: %@"), error.localizedDescription))
        }
    }

    // MARK: - Claude Code connection

    func connectClaudeCode() {
        do {
            try HookInstaller.install()
            petState.notify(tr("Connected Claude Code"), mood: .talking)
        } catch {
            let message = String(format: tr("Connection error: %@"), error.localizedDescription)
            petState.notify(message)
            petState.recordError(message)
        }
        refreshConnectionStatus()
    }

    func disconnectClaudeCode() {
        try? HookInstaller.uninstall()
        petState.notify(tr("Disconnected Claude Code"))
        refreshConnectionStatus()
    }

    // MARK: - Connection self-healing

    /// There is no diagnostics UI: the app watches its own connection and
    /// repairs it. Every few minutes, if hooks are installed but no event has
    /// arrived for a long while, it silently re-installs the hook script
    /// (idempotent) and runs the real end-to-end test below. Only when even
    /// that fails does the user hear about it — as one plain pet card, not a
    /// wall of ports and log paths.
    private var healTimer: Timer?
    private var lastHealAttemptAt: Date?
    private static let healCheckInterval: TimeInterval = 180
    private static let healRetryMinInterval: TimeInterval = 1800

    private func startConnectionSelfHealing() {
        guard healTimer == nil else { return }
        let timer = Timer(timeInterval: Self.healCheckInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.selfHealTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healTimer = timer
    }

    private func selfHealTick() {
        guard isConnected, serverPort != nil, !diagnosticTestRunning,
              petState.isConnectionStale(hooksInstalled: true) else { return }
        // Staleness usually just means the user isn't talking to Claude; the
        // test settles it. Don't hammer: at most one attempt per half hour.
        if let last = lastHealAttemptAt,
           Date().timeIntervalSince(last) < Self.healRetryMinInterval { return }
        lastHealAttemptAt = Date()
        try? HookInstaller.install()   // silent refresh of script + entries
        refreshConnectionStatus()
        testHookConnection()
        // The test flips diagnosticTestResult when its round-trip finishes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let result = self.diagnosticTestResult,
                  !result.success, result.at >= self.lastHealAttemptAt! else { return }
            self.petState.notify(
                tr("Pet isn't receiving signals from Claude Code — try restarting the app, or press Connect in Settings"))
        }
    }

    /// Result of the last hook connectivity test (also used by self-healing).
    struct DiagnosticTestResult {
        let success: Bool
        let message: String
        let at: Date
    }

    private(set) var diagnosticTestRunning = false
    private(set) var diagnosticTestResult: DiagnosticTestResult?

    /// Runs a real end-to-end connectivity test: executes the *installed*
    /// `pet-hook.sh` (not a direct HTTP call) with a synthetic event payload
    /// on stdin, exactly the way Claude Code itself invokes it, then checks
    /// whether `PetState` actually observed the event. This exercises the
    /// whole real path (script → curl → loopback server → decode → state),
    /// which is the only way to catch a script/server mismatch.
    func testHookConnection() {
        guard !diagnosticTestRunning else { return }
        guard FileManager.default.fileExists(atPath: HookInstaller.scriptURL.path) else {
            diagnosticTestResult = DiagnosticTestResult(
                success: false, message: tr("pet-hook.sh isn't installed yet — press \"Reinstall hook\" first."), at: Date())
            return
        }
        diagnosticTestRunning = true
        diagnosticTestResult = nil
        let scriptPath = HookInstaller.scriptURL.path
        let diagnosticMessage = tr("Testing pet-hook.sh connection")
        let payload = Data("""
        {"hook_event_name":"PetDiagnostic","session_id":"diagnostic","message":"\(diagnosticMessage)"}
        """.utf8)
        let start = Date()
        let petState = petState

        Task.detached {
            var launchError: String?
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptPath, "event"]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                stdin.fileHandleForWriting.write(payload)
                try stdin.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {
                launchError = error.localizedDescription
            }

            // Give the loopback round-trip (script → curl → server → state)
            // a brief moment to land before checking.
            try? await Task.sleep(for: .milliseconds(500))

            await MainActor.run {
                self.diagnosticTestRunning = false
                if let launchError {
                    let message = String(format: tr("Could not run pet-hook.sh: %@"), launchError)
                    self.diagnosticTestResult = DiagnosticTestResult(success: false, message: message, at: Date())
                    petState.recordError(message)
                    return
                }
                if let lastEventAt = petState.lastEventAt, lastEventAt >= start {
                    self.diagnosticTestResult = DiagnosticTestResult(
                        success: true, message: tr("Success — the pet received the event via pet-hook.sh."), at: Date())
                } else {
                    let message = tr("The script ran, but the pet didn't receive the event (check that hooks are installed, the server is running, or events.log).")
                    self.diagnosticTestResult = DiagnosticTestResult(success: false, message: message, at: Date())
                    petState.recordError(message)
                }
            }
        }
    }

    func togglePet() {
        isVisible ? hidePet() : showPet()
    }

    /// Explicit show/hide used by the settings window's toggle.
    func setPetVisible(_ visible: Bool) {
        visible ? showPet() : hidePet()
    }

    func setClickThrough(_ enabled: Bool) {
        isClickThrough = enabled
        panel?.ignoresMouseEvents = enabled
    }

    private func showPet() {
        if panel == nil {
            // Taller than wide so the speech bubble / dialog has room above the dog.
            let contentSize = NSSize(width: 320, height: 500)
            let frame = NSRect(
                x: (NSScreen.main?.visibleFrame.maxX ?? 900) - contentSize.width - 32,
                y: (NSScreen.main?.visibleFrame.minY ?? 32) + 32,
                width: contentSize.width,
                height: contentSize.height
            )
            let newPanel = PetPanel(contentRect: frame)
            newPanel.contentView = NSHostingView(
                rootView: PetView(state: petState, sprites: sprites, settings: settings, usage: usage))
            panel = newPanel
        }

        panel?.ignoresMouseEvents = isClickThrough
        panel?.orderFrontRegardless()
        isVisible = true
    }

    private func hidePet() {
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Settings window

    /// Opens (or fronts) the real settings window. The app is an accessory, so
    /// we activate explicitly; the window is kept around and reused.
    func openSettingsWindow() {
        refreshConnectionStatus()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = tr("Desktop Pet Settings")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsWindowView(
                    delegate: self, state: petState, sprites: sprites, settings: settings,
                    usage: usage))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Onboarding window

    /// Opens (or fronts) the first-run onboarding wizard. Called automatically
    /// on a fresh install, and reachable again from Settings via "Mở lại
    /// hướng dẫn" so a user who skipped it can come back later.
    func openOnboardingWindow() {
        refreshConnectionStatus()
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = tr("Connect Claude Code")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: OnboardingWindowView(delegate: self) { [weak self] in
                    self?.onboardingWindow?.close()
                })
            window.center()
            // Closing via the titlebar button (not just "Xong"/"Bỏ qua") still
            // counts as "seen" — otherwise a user who dismisses the window
            // with the X gets nagged again on every subsequent launch.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                PetConfig.markOnboardingCompleted()
            }
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

final class PetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Only grab key focus when a control (dialog button / text field) needs
        // it, so idle clicks and drags don't steal focus from other apps.
        becomesKeyOnlyIfNeeded = true
    }

    // Must be able to become key, otherwise SwiftUI buttons / text fields in the
    // permission dialog don't receive clicks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
