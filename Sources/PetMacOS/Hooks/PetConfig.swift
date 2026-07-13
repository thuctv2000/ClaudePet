import Foundation

/// On-disk handshake file that lets the hook scripts find the running pet app.
/// Written to `~/.petmacos/config.json` on launch and read by `pet-hook.sh`.
struct PetConfig: Codable {
    var port: UInt16
    var token: String

    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".petmacos", isDirectory: true)

    static let fileURL = directory.appendingPathComponent("config.json")

    /// Generates a fresh random token for this launch.
    static func makeToken() -> String {
        UUID().uuidString + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Persists the config so hooks can read the current port and token.
    func write() throws {
        try FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL, options: .atomic)
    }
}
