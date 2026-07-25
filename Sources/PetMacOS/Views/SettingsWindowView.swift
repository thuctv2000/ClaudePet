import SwiftUI

/// The settings window: an icon tab bar over grouped forms.
///
/// The tab bar is drawn by hand rather than using `TabView`. The native macOS
/// tab bar moves the tabs into the window's title area and collapses them
/// behind a "»" overflow menu when it decides the row is too wide — hiding
/// every tab. A row of explicit buttons always lays them all out, and lets each
/// tab carry an icon so the window is scannable at a glance.
struct SettingsWindowView: View {
    var delegate: PetAppDelegate
    var state: PetState
    var sprites: SpriteLibrary
    @Bindable var settings: SettingsStore
    var usage: UsageMonitor

    @State private var importMessage: String?
    /// Name typed into the "add a new pet" field.
    @State private var newPetName = ""
    /// Pet currently being renamed (drives the rename alert) + its draft name.
    @State private var renamingPetID: String?
    @State private var renameText = ""
    @State private var showUninstallDialog = false
    /// Language picker state ("system", "en", "vi") + whether it changed this
    /// session (drives the relaunch prompt).
    @State private var language: String =
        UserDefaults.standard.string(forKey: L10n.overrideKey) ?? "system"
    @State private var languageChanged = false
    /// Ticks periodically so the "last event" relative time and the stale-
    /// connection warning stay fresh while the tab is open (they depend on
    /// `Date()`, which SwiftUI has no other reason to recompute).
    @State private var now = Date()
    /// Currently selected tab.
    @State private var selectedTab: Tab = .general

    /// The settings tabs, in display order. Each carries its own label and SF
    /// Symbol so the strip and the content switch stay in sync.
    private enum Tab: String, CaseIterable, Identifiable {
        case general, pet, permissions, colors, about
        var id: Self { self }

