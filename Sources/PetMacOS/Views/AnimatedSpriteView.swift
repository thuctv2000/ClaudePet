import SwiftUI

/// Plays a `SpriteClip` as a flipbook. Looping clips repeat; one-shot clips
/// hold the last frame. Reset playback by changing the view's `.id(...)`.
struct AnimatedSpriteView: View {
    let clip: SpriteClip

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            if clip.frames.count == 1 {
                // A single static image still reads as alive: a gentle
                // breathing bob, so a pet made from one PNG isn't frozen.
                let phase = sin(elapsed * 2 * .pi / 2.4)
                Image(nsImage: clip.frames[0])
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(x: 1, y: 1 + 0.015 * phase, anchor: .bottom)
                    .offset(y: -2 * max(phase, 0))
            } else {
                Image(nsImage: clip.frames[frameIndex(at: elapsed)])
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .onAppear { start = Date() }
    }

    private func frameIndex(at elapsed: Double) -> Int {
        let count = clip.frames.count
        guard count > 1 else { return 0 }
        let raw = Int(elapsed * clip.fps)
        if clip.loops {
            return raw % count
        }
        return min(raw, count - 1)
    }
}
