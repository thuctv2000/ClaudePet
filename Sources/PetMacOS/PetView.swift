import SwiftUI

struct PetView: View {
    var state: PetState
    var sprites: SpriteLibrary
    var settings: SettingsStore
    var usage: UsageMonitor

    @State private var isWagging = false
    @State private var isBouncing = false
    @State private var eyesClosed = false
    @State private var isHappy = false
    @State private var reacting = false   // playing the one-shot click clip

    /// A blocking dialog is on screen; shrink the pet to give it room.
    private var dialogActive: Bool {
        state.pendingQuestion != nil || state.pendingAsk != nil
    }

    private var petSide: CGFloat { dialogActive ? 150 : 280 }

    var body: some View {
        // Dog pinned to the bottom; the bubble / dialog sits right above its
        // head. The Spacer soaks up the extra height so a tall dialog grows
        // upward instead of pushing the dog out of the panel.
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            // Scrollable so a long list of subagent/background/completed cards
            // never gets clipped by or overlaps the panel — it scrolls inside
            // its own bounds instead, anchored to the newest (bottom) card.
            ScrollView(.vertical, showsIndicators: false) {
                topContent
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.runningTasks)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.subagentTasks)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.backgroundTasks)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.completedNotices)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.pendingAsk)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.pendingQuestion)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: dialogActive ? 420 : 340)
            dog
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dialogActive)
            // Usage badge stays visible under the pet at all times.
            UsageBadgeView(usage: usage)
                .padding(.top, 2)
        }
        .frame(width: 320, height: 500)
        .background(Color.clear)
        .contextMenu {
            Text("Drag me anywhere")
        }
    }

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
                onAllow: { note in state.resolve("allow", text: note) },
                onDeny: { note in state.resolve("deny", text: note) }
            )
        } else {
            TaskStackView(
                running: state.runningTasks,
                subagents: state.subagentTasks,
                backgroundTasks: state.backgroundTasks,
                completed: state.completedNotices,
                settings: settings,
                onDismiss: { id in state.dismissNotice(id: id) },
                onDismissSubagent: { id in state.dismissSubagent(id: id) },
                onDismissBackground: { id in state.dismissBackgroundTask(id: id) }
            )
        }
    }

    /// Uses sprite frames when available, otherwise the built-in vector dog.
    @ViewBuilder
    private var dog: some View {
        if let clip = resolvedClip {
            ZStack {
                AnimatedSpriteView(clip: clip)
                    .id(activeClipName)   // restart playback when the state changes
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 9)
                hearts
            }
            .frame(width: petSide, height: petSide)
            .contentShape(Rectangle())
            .onTapGesture { celebrate() }
        } else {
            vectorDog
        }
    }

    /// Name of the clip to play right now: click reaction wins, else the mood.
    private var activeClipName: String {
        if reacting, sprites.clip(named: "click") != nil { return "click" }
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

    private var vectorDog: some View {
        TimelineView(.animation) { _ in
            ZStack {
                DogShape(eyesClosed: eyesClosed, isHappy: isHappy)
                    .rotationEffect(.degrees(isWagging ? 7 : -7), anchor: .bottomLeading)
                    .offset(y: isBouncing ? -8 : 3)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 9)
                hearts
            }
            .frame(width: petSide, height: petSide)
            .contentShape(Rectangle())
            .onTapGesture { celebrate() }
            .onAppear { animate() }
        }
    }

    private func animate() {
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            isWagging = true
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            isBouncing = true
        }
        blink()
    }

    private func blink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            withAnimation(.easeInOut(duration: 0.12)) { eyesClosed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.easeInOut(duration: 0.12)) { eyesClosed = false }
                blink()
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

private struct DogShape: View {
    let eyesClosed: Bool
    let isHappy: Bool

    var body: some View {
        ZStack {
            // Tail stays behind the body so its wag reads clearly against any desktop.
            Capsule()
                .fill(Color(red: 0.70, green: 0.36, blue: 0.14))
                .frame(width: 84, height: 27)
                .rotationEffect(.degrees(-27), anchor: .leading)
                .offset(x: 86, y: 36)

            RoundedRectangle(cornerRadius: 68, style: .continuous)
                .fill(Color(red: 0.79, green: 0.45, blue: 0.20))
                .frame(width: 178, height: 126)
                .offset(y: 40)

            Circle()
                .fill(Color(red: 0.91, green: 0.60, blue: 0.32))
                .frame(width: 168, height: 152)
                .offset(y: -23)

            Group {
                Capsule()
                    .fill(Color(red: 0.66, green: 0.31, blue: 0.12))
                    .frame(width: 47, height: 87)
                    .rotationEffect(.degrees(24))
                    .offset(x: -66, y: -71)
                Capsule()
                    .fill(Color(red: 0.66, green: 0.31, blue: 0.12))
                    .frame(width: 47, height: 87)
                    .rotationEffect(.degrees(-24))
                    .offset(x: 66, y: -71)
            }

            Ellipse()
                .fill(Color(red: 0.97, green: 0.79, blue: 0.56))
                .frame(width: 96, height: 72)
                .offset(y: 7)

            HStack(spacing: 45) {
                if eyesClosed {
                    Image(systemName: "minus")
                    Image(systemName: "minus")
                } else {
                    Circle().frame(width: 14, height: 17)
                    Circle().frame(width: 14, height: 17)
                }
            }
            .font(.system(size: 17, weight: .black))
            .foregroundStyle(Color(red: 0.17, green: 0.10, blue: 0.07))
            .offset(y: -25)

            VStack(spacing: 4) {
                Circle()
                    .fill(Color(red: 0.18, green: 0.10, blue: 0.08))
                    .frame(width: 25, height: 18)
                if isHappy {
                    Text("ᴗ")
                        .font(.system(size: 27, weight: .black))
                        .foregroundStyle(Color(red: 0.25, green: 0.12, blue: 0.08))
                        .offset(y: -12)
                }
            }
            .offset(y: 6)

            RoundedRectangle(cornerRadius: 7)
                .fill(Color(red: 0.19, green: 0.53, blue: 0.64))
                .frame(width: 124, height: 17)
                .offset(y: 51)
            Circle()
                .fill(.yellow)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(.orange, lineWidth: 2))
                .offset(y: 62)
        }
    }
}
