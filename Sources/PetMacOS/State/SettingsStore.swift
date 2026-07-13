import SwiftUI
import Observation

/// User-tunable appearance settings, persisted in UserDefaults.
/// Border colours for the running-task cards plus the gradient used on
/// completed notices. Defaults mirror the original hardcoded palette.
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Defaults

    private static let defaultColors: [String: Color] = [
        Keys.thinking: .blue.opacity(0.9),
        Keys.tool: .orange.opacity(0.9),
        Keys.notification: .purple.opacity(0.9),
        Keys.session: .gray.opacity(0.9),
        Keys.done: .pink.opacity(0.9),
        Keys.gradient1: .purple,
        Keys.gradient2: .pink,
        Keys.gradient3: .orange,
    ]

    private enum Keys {
        static let thinking = "color.thinking"
        static let tool = "color.tool"
        static let notification = "color.notification"
        static let session = "color.session"
        static let done = "color.done"
        static let gradient1 = "color.gradient1"
        static let gradient2 = "color.gradient2"
        static let gradient3 = "color.gradient3"
    }

    // MARK: - Stored colours

    var thinking: Color { didSet { save(Keys.thinking, thinking) } }
    var tool: Color { didSet { save(Keys.tool, tool) } }
    var notification: Color { didSet { save(Keys.notification, notification) } }
    var session: Color { didSet { save(Keys.session, session) } }
    var done: Color { didSet { save(Keys.done, done) } }
    var gradient1: Color { didSet { save(Keys.gradient1, gradient1) } }
    var gradient2: Color { didSet { save(Keys.gradient2, gradient2) } }
    var gradient3: Color { didSet { save(Keys.gradient3, gradient3) } }

    init() {
        thinking = Self.load(Keys.thinking)
        tool = Self.load(Keys.tool)
        notification = Self.load(Keys.notification)
        session = Self.load(Keys.session)
        done = Self.load(Keys.done)
        gradient1 = Self.load(Keys.gradient1)
        gradient2 = Self.load(Keys.gradient2)
        gradient3 = Self.load(Keys.gradient3)
    }

    // MARK: - Lookup

    /// Border colour for a running card of the given kind.
    func borderColor(for kind: TaskKind) -> Color {
        switch kind {
        case .thinking: return thinking
        case .tool: return tool
        case .notification: return notification
        case .session: return session
        case .done: return done
        }
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
        thinking = Self.defaultColors[Keys.thinking]!
        tool = Self.defaultColors[Keys.tool]!
        notification = Self.defaultColors[Keys.notification]!
        session = Self.defaultColors[Keys.session]!
        done = Self.defaultColors[Keys.done]!
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
