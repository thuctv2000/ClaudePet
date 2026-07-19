import SwiftUI

/// The real settings window: status, pet & sprites, permissions, colours.
/// Text-only UI (no icons), Vietnamese labels.
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
    /// Language picker state ("system", "en", "vi") + whether it changed this
    /// session (drives the relaunch prompt).
    @State private var language: String =
        UserDefaults.standard.string(forKey: L10n.overrideKey) ?? "system"
    @State private var languageChanged = false
    /// Ticks periodically so the "last event" relative time and the stale-
    /// connection warning stay fresh while the tab is open (they depend on
    /// `Date()`, which SwiftUI has no other reason to recompute).
    @State private var now = Date()
    /// Currently selected tab. Drives our custom top strip instead of a native
    /// `TabView`, so the tabs can never collapse into the macOS overflow menu.
    @State private var selectedTab: Tab = .status

    /// The settings tabs, in display order. Each carries its Vietnamese label so
    /// the strip and the content switch stay in sync.
    private enum Tab: String, CaseIterable, Identifiable {
        case status, pet, permissions, colors
        var id: Self { self }
        var label: String {
            switch self {
            case .status: return tr("Status")
            case .pet: return tr("Pet")
            case .permissions: return tr("Permissions")
            case .colors: return tr("Colors")
            }
        }
    }

    var body: some View {
        // A custom top tab strip (a segmented picker) rather than `TabView`.
        // The native macOS tab bar moves the tabs into the window's title area
        // and collapses them behind a "»" overflow menu when it decides the row
        // is too wide, hiding every tab. A segmented control always lays all the
        // tabs out in one row regardless of width or macOS version.
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Only the selected tab's content is shown.
            switch selectedTab {
            case .status: statusTab
            case .pet: petTab
            case .permissions: permissionsTab
            case .colors: colorsTab
            }
        }
        .frame(width: 480, height: 540)
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Trạng thái

    private var statusTab: some View {
        Form {
            Section(tr("Pet")) {
                Toggle(tr("Show pet"), isOn: Binding(
                    get: { delegate.isVisible },
                    set: { delegate.setPetVisible($0) }
                ))
                Toggle(tr("Click-through (mouse passes through the pet)"), isOn: Binding(
                    get: { delegate.isClickThrough },
                    set: { delegate.setClickThrough($0) }
                ))
            }

            Section(tr("Claude Code connection")) {
                LabeledContent("Hooks") {
                    Text(delegate.isConnected ? tr("Installed in ~/.claude/settings.json") : tr("Not connected"))
                        .foregroundStyle(delegate.isConnected ? .green : .secondary)
                }
                LabeledContent(tr("Internal server")) {
                    if let port = delegate.serverPort {
                        Text(String(format: tr("Listening on port %@"), String(port)))
                            .foregroundStyle(.green)
                    } else {
                        Text(tr("Not running"))
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    if delegate.isConnected {
                        Button(tr("Disconnect")) { delegate.disconnectClaudeCode() }
                    } else {
                        Button(tr("Connect")) { delegate.connectClaudeCode() }
                    }
                    Button(tr("Check again")) { delegate.refreshConnectionStatus() }
                    Button(tr("Reopen the guide")) { delegate.openOnboardingWindow() }
                }
            }

            Section(tr("Claude usage")) {
                usageRow(tr("5-hour window"), usage.fiveHour)
                usageRow(tr("Week"), usage.sevenDay)
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
            }

            languageSection
            updateSection
        }
        .formStyle(.grouped)
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

    /// App update via Sparkle: the button opens Sparkle's own update window,
    /// which downloads, verifies (EdDSA), installs and relaunches by itself.
    private var updateSection: some View {
        Section(tr("Version")) {
            LabeledContent(tr("Current")) {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? tr("dev build"))
                    .foregroundStyle(.secondary)
            }
            if let controller = delegate.updaterController {
                HStack {
                    Button(tr("Check for updates")) { controller.checkForUpdates(nil) }
                    Text(tr("A new version downloads, installs, and relaunches automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(tr("Check automatically"), isOn: Binding(
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

    @ViewBuilder
    private func usageRow(_ title: String, _ window: UsageMonitor.Window?) -> some View {
        LabeledContent(title) {
            if let window {
                HStack(spacing: 6) {
                    Text("\(Int(window.utilization.rounded()))%").bold().monospacedDigit()
                    if let resets = window.resetsAt {
                        Text(String(format: tr("reset %@"), resets.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(tr("no data yet")).foregroundStyle(.tertiary)
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
        HStack(spacing: 10) {
            Group {
                if let avatar = pet.avatar {
                    Image(nsImage: avatar).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(pet.name)
                Text("\(pet.coverage)/\(SpriteLibrary.states.count) mood")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            activeMark(isActive: delegate.petStore.activeID == pet.id) {
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
            Button {
                delegate.petStore.deletePet(id: pet.id)
                delegate.reloadSprites()
            } label: {
                Text("✕").font(.caption).bold().foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Move this pet to the Trash"))
        }
    }

    @ViewBuilder
    private func activeMark(isActive: Bool, action: @escaping () -> Void) -> some View {
        if isActive {
            Text(tr("In use"))
                .font(.caption)
                .foregroundStyle(.green)
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
            Text(tr("One image or GIF is enough — the pet comes alive right away. A GIF animates as-is, several images become the frames, and a single image gets a gentle idle bob. Fill in the other moods below whenever you like."))
        }
    }

    /// Name + files → a living pet: create the folder, make it active, import
    /// everything into `idle` (the mood every other mood falls back to).
    private func addPet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .jpeg]
        panel.allowsMultipleSelection = true
        panel.message = tr("Choose one GIF or one or more images for your pet")
        panel.prompt = tr("Create")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let trimmed = newPetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? tr("New pet") : trimmed
        do {
            let id = try delegate.petStore.createPet(named: name)
            delegate.petStore.setActive(id)
            let result = try SpriteImporter.replaceFrames(of: "idle", with: panel.urls)
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

    // MARK: - Quyền

    /// Deliberately has no switches. The pet holds no permission policy of its
    /// own: it shows the dialog exactly when Claude Code would have shown one,
    /// and nothing more. Anything that decides *whether* to ask -- the
    /// permission mode, the allow rules -- belongs to Claude Code, and keeping a
    /// second copy here is what used to let the two drift apart.
    private var permissionsTab: some View {
        Form {
            Section {
                Text(tr("The pet shows a dialog exactly when Claude Code would have asked you, and nothing more. Press Allow or Deny on the pet and you're done — the terminal won't ask again."))
                Text(tr("Want more or fewer prompts? Change the permission mode inside Claude Code itself (Shift+Tab, or the --permission-mode flag). The pet follows automatically."))
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("Approving permissions on the pet"))
            } footer: {
                Text(tr("If the pet is off or busy, Claude Code asks in the terminal as usual — nothing gets stuck."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Colors

    private var colorsTab: some View {
        Form {
            Section(tr("Card colors")) {
                colorRow(tr("Running tool"), $settings.tool)
                colorRow(tr("Attention"), $settings.notification)
            }

            Section(tr("Completed-task gradient")) {
                colorRow(tr("Color 1"), $settings.gradient1)
                colorRow(tr("Color 2"), $settings.gradient2)
                colorRow(tr("Color 3"), $settings.gradient3)
                LabeledContent(tr("Preview")) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(settings.completedGradient, lineWidth: 3)
                        .frame(width: 120, height: 28)
                }
            }

            Section {
                Button(tr("Restore defaults")) { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
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
