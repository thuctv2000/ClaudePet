import AppKit
import Observation

/// One animation clip: an ordered set of frames plus playback settings.
struct SpriteClip {
    let frames: [NSImage]
    let fps: Double
    let loops: Bool

    /// Total play time of one pass through the frames.
    var duration: Double { Double(frames.count) / max(fps, 0.001) }
}

/// Loads per-state PNG frame sequences from `~/.petmacos/sprites/<state>/`.
/// Living outside the app bundle means frames can be added or swapped without
/// rebuilding — just drop PNGs in the folder and choose "Tải lại sprites".
@MainActor
@Observable
final class SpriteLibrary {
    private(set) var clips: [String: SpriteClip] = [:]

    /// Folder the clips load from: the active pet's directory when one is
    /// chosen (see `PetStore`), else the legacy single-pet `sprites/` folder —
    /// kept as the fallback so pre-library installs and the "no pet" state
    /// still have a place for the scaffold/README.
    static var root: URL {
        PetStore.activeDirectory
            ?? PetConfig.directory.appendingPathComponent("sprites", isDirectory: true)
    }

    /// Every state the app knows how to play. `click` is the tap reaction;
    /// `happy` is the one-shot played on a clean `Stop` (see `PetState.happyID`).
    static let states = ["idle", "click", "thinking", "working", "talking", "asking", "sleep", "error", "happy"]

    /// Sensible default fps / looping per state (overridable via clip.json).
    private static func defaults(for state: String) -> (fps: Double, loops: Bool) {
        switch state {
        case "click": return (14, false)   // one-shot reaction
        case "happy": return (14, false)   // one-shot reaction, like click
        case "talking": return (10, false) // play once, hold last frame
        case "error": return (10, true)    // loops for as long as the mood shows
        case "sleep": return (5, true)
        default: return (10, true)
        }
    }

    /// True if any state has frames; otherwise the app uses the vector fallback.
    var hasAnyFrames: Bool { !clips.isEmpty }

    func clip(named name: String) -> SpriteClip? { clips[name] }

    /// (Re)scans the sprites folder and rebuilds all clips.
    func reload() {
        var loaded: [String: SpriteClip] = [:]
        for state in Self.states {
            let dir = Self.root.appendingPathComponent(state, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }

            let frames = files
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .compactMap { NSImage(contentsOf: $0) }
            guard !frames.isEmpty else { continue }

            var settings = Self.defaults(for: state)
            let configURL = dir.appendingPathComponent("clip.json")
            if let data = try? Data(contentsOf: configURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let fps = object["fps"] as? Double { settings.fps = fps }
                if let loop = object["loop"] as? Bool { settings.loops = loop }
            }

            loaded[state] = SpriteClip(frames: frames, fps: settings.fps, loops: settings.loops)
        }
        clips = loaded
    }

    /// Creates the folder scaffold and a README so the user knows where to drop
    /// frames. Safe to call on every launch.
    static func ensureScaffold() {
        for state in states {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(state), withIntermediateDirectories: true)
        }
        // README.txt is generated documentation, not user content — safe to
        // overwrite on every launch (unlike the sprite frames / clip.json next
        // to it, which are never touched here) so users who installed the app
        // before "error"/"happy" existed still see them listed.
        let readme = root.appendingPathComponent("README.txt")
        let text = """
        SPRITES FOR DESKTOP PET
        ========================
        \(tr("Each folder is a \"state\". Drop transparent PNG frames into the matching folder, named in playback order, e.g.:"))
            idle/idle_000.png, idle/idle_001.png, idle/idle_002.png ...

        \(tr("States")): \(states.joined(separator: ", ")).
          - idle     : \(tr("when idle (should loop)"))
          - click    : \(tr("reaction when the pet is tapped (plays once)"))
          - thinking : \(tr("Claude is thinking"))
          - working  : \(tr("running a tool"))
          - talking  : \(tr("just replied"))
          - asking   : \(tr("asking for permission (needs attention)"))
          - sleep    : \(tr("session ended"))
          - error    : \(tr("a tool just failed (shows briefly, then clears itself)"))
          - happy    : \(tr("reaction when Claude just finished cleanly (plays once; falls back to \"talking\" if you have no frames for it)"))

        \(tr("Optional: add a clip.json file inside a state folder to adjust speed/looping:"))
            {"fps": 12, "loop": true}

        \(tr("After adding or changing images, use the menu bar > \"Reload sprites\"."))
        \(tr("Any state with no images falls back to the \"idle\" frame, or the built-in vector dog if there are no images at all."))
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }
}