        var label: String {
            switch self {
            case .general: return tr("General")
            case .pet: return tr("Pet")
            case .permissions: return tr("Permissions")
            case .colors: return tr("Colors")
            case .about: return tr("About")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .pet: return "pawprint.fill"
            case .permissions: return "lock.shield.fill"
            case .colors: return "paintpalette.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch selectedTab {
                case .general: generalTab
                case .pet: petTab
                case .permissions: permissionsTab
                case .colors: colorsTab
                case .about: aboutTab
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 560, height: 600)
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { tab in
                TabButton(
                    icon: tab.icon,
                    label: tab.label,
                    selected: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section { connectionCard }
            Section(tr("Pet")) {
                switchRow(tr("Show pet"), isOn: Binding(
                    get: { delegate.isVisible },
                    set: { delegate.setPetVisible($0) }
                ))
                switchRow(tr("Click-through (mouse passes through the pet)"), isOn: Binding(
                    get: { delegate.isClickThrough },
                    set: { delegate.setClickThrough($0) }
                ))
            }
            usageSection
            languageSection
        }
        .formStyle(.grouped)
    }

    /// The one thing this window exists to answer: is the pet actually wired to
    /// Claude Code right now? Big status, the port it listens on, and every
    /// repair action in one place.
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((delegate.isConnected ? Color.green : Color.orange).opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: delegate.isConnected ? "link" : "link.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(delegate.isConnected ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(delegate.isConnected ? tr("Connected to Claude Code") : tr("Not connected"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(delegate.isConnected
                         ? tr("Installed in ~/.claude/settings.json")
                         : tr("Press Connect to install the hooks."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 5) {
                        StatusDot(color: delegate.serverPort != nil ? .green : .red, size: 6)
                        Text(tr("Internal server"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let port = delegate.serverPort {
                        Text(String(format: tr("Listening on port %@"), String(port)))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    } else {
                        Text(tr("Not running"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack(spacing: 8) {
                if delegate.isConnected {
                    Button(tr("Disconnect")) { delegate.disconnectClaudeCode() }
                } else {
                    Button(tr("Connect")) { delegate.connectClaudeCode() }
                        .buttonStyle(.borderedProminent)
                }
                Button(tr("Check again")) { delegate.refreshConnectionStatus() }
                Button(tr("Reopen the guide")) { delegate.openOnboardingWindow() }
                Spacer()
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
    }

    private var usageSection: some View {
        Section {
            HStack(alignment: .top, spacing: 20) {
                UsageBar(title: tr("5-hour window"), window: usage.fiveHour)
                UsageBar(title: tr("Week"), window: usage.sevenDay)
            }
            .padding(.vertical, 4)
            if let error = usage.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button(tr("Refresh")) { Task { await usage.refresh() } }
                if let updated = usage.lastUpdated {
                    Text(String(format: tr("Updated %@"), updated.formatted(date: .omitted, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(tr("Claude usage"))
        }
    }

    /// Language override: follow the system (default) or force EN/VI.
    /// Strings resolve once at launch, so applying a change means relaunching.
    private var languageSection: some View {
        Section(tr("Language")) {
            Picker(tr("App language"), selection: $language) {
                Text(tr("Follow system")).tag("system")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "Tiếng Việt").tag("vi")
            }
            .onChange(of: language) { _, newValue in
                if newValue == "system" {
                    UserDefaults.standard.removeObject(forKey: L10n.overrideKey)
                } else {
                    UserDefaults.standard.set(newValue, forKey: L10n.overrideKey)
                }
                languageChanged = true
            }
            if languageChanged {
                HStack {
                    Text(tr("Takes effect after the app relaunches."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(tr("Relaunch now")) { delegate.relaunchApp() }
                }
            }
        }
    }

    /// A form row whose toggle is our own accent switch — the native one greys
    /// out whenever the window isn't key, which reads as "disabled".
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            AccentSwitch(isOn: isOn)
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.systemAccent)
                    Text(verbatim: "ClaudePet")
                        .font(.title2.bold())
                    Text(tr("A desktop pet that reacts to what Claude Code is doing."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(String(format: tr("Version %@"), appVersion))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            updateSection

            Section(tr("Project")) {
                Link(destination: URL(string: "https://github.com/thuctv2000/ClaudePet")!) {
                    Label("github.com/thuctv2000/ClaudePet", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    delegate.openSpritesFolder()
                } label: {
                    Label(tr("Open sprites folder"), systemImage: "folder")
                }
            }

            uninstallSection
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? tr("dev build")
    }

    /// Clean uninstall entry point. The hook removal is marker-scoped (only
    /// the pet's own entries) and a backup of settings.json is written first,
    /// so the user's other Claude Code configuration can never be harmed.
    private var uninstallSection: some View {
        Section {
            Button(tr("Clean uninstall…"), role: .destructive) {
                showUninstallDialog = true
            }
            .confirmationDialog(
                tr("Remove the pet's hooks from Claude Code and quit?"),
                isPresented: $showUninstallDialog
            ) {
                Button(tr("Remove hooks, keep my pets"), role: .destructive) {
                    delegate.cleanUninstall(deleteData: false)
                }
                Button(tr("Remove hooks and delete all pet data"), role: .destructive) {
                    delegate.cleanUninstall(deleteData: true)
                }
                Button(tr("Cancel"), role: .cancel) {}
            } message: {
                Text(tr("Only the pet's own entries are removed from ~/.claude/settings.json (a backup is saved first) — the rest of your Claude Code settings stay untouched. Deleted data goes to the Trash. The app then shows itself in Finder so you can drag it to the Trash."))
            }
        } header: {
            Text(tr("Uninstall"))
        } footer: {
            Text(tr("Reinstalling later brings everything back if you kept your pets."))
        }
    }

    /// App update via Sparkle: the button opens Sparkle's own update window,
    /// which downloads, verifies (EdDSA), installs and relaunches by itself.
    private var updateSection: some View {
        Section(tr("Updates")) {
            if let controller = delegate.updaterController {
                HStack {
                    Button(tr("Check for updates")) { controller.checkForUpdates(nil) }
                    Text(tr("A new version downloads, installs, and relaunches automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switchRow(tr("Check automatically"), isOn: Binding(
                    get: { controller.updater.automaticallyChecksForUpdates },
                    set: { controller.updater.automaticallyChecksForUpdates = $0 }
                ))
            } else {
                Text(tr("Dev build — auto-update only works in the /Applications install."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pet & sprites

    private var petTab: some View {
        Form {
            petLibrarySection
            addPetSection
            if delegate.petStore.activeID != nil {
                petMoodsSection
            }
        }
        .formStyle(.grouped)
        // Dropping a GIF/images anywhere on the tab creates a pet from them —
        // the fastest possible path from "found a cute GIF" to a living pet.
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter {
                ["png", "gif", "jpg", "jpeg"].contains($0.pathExtension.lowercased())
            }
            guard !images.isEmpty else { return false }
            createPet(from: images)
            return true
        }
    }

    // MARK: Pet library

    /// Every saved pet: one tap to switch, pencil to rename, ✕ to move the
    /// pet's folder to the Trash.
    private var petLibrarySection: some View {
        Section(tr("Your pets")) {
            if delegate.petStore.pets.isEmpty {
                Text(tr("No pets yet — add one below."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(delegate.petStore.pets) { pet in
                petLibraryRow(pet)
            }
        }
        .alert(tr("Rename pet"), isPresented: renameAlertShown) {
            TextField(tr("Pet name"), text: $renameText)
            Button(tr("Rename")) {
                if let id = renamingPetID {
                    delegate.petStore.renamePet(id: id, to: renameText)
                }
                renamingPetID = nil
            }
            Button(tr("Cancel"), role: .cancel) { renamingPetID = nil }
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(
            get: { renamingPetID != nil },
            set: { if !$0 { renamingPetID = nil } }
        )
    }

    private func petLibraryRow(_ pet: PetInfo) -> some View {
        let isActive = delegate.petStore.activeID == pet.id
        return HStack(spacing: 12) {
            Group {
                if let avatar = pet.avatar {
                    Image(nsImage: avatar).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(pet.name)
                    .fontWeight(isActive ? .semibold : .regular)
                Text("\(pet.coverage)/\(SpriteLibrary.states.count) mood")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            activeMark(isActive: isActive) {
                switchPet(to: pet.id)
            }
            Button {
                renameText = pet.name
                renamingPetID = pet.id
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Rename pet"))
            if pet.isBuiltin {
                // The bundled Dino can't be removed — it's the guaranteed
                // fallback pet. Show a lock instead of a delete control.
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(tr("The default pet can't be deleted"))
            } else {
                Button {
                    delegate.petStore.deletePet(id: pet.id)
                    delegate.reloadSprites()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Move this pet to the Trash"))
            }
        }
        .listRowBackground(isActive ? Color.accentColor.opacity(0.08) : nil)
    }

    @ViewBuilder
    private func activeMark(isActive: Bool, action: @escaping () -> Void) -> some View {
        if isActive {
            Text(tr("In use"))
                .font(.caption)
                .bold()
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.green.opacity(0.12)))
        } else {
            Button(tr("Use"), action: action)
        }
    }

    private func switchPet(to id: String?) {
        delegate.petStore.setActive(id)
        SpriteLibrary.ensureScaffold()
        delegate.reloadSprites()
    }

    // MARK: Add a pet

    private var addPetSection: some View {
        Section {
            TextField(tr("Pet name"), text: $newPetName)
            HStack {
                Button(tr("Choose image or GIF…")) { addPet() }
                if let message = importMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(tr("Add a new pet"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("One image or GIF is enough — the pet comes alive right away. A GIF animates as-is, several images become the frames, and a single image gets a gentle idle bob. Fill in the other moods below whenever you like."))
                Text(tr("Tip: you can also drop a GIF or images anywhere on this tab."))
            }
        }
    }

    private func addPet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .jpeg]
        panel.allowsMultipleSelection = true
        panel.message = tr("Choose one GIF or one or more images for your pet")
        panel.prompt = tr("Create")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        createPet(from: panel.urls)
    }

    /// Files → a living pet: create the folder, make it active, import
    /// everything into `idle` (the mood every other mood falls back to).
    /// Unnamed pets fall back to the first file's name — good enough to tell
    /// apart, renameable any time.
    private func createPet(from urls: [URL]) {
        let trimmed = newPetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? (urls.first?.deletingPathExtension().lastPathComponent ?? tr("New pet"))
            : trimmed
        do {
            let id = try delegate.petStore.createPet(named: name)
            delegate.petStore.setActive(id)
            let result = try SpriteImporter.replaceFrames(of: "idle", with: urls)
            delegate.petStore.reload()
            delegate.reloadSprites()
            newPetName = ""
            importMessage = String(format: tr("Created %@ with %d frame(s)."), name, result.frameCount)
        } catch {
            importMessage = String(format: tr("Import error: %@"), error.localizedDescription)
        }
    }

    // MARK: Per-mood animations of the active pet

    private var petMoodsSection: some View {
        Group {
            Section {
                ForEach(SpriteLibrary.states, id: \.self) { stateName in
                    spriteRow(for: stateName)
                }
            } header: {
                Text(tr("Animations of the selected pet"))
            } footer: {
                Text(tr("Press Replace… to pick a transparent PNG sequence or an animated GIF — the app splits it into frames, centers them, and sets the speed automatically."))
            }

            if let message = importMessage {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button(tr("Open sprites folder")) { delegate.openSpritesFolder() }
                    Button(tr("Reload sprites")) { delegate.reloadSprites() }
                }
            }
        }
    }

    private func spriteRow(for stateName: String) -> some View {
        HStack(spacing: 10) {
            // Thumbnail of the first frame, if any.
            Group {
                if let first = sprites.clip(named: stateName)?.frames.first {
                    Image(nsImage: first)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: stateName))
                if let clip = sprites.clip(named: stateName) {
                    Text("\(clip.frames.count) \(tr("frames")), \(trimmed(clip.fps)) fps" + (clip.loops ? ", \(tr("loops"))" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(tr("none yet"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(tr("Replace…")) { importSprites(for: stateName) }
        }
    }

    /// Opens a file picker and replaces the state's frames with the selection.
    private func importSprites(for stateName: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .jpeg]
        panel.allowsMultipleSelection = true
        panel.message = String(format: tr("Choose a transparent PNG sequence or a GIF file for \"%@\""), stateName)
        panel.prompt = tr("Import")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        do {
            let result = try SpriteImporter.replaceFrames(of: stateName, with: panel.urls)
            delegate.reloadSprites()
            delegate.petStore.reload()   // coverage/avatar may have changed
            if let fps = result.gifFPS {
                importMessage = String(format: tr("Imported %d frames for %@ (GIF, %@ fps)."), result.frameCount, stateName, trimmed(fps))
            } else {
                importMessage = String(format: tr("Imported %d frames for %@."), result.frameCount, stateName)
            }
        } catch {
            importMessage = String(format: tr("Import error: %@"), error.localizedDescription)
        }
    }

    private func label(for state: String) -> String {
        switch state {
        case "idle": return "idle — \(tr("when idle"))"
        case "click": return "click — \(tr("tapping the pet"))"
        case "thinking": return "thinking — \(tr("thinking"))"
        case "working": return "working — \(tr("running a tool"))"
        case "talking": return "talking — \(tr("just replied"))"
        case "asking": return "asking — \(tr("asking for permission"))"
        case "sleep": return "sleep — \(tr("session ended"))"
        case "error": return "error — \(tr("a tool just failed"))"
        case "happy": return "happy — \(tr("Claude just finished cleanly"))"
        default: return state
        }
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Permissions

    /// Deliberately has no switches. The pet holds no permission policy of its
    /// own: it shows the dialog exactly when Claude Code would have shown one,
    /// and nothing more. Anything that decides *whether* to ask -- the
    /// permission mode, the allow rules -- belongs to Claude Code, and keeping a
    /// second copy here is what used to let the two drift apart.
    private var permissionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                infoRow(
                    icon: "hand.raised.fill",
                    tint: .orange,
                    title: tr("The pet asks only when Claude Code would"),
                    body: tr("The pet shows a dialog exactly when Claude Code would have asked you, and nothing more. Press Allow or Deny on the pet and you're done — the terminal won't ask again.")
                )
                infoRow(
                    icon: "slider.horizontal.3",
                    tint: .blue,
                    title: tr("Tune it inside Claude Code"),
                    body: tr("Want more or fewer prompts? Change the permission mode inside Claude Code itself (Shift+Tab, or the --permission-mode flag). The pet follows automatically.")
                )
                infoRow(
                    icon: "checkmark.shield.fill",
                    tint: .green,
                    title: tr("Nothing ever gets stuck"),
                    body: tr("If the pet is off or busy, Claude Code asks in the terminal as usual — nothing gets stuck.")
                )
            }
            .padding(20)
        }
    }

    private func infoRow(icon: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .petCard()
    }

    // MARK: - Colors

    private var colorsTab: some View {
        Form {
            Section { colorPreviewCard } header: {
                Text(tr("Preview"))
            }
            Section(tr("Card colors")) {
                colorRow(tr("Running tool"), $settings.tool)
                colorRow(tr("Attention"), $settings.notification)
            }
            Section(tr("Completed-task gradient")) {
                colorRow(tr("Color 1"), $settings.gradient1)
                colorRow(tr("Color 2"), $settings.gradient2)
                colorRow(tr("Color 3"), $settings.gradient3)
            }
            Section {
                Button(tr("Restore defaults")) { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    /// The three card looks, drawn exactly as the pet draws them — so the
    /// pickers below are judged against the real thing, not a swatch.
    private var colorPreviewCard: some View {
        HStack(spacing: 10) {
            previewCard(tr("Running tool"), AnyShapeStyle(settings.tool))
            previewCard(tr("Attention"), AnyShapeStyle(settings.notification))
            previewCard(tr("Done"), AnyShapeStyle(settings.completedGradient))
        }
        .padding(.vertical, 4)
    }

    private func previewCard(_ title: String, _ style: AnyShapeStyle) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(style, lineWidth: 2)
            )
    }

    private func colorRow(_ title: String, _ color: Binding<Color>) -> some View {
        HStack {
            ColorPicker(title, selection: color, supportsOpacity: true)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(color.wrappedValue, lineWidth: 3)
                .frame(width: 60, height: 22)
        }
    }
}

// MARK: - Tab bar button

/// One tab: icon over label, accent-tinted while selected.
private struct TabButton: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 11))
            }
            .frame(width: 84, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected
                          ? Color.systemAccent.opacity(0.18)
                          : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.systemAccent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .foregroundStyle(selected ? Color.systemAccent : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
