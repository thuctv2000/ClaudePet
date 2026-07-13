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

    static let root = PetConfig.directory.appendingPathComponent("sprites", isDirectory: true)

    /// Every state the app knows how to play. `click` is the tap reaction.
    static let states = ["idle", "click", "thinking", "working", "talking", "asking", "sleep"]

    /// Sensible default fps / looping per state (overridable via clip.json).
    private static func defaults(for state: String) -> (fps: Double, loops: Bool) {
        switch state {
        case "click": return (14, false)   // one-shot reaction
        case "talking": return (10, false) // play once, hold last frame
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
        let readme = root.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        let text = """
        SPRITES CHO DESKTOP PET
        =======================
        Mỗi thư mục là một "state" (trạng thái). Thả các frame PNG trong suốt vào
        thư mục tương ứng, đặt tên theo thứ tự phát, ví dụ:
            idle/idle_000.png, idle/idle_001.png, idle/idle_002.png ...

        Các state: \(states.joined(separator: ", ")).
          - idle     : khi rảnh (nên loop)
          - click    : phản ứng khi bấm vào pet (chạy 1 lần)
          - thinking : Claude đang suy nghĩ
          - working  : đang chạy tool
          - talking  : vừa trả lời xong
          - asking   : đang xin quyền (cần chú ý)
          - sleep    : kết thúc phiên

        Tùy chọn: thêm file clip.json trong thư mục state để chỉnh tốc độ/lặp:
            {"fps": 12, "loop": true}

        Sau khi thêm/đổi ảnh, dùng menu bar > "Tải lại sprites".
        State nào chưa có ảnh sẽ tự dùng frame "idle", hoặc con chó vẽ sẵn nếu
        chưa có ảnh nào cả.
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }
}
