import AppKit
import Sparkle
import SwiftUI

@main
struct PetMacOSApp: App {
    @NSApplicationDelegateAdaptor(PetAppDelegate.self) private var appDelegate

    var body: some Scene {
        // `.window` style, not `.menu`: clicking the icon opens a real panel
        // showing what the pet knows (live conversations, usage, the pending
        // permission) instead of a list of verbs. See `MenuBarPopoverView`.
        MenuBarExtra {
            MenuBarPopoverView(
                delegate: appDelegate,
                state: appDelegate.petState,
                usage: appDelegate.usage
            )
        } label: {
            // Redrawn whenever the counts change: paw alone when quiet, paw +
            // count while work is live, all orange when a permission is
            // blocking Claude.
            Image(nsImage: MenuBarIcon.image(
                count: appDelegate.menuBarCount,
                waiting: appDelegate.isWaitingOnUser
            ))
        }
        .menuBarExtraStyle(.window)
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
        // Bundled Dino pet: always present (re-provisioned from bundled GIFs if
        // its folder is missing), on both fresh installs and updates. On a
        // fresh install — the only time no pet is active — it becomes active so
        // the app opens with a real pet instead of the paw placeholder.
        petStore.provisionBuiltinIfNeeded()
        if petStore.activeID == nil { petStore.setActive(PetStore.builtinID) }
        SpriteLibrary.ensureScaffold()
        sprites.reload()
        petState.recoverInFlightSubagents()
        // Off the main thread: it walks a few directories and copies two small
        // files, and nothing on screen waits for the result.
        let state = petState
        DispatchQueue.global(qos: .utility).async {
            let summary = VSCodeExtensionInstaller.installIfNeeded()
            Task { @MainActor in state.recordNote(summary) }
        }
        showPet()
        // Decide (and persist) the onboarding flag *before* starting the hook
        // server: its onReady callback rewrites config.json with a fresh
        // port/token off the network queue, racing this decision if it ran
        // second — reading the flag back out from a half-written file.
        let needsOnboarding = Self.shouldShowOnboarding()
        // Post-update migration: the user already chose to be connected, so a
        // newer app silently rewrites the hook script/entries when they no
        // longer match what this version installs. One click on "update" and
        // everything — including new hook events — just works.
        if HookInstaller.isInstalled, !HookInstaller.isCurrent {
            try? HookInstaller.install()
            refreshConnectionStatus()
        }
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

    /// The number the menu bar icon shows next to the paw. A pending permission
    /// wins over everything — Claude is literally blocked on the user — and is
    /// what turns the icon orange; otherwise it counts the conversations that
    /// are actually doing work, so an idle terminal never inflates it.
    var menuBarCount: Int {
        if petState.pendingAskCount > 0 { return petState.pendingAskCount }
        if petState.waitingSessionCount > 0 { return petState.waitingSessionCount }
        return petState.orderedSessionSummaries.filter { summary in
            switch summary.mood {
            case .working, .thinking: return true
            default: return !summary.subagents.isEmpty || !summary.backgrounds.isEmpty
            }
        }.count
    }

    /// Whether anything is blocked on the user: a permission dialog, or a
    /// conversation whose turn ended in a question. Turns the menu bar icon
    /// orange.
    var isWaitingOnUser: Bool {
        petState.pendingAskCount > 0 || petState.waitingSessionCount > 0
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
                // A dialog needs key focus (so its buttons / text field respond)
                // but must NOT make the whole window catch clicks: the empty area
                // above the dialog has to keep passing clicks through to whatever
                // is behind. Content tracking already makes the dialog itself
                // live once the cursor is over it; just re-evaluate now in case it
                // popped up under a stationary cursor.
                self.isVisible = true
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.reevaluateSoon()
            } else {
                // Never re-show a pet the user has hidden. This branch runs
                // when a dialog is dismissed; ordering the panel front here used
                // to resurrect a hidden pet after any permission/question cycle.
                if self.isVisible { panel.orderFrontRegardless() }
                // Hand active status back to whatever the user was using.
                NSApp.deactivate()
                panel.reevaluateSoon()
            }
        }
        petState.isPetHidden = { [weak self] in !(self?.isVisible ?? true) }
        petState.onDebugHitmap = { [weak self] path in
            guard let panel = self?.panel else { return "no pet window" }
            return panel.dumpHitmap(to: path)
        }
        petState.onMousePassthroughNeeded = { [weak self] _ in
            // A notice / card carries its own hittable ✕, so cursor tracking
            // already makes it clickable. Just recompute in case it appeared
            // under a stationary cursor (no mouse-move to trigger tracking).
            self?.panel?.reevaluateCursor()
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

    /// Clean uninstall: removes the pet's hook entries from
    /// `~/.claude/settings.json` (marker-scoped; a rolling backup is written
    /// first — see `HookInstaller.saveSettings`), optionally trashes
    /// `~/.petmacos` (pets + config) and the app's preferences, then reveals
    /// the app bundle in Finder and quits so the user can drag it to the Trash.
    func cleanUninstall(deleteData: Bool) {
        try? HookInstaller.uninstall()
        refreshConnectionStatus()
        if deleteData {
            UserDefaults.standard.removePersistentDomain(
                forName: Bundle.main.bundleIdentifier ?? "com.desktoppet.PetMacOS")
            try? FileManager.default.trashItem(at: PetConfig.directory, resultingItemURL: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
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
        panel?.clickThrough = enabled
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
            newPanel.contentView = FirstMouseHostingView(
                rootView: PetView(
                    state: petState, sprites: sprites, settings: settings, usage: usage,
                    petStore: petStore,
                    onSwitchPet: { [weak self] id in
                        self?.petStore.setActive(id)
                        SpriteLibrary.ensureScaffold()
                        self?.reloadSprites()
                    },
                    onOpenSettings: { [weak self] in self?.openSettingsWindow() },
                    onHidePet: { [weak self] in self?.setPetVisible(false) },
                    onContentFrameChange: { [weak self] rect in
                        self?.panel?.setContentFrame(rect)
                    },
                    onDragTick: { [weak self] in self?.panel?.dragTick() },
                    onDragEnd: { [weak self] in self?.panel?.endDrag() }
                ))
            panel = newPanel
        }

        panel?.clickThrough = isClickThrough
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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            // Product name, not a sentence — matches the About tab and the
            // menu bar panel header, which both say "ClaudePet".
            window.title = "ClaudePet"
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

/// Hosting view that acts on the very first click.
///
/// AppKit swallows the click that brings a window forward — `acceptsFirstMouse`
/// is false by default — so the pet's cards needed one click to wake the panel
/// and a second to actually press anything. On a floating companion window that
/// reads as "the card is dead": you click a ✕, nothing happens, you click again.
/// The pet has no reason to hoard that first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The floating pet window. It's a fixed 320x500 panel, but most of that is
/// empty space above the pet. To avoid acting as a big invisible click-blocker
/// over the desktop, it tracks the cursor and only accepts mouse events while
/// the pointer is over real content (the pet, a card, a dialog, the badge);
/// everywhere else it passes clicks straight through to whatever is behind.
final class PetPanel: NSPanel {
    /// User's "click-through" preference. When on, the window ignores mouse
    /// events everywhere — even over the pet.
    var clickThrough = false { didSet { refreshIgnoreState() } }

    // nonisolated(unsafe): the array is only mutated on the main actor, but the
    // Swift 6 nonisolated deinit needs to read it to tear the monitors down —
    // safe because deinit runs only when no other reference remains.
    nonisolated(unsafe) private var monitors: [Any] = []
    private var cursorOverContent = false
    /// The pet's real content box in the hosting view's global space (top-left
    /// origin), reported by PetView. Empty until the first layout pass.
    private var contentFrame: CGRect = .zero
    /// Cached snapshot of the content view, sampled for per-pixel alpha in
    /// `pointIsOverContent`. Refreshed lazily (see `contentAlpha`).
    private var contentBitmap: NSBitmapImageRep?
    private var bitmapAt = Date.distantPast

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
        // Dragging is wired to the pet sprite itself (PetView), not to any
        // background: with this on, a click that slipped by a millimetre on a
        // card dragged the whole window instead of pressing what was under the
        // cursor — and during that drag the card stopped responding at all.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Only grab key focus when a control (dialog button / text field) needs
        // it, so idle clicks and drags don't steal focus from other apps.
        becomesKeyOnlyIfNeeded = true
        // Start transparent to clicks; tracking turns it on over the pet.
        ignoresMouseEvents = true
        installCursorTracking()
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        cursorTimer?.invalidate()
    }

    // MARK: - Cursor tracking

    /// Watches the pointer with both a local monitor (fires while our window is
    /// live over content) and a global one (fires while the window is passing
    /// events through to other apps). Together they cover the hand-off in both
    /// directions as the cursor enters and leaves the pet. `mouseMoved` doesn't
    /// need Accessibility permission (only keyboard taps do).
    /// Ticks the cursor check even when no `mouseMoved` arrives.
    ///
    /// The monitors alone lose the race that matters: move onto a card and
    /// click in one motion and the click can arrive before the last move has
    /// been delivered, so the window is still passing events through and the
    /// click lands on whatever is behind. That is the "have to click twice"
    /// everyone hits. macOS also coalesces moves and drops them entirely during
    /// other apps' drag loops. 30Hz against a cached bitmap costs nothing and
    /// closes the hole to a frame.
    // Same reason as `monitors`: deinit is nonisolated and has to tear it down.
    nonisolated(unsafe) private var cursorTimer: Timer?

    private func startCursorPolling() {
        guard cursorTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackCursor() }
        }
        // .common so it keeps running while a menu or a drag loop is up.
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func installCursorTracking() {
        startCursorPolling()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.trackCursor()
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.trackCursor()
        }
        monitors = [local, global].compactMap { $0 }
    }

    /// Updates the clickable region (called by PetView as content grows/shrinks)
    /// and re-checks the cursor against it right away, so a card appearing under
    /// a still cursor becomes live without waiting for a mouse move.
    func setContentFrame(_ rect: CGRect) {
        contentFrame = rect
        contentBitmap = nil        // structure changed — force a fresh snapshot
        lastEvaluatedPoint = nil   // ...and a fresh verdict, even if the cursor sits still
        trackCursor()
    }

    /// Recomputes whether the cursor is over real content and updates the
    /// ignore state. Public so the app can nudge it when content appears under
    /// a stationary cursor.
    func reevaluateCursor() { trackCursor() }

    /// Where the last verdict was taken, and how many times in a row the answer
    /// has come back "not on content" since. See `trackCursor`.
    private var lastEvaluatedPoint: NSPoint?
    private var consecutiveMisses = 0
    /// A single empty snapshot must not be enough to switch the window off.
    private static let missesBeforeReleasing = 3

    private func trackCursor() {
        // Never flip mid-drag: it would abort a drag of the pet halfway.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let point = NSEvent.mouseLocation
        // Standing still on something clickable: leave it alone. Re-testing the
        // very same pixel can only change the answer if the *snapshot* changed,
        // and that is exactly the failure this guards against — a refresh that
        // renders empty turns the window off under a motionless pointer, and
        // the next click sails through to whatever is behind. Measured: the
        // same point on the same card alternated between "solid" and
        // "transparent" as snapshots were retaken.
        if let last = lastEvaluatedPoint, last == point, cursorOverContent { return }
        lastEvaluatedPoint = point

        let over = pointIsOverContent(point)
        if over {
            consecutiveMisses = 0
        } else if cursorOverContent {
            // Let go only after several agreeing readings, so one bad snapshot
            // costs nothing.
            consecutiveMisses += 1
            guard consecutiveMisses >= Self.missesBeforeReleasing else { return }
            consecutiveMisses = 0
        }
        guard over != cursorOverContent else { return }
        cursorOverContent = over
        refreshIgnoreState()
    }

    /// True when the cursor sits on an actually-drawn (non-transparent) pixel of
    /// the pet UI. A plain rectangle isn't enough: the pet sprite is a wide art
    /// centered in a square frame, so its bounding box has transparent bands
    /// above and below the visible body — and with `isMovableByWindowBackground`
    /// those bands would still drag the window. So test the real alpha: first a
    /// cheap reject against the reported content box, then the rendered pixel.
    /// (`hitTest` can't help — NSHostingView returns itself for every in-bounds
    /// point, transparent or not.)
    private func pointIsOverContent(_ screenPoint: NSPoint) -> Bool {
        guard let content = contentView, isVisible, !contentFrame.isEmpty else { return false }
        let windowPoint = convertPoint(fromScreen: screenPoint)   // bottom-left origin
        let flipped = CGPoint(x: windowPoint.x, y: content.bounds.height - windowPoint.y)
        guard contentFrame.insetBy(dx: -Self.approachMargin, dy: -Self.approachMargin)
            .contains(flipped) else { return false }
        if contentAlpha(atTopLeft: flipped, in: content) > 0.02 { return true }
        // Nothing solid *under* the cursor — but if solid content is within a
        // few points, take the window live anyway.
        //
        // Why: macOS decides which window a click belongs to at the last mouse
        // *move*, not at the click. Turning the window on at the instant the
        // cursor lands on a card is therefore too late — the click that follows
        // still goes to the app behind, and only the second one lands. That is
        // the "the card is hard to press" everyone hits, and it is a race no
        // amount of polling wins. Switching on a few points early means the
        // change happens while the pointer is still moving, so the server sees
        // a move afterwards and routes the click here. The cost is a thin halo
        // around the pet that swallows clicks; the alternative is buttons that
        // work every other time.
        for radius in Self.approachRings {
            for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 4) {
                let probe = CGPoint(x: flipped.x + cos(angle) * radius,
                                    y: flipped.y + sin(angle) * radius)
                guard contentFrame.contains(probe) else { continue }
                if contentAlpha(atTopLeft: probe, in: content) > 0.02 { return true }
            }
        }
        return false
    }

