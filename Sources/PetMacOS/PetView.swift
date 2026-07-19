import SwiftUI

struct PetView: View {
    var state: PetState
    var sprites: SpriteLibrary
    var settings: SettingsStore
    var usage: UsageMonitor
    var petStore: PetStore
    /// Wired by the app delegate: switch the active pet / open settings /
    /// hide the pet — all reachable from the right-click menu on the pet.
    var onSwitchPet: (String) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onHidePet: () -> Void = {}

    @State private var isHappy = false
    @State private var reacting = false   // playing the one-shot click clip
    @State private var celebratingStop = false   // playing the one-shot "happy" clip after a clean Stop

    /// A blocking dialog is on screen; shrink the pet to give it room.
    private var dialogActive: Bool {
        state.pendingQuestion != nil || state.pendingAsk != nil
    }

    private func petSide(hasCards: Bool) -> CGFloat {
        if dialogActive { return 150 }
        // Give the session-card stack breathing room while cards are on
        // screen; the pet grows back once every conversation is done.
        return hasCards ? 210 : 280
    }

    var body: some View {
        // Grouping walk is O(sessions x items) — compute once per render and
        // hand the same array to everything below.
        let summaries = state.orderedSessionSummaries
        // Dog pinned to the bottom; the bubble / dialog sits right above its
        // head. The Spacer soaks up the extra height so a tall dialog grows
        // upward instead of pushing the dog out of the panel.
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            if dialogActive {
                // Scrollable so a tall dialog never gets clipped by the
                // panel; anchored to the bottom so it grows upward from the
                // pet's head.
                ScrollView(.vertical, showsIndicators: false) {
                    topContent
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.pendingAsk)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.pendingQuestion)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 420)
            } else {
                // The session-card list scrolls inside its own bounds (see
                // SessionStackView) so the "Latest" card is always in view.
                stackContent(summaries)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: summaries)
                    .frame(maxHeight: 300)
            }
            dog(side: petSide(hasCards: !summaries.isEmpty))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dialogActive)
            // Usage badge stays visible under the pet at all times.
            UsageBadgeView(usage: usage)
                .padding(.top, 2)
        }
        .frame(width: 320, height: 500)
        .background(Color.clear)
        .contextMenu {
            if !petStore.pets.isEmpty {
                Menu(tr("Switch pet")) {
                    ForEach(petStore.pets) { pet in
                        Button {
                            onSwitchPet(pet.id)
                        } label: {
                            if petStore.activeID == pet.id {
                                Label(pet.name, systemImage: "checkmark")
                            } else {
                                Text(pet.name)
                            }
                        }
                    }
                }
                Divider()
            }
            Button(tr("Settings…")) { onOpenSettings() }
            Button(tr("Hide pet")) { onHidePet() }
        }
        .onChange(of: state.happyID) { _, newValue in
            // A clean Stop just happened. Play "happy" once if the user has
            // that sprite; otherwise this is a no-op and the mood's own clip
            // ("talking", already set by PetState) keeps playing unchanged.
            guard newValue != nil, let clip = sprites.clip(named: "happy") else { return }
            celebratingStop = true
            let seconds = max(clip.duration, 0.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                celebratingStop = false
            }
        }
    }

    /// The blocking dialog, when one is pending (dialog branch of `body`).
    @ViewBuilder
    private var topContent: some View {
        if let question = state.pendingQuestion {
            QuestionDialogView(
                question: question,
                accent: settings.notification,
                onSubmit: { answers in state.resolveQuestion(answers) },
                onSkip: { state.skipQuestion() }
            )
        } else if let ask = state.pendingAsk {
            PermissionDialogView(
                ask: ask,
                onAllow: { state.resolve("allow") },
                onDeny: { state.resolve("deny") }
            )
        }
    }

    /// The per-conversation card stack (no-dialog branch of `body`), fed the
    /// summaries `body` already computed.
    private func stackContent(_ summaries: [PetState.SessionSummary]) -> some View {
        SessionStackView(
            summaries: summaries,
            settings: settings,
            onDismissCard: { key in state.dismissSession(key: key) },
            onDismissSubagent: { id in state.dismissSubagent(id: id) },
            onDismissBackground: { id in state.dismissBackgroundTask(id: id) }
        )
    }

    /// Plays the active pet's sprite clip; with no pet on disk (fresh install,
    /// all pets deleted) a quiet paw placeholder keeps the window visible so
    /// Settings is still reachable to add one.
    @ViewBuilder
    private func dog(side: CGFloat) -> some View {
        ZStack {
            if let clip = resolvedClip {
                AnimatedSpriteView(clip: clip)
                    .id(activeClipName)   // restart playback when the state changes
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 9)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            hearts
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onTapGesture { celebrate() }
    }

    /// Name of the clip to play right now: click reaction wins, then the
    /// "happy" one-shot after a clean Stop, else the mood's own clip.
    private var activeClipName: String {
        if reacting, sprites.clip(named: "click") != nil { return "click" }
        if celebratingStop, sprites.clip(named: "happy") != nil { return "happy" }
        return state.mood.spriteName
    }

    /// Falls back to the idle clip when a mood has no frames of its own.
    private var resolvedClip: SpriteClip? {
        sprites.clip(named: activeClipName) ?? sprites.clip(named: "idle")
    }

    @ViewBuilder
    private var hearts: some View {
        if isHappy {
            ForEach(0..<3, id: \.self) { index in
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.system(size: 18))
                    .offset(x: CGFloat(index - 1) * 40, y: -118)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func celebrate() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { isHappy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation { isHappy = false }
        }

        // Play the one-shot click clip (if present), then revert to the mood.
        if let click = sprites.clip(named: "click") {
            reacting = true
            let seconds = max(click.duration, 0.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                reacting = false
            }
        }
    }
}
