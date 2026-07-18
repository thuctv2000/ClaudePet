import SwiftUI
import Observation

/// User-tunable appearance settings, persisted in UserDefaults.
///
/// The per-conversation card (see `SessionCardView`) draws its border from
/// just three sources — the active-tool colour, the completed gradient, and a
/// fixed red for errors — so only those are configurable. `notification` also
/// tints the question dialog's accent. The old per-kind palette (thinking,
/// session, subagent, background, done) was dropped when the flat per-event
/// card stack became one card per conversation; nothing read those colours.
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Defaults

    private static let defaultColors: [String: Color] = [
        Keys.tool: .orange.opacity(0.9),
        Keys.notification: .purple.opacity(0.9),
        Keys.gradient1: .purple,
        Keys.gradient2: .pink,
        Keys.gradient3: .orange,
    ]

    private enum Keys {
        static let tool = "color.tool"
        static let notification = "color.notification"
        static let gradient1 = "color.gradient1"
        static let gradient2 = "color.gradient2"
        static let gradient3 = "color.gradient3"
    }

    // MARK: - Stored colours

    /// Border of an active (running) card.
    var tool: Color { didSet { save(Keys.tool, tool) } }
    /// Accent of the question dialog.
    var notification: Color { didSet { save(Keys.notification, notification) } }
    var gradient1: Color { didSet { save(Keys.gradient1, gradient1) } }
    var gradient2: Color { didSet { save(Keys.gradient2, gradient2) } }
    var gradient3: Color { didSet { save(Keys.gradient3, gradient3) } }

    init() {
        tool = Self.load(Keys.tool)
        notification = Self.load(Keys.notification)
        gradient1 = Self.load(Keys.gradient1)
        gradient2 = Self.load(Keys.gradient2)
        gradient3 = Self.load(Keys.gradient3)
    }

    // MARK: - Lookup

    /// Border colour for an active card. `.failed` only ever appears on a
    /// completed notice (see `TaskKind`'s doc comment), which renders via the
    /// gradient/red stroke in `SessionCardView`, so any other kind maps to the
    /// single active-tool colour.
    func borderColor(for kind: TaskKind) -> Color {
        kind == .failed ? .red.opacity(0.9) : tool
    }

    /// Gradient stroking the border of completed notices.
    var completedGradient: LinearGradient {
        LinearGradient(
            colors: [gradient1, gradient2, gradient3],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func resetToDefaults() {
        tool = Self.defaultColors[Keys.tool]!
        notification = Self.defaultColors[Keys.notification]!
        gradient1 = Self.defaultColors[Keys.gradient1]!
        gradient2 = Self.defaultColors[Keys.gradient2]!
        gradient3 = Self.defaultColors[Keys.gradient3]!
    }

    // MARK: - Persistence (hex RGBA strings)

    private func save(_ key: String, _ color: Color) {
        UserDefaults.standard.set(Self.hexString(from: color), forKey: key)
    }

    private static func load(_ key: String) -> Color {
        guard let hex = UserDefaults.standard.string(forKey: key),
              let color = color(fromHex: hex)
        else { return defaultColors[key]! }
        return color
    }

    private static func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        let a = Int(round(ns.alphaComponent * 255))
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }

    private static func color(fromHex hex: String) -> Color? {
        guard hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 24) & 0xFF) / 255
        let g = Double((value >> 16) & 0xFF) / 255
        let b = Double((value >> 8) & 0xFF) / 255
        let a = Double(value & 0xFF) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