    /// How far outside the drawn content the window still takes clicks.
    private static let approachMargin: CGFloat = 18
    private static let approachRings: [CGFloat] = [9, 18]

    /// Alpha of the content view's rendered pixel at a top-left-origin point.
    /// Uses a short-lived cached snapshot so mouse-move sampling stays cheap; the
    /// pet's silhouette is stable enough between refreshes that a slightly stale
    /// snapshot is fine for hit-testing.
    private func contentAlpha(atTopLeft point: CGPoint, in content: NSView) -> CGFloat {
        if contentBitmap == nil || Date().timeIntervalSince(bitmapAt) > 0.4 {
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            if let rep { content.cacheDisplay(in: content.bounds, to: rep) }
            // Keep the previous snapshot when the new one came back blank.
            //
            // `cacheDisplay` on a hosting view sometimes captures nothing —
            // caught in the act: the same pixel of the same card read "solid",
            // then "transparent", then "solid" again as snapshots were retaken,
            // with the pointer never moving. Every blank read switched the
            // window off, and the click that followed went to the app behind.
            // That is the pet "going dead" for no reason anyone could see.
            if contentBitmap == nil || rep.map(Self.hasDrawnPixels) == true {
                contentBitmap = rep
            }
            bitmapAt = Date()
        }
        guard let rep = contentBitmap else { return 1 }   // can't snapshot → treat as solid
        let sx = CGFloat(rep.pixelsWide) / content.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / content.bounds.height
        let px = Int((point.x * sx).rounded())
        let py = Int((point.y * sy).rounded())
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { return 0 }
        return rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
    }

    /// Whether a snapshot has anything drawn in it at all — a coarse grid is
    /// enough to tell "rendered" from "came back empty".
    private static func hasDrawnPixels(_ rep: NSBitmapImageRep) -> Bool {
        let stepX = max(1, rep.pixelsWide / 40)
        let stepY = max(1, rep.pixelsHigh / 60)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 { return true }
            }
        }
        return false
    }

    private func refreshIgnoreState() {
        let wasIgnoring = ignoresMouseEvents
        if clickThrough { ignoresMouseEvents = true }
        else { ignoresMouseEvents = !cursorOverContent }
        // Turning the window back on is not enough on its own. The window
        // server decides which window a click belongs to at the last mouse
        // *move*, not at the click — so with the pointer already standing on a
        // card, flipping the flag changes nothing for the click that follows:
        // it still goes to the app behind, and only the *second* click lands.
        // That is the "have to click twice / the card feels dead" everyone
        // runs into. Warping the cursor to where it already is costs nothing
        // visually and makes the server redo that decision now.
        if wasIgnoring, !ignoresMouseEvents { renotifyCursorPosition() }
    }

    /// Re-asserts the pointer position so the window server re-runs its
    /// hit test. No permission needed (unlike posting synthetic events) and no
    /// visible movement — the cursor is warped to the pixel it is already on.
    private func renotifyCursorPosition() {
        let point = NSEvent.mouseLocation
        // CGWarp works in display space: origin top-left of the primary screen,
        // y growing downwards.
        guard let primary = NSScreen.screens.first else { return }
        let here = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        // One pixel out and straight back. Warping to the pixel the cursor is
        // already on produces no movement, and no movement means the server has
        // no reason to redo anything — the flag change is only noticed on the
        // next real move, which is exactly the click that gets lost. A pixel is
        // invisible and lands the cursor back where the user put it.
        CGWarpMouseCursorPosition(CGPoint(x: here.x + 1, y: here.y))
        CGWarpMouseCursorPosition(here)
    }

    /// Re-checks the cursor a couple of times over the next moment. Used when a
    /// dialog appears/dismisses: the layout (and so the snapshot) changes a frame
    /// or two later, and the cursor may be sitting still, so a plain immediate
    /// check could sample the old content. Cheap and self-correcting.
    func reevaluateSoon() {
        contentBitmap = nil
        trackCursor()
        for delay in [0.05, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.contentBitmap = nil
                self?.trackCursor()
            }
        }
    }

    /// Moves the window by however far the pointer has travelled since the last
    /// tick. Measured against the screen rather than the gesture's translation:
    /// the window moves out from under the cursor as it is dragged, so a
    /// translation reported in window space cancels itself out and the pet
    /// stops following after the first step.
    private var dragAnchor: NSPoint?

    func dragTick() {
        let now = NSEvent.mouseLocation
        defer { dragAnchor = now }
        guard let anchor = dragAnchor else { return }
        setFrameOrigin(NSPoint(x: frame.origin.x + (now.x - anchor.x),
                               y: frame.origin.y + (now.y - anchor.y)))
    }

    func endDrag() { dragAnchor = nil }

    /// Writes the snapshot the alpha test samples to `path`, and reports what
    /// the test currently believes about the cursor.
    func dumpHitmap(to path: String) -> String {
        guard let content = contentView else { return "no content view" }
        contentBitmap = nil
        let point = NSEvent.mouseLocation
        let over = pointIsOverContent(point)
        let windowPointEarly = convertPoint(fromScreen: point)
        let flippedEarly = CGPoint(x: windowPointEarly.x,
                                   y: content.bounds.height - windowPointEarly.y)
        guard let rep = contentBitmap, let png = rep.representation(using: .png, properties: [:]) else {
            return """
            no snapshot — over=\(over)
            contentFrame=\(contentFrame) contentBounds=\(content.bounds)
            cursor(screen)=\(point) cursor(flipped)=\(flippedEarly)
            insideContentFrame=\(contentFrame.contains(flippedEarly))
            windowFrame=\(frame) isVisible=\(isVisible)
            """
        }
        try? png.write(to: URL(fileURLWithPath: path))
        let windowPoint = convertPoint(fromScreen: point)
        let flipped = CGPoint(x: windowPoint.x, y: content.bounds.height - windowPoint.y)
        let alpha = contentAlpha(atTopLeft: flipped, in: content)
        return """
        wrote \(rep.pixelsWide)x\(rep.pixelsHigh) to \(path)
        contentFrame=\(contentFrame)
        cursor(screen)=\(point) cursor(flipped)=\(flipped)
        insideContentFrame=\(contentFrame.contains(flipped)) alpha=\(alpha) over=\(over)
        ignoresMouseEvents=\(ignoresMouseEvents) clickThrough=\(clickThrough)
        windowFrame=\(frame) contentBounds=\(content.bounds)
        """
    }

    // Must be able to become key, otherwise SwiftUI buttons / text fields in the
    // permission dialog don't receive clicks.
    override var canBecomeKey: Bool { true }

    /// Takes key status the moment the user clicks the pet's own content.
    ///
    /// `becomesKeyOnlyIfNeeded` keeps the panel out of the way — clicking it
    /// normally does not steal focus from the app you are working in — but it
    /// also means the first click on a reply box only *keys the window*, and
    /// the caret needs a second click. Somebody clicking a card has already
    /// decided to interact with it, so hand key status over on that first
    /// click and let the same click do its job.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, cursorOverContent, !clickThrough, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
    override var canBecomeMain: Bool { false }
}
