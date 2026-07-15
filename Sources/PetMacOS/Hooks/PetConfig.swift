import Foundation

/// On-disk handshake file that lets the hook scripts find the running pet app.
/// Written to `~/.petmacos/config.json` on launch and read by `pet-hook.sh`.
struct PetConfig: Codable {
    var port: UInt16
    var token: String
    /// True once the user has been through (or explicitly skipped) the
    /// first-run onboarding flow. Preserved across launches even though
    /// `port`/`token` are regenerated every time the app starts.
    var onboardingCompleted: Bool = false

    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".petmacos", isDirectory: true)

    static let fileURL = directory.appendingPathComponent("config.json")

    init(port: UInt16, token: String, onboardingCompleted: Bool = false) {
        self.port = port
        self.token = token
        self.onboardingCompleted = onboardingCompleted
    }

    private enum CodingKeys: String, CodingKey {
        case port, token, onboardingCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(UInt16.self, forKey: .port)
        token = try container.decode(String.self, forKey: .token)
        // Missing in files written before onboarding existed; default false so
        // the caller decides (see `PetAppDelegate.shouldShowOnboarding`).
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }

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

    /// Reads the persisted onboarding flag, if the config file exists yet.
    static func readOnboardingCompleted() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(PetConfig.self, from: data)
        else { return false }
        return config.onboardingCompleted
    }

    /// Marks onboarding as done, preserving the current port/token if the file
    /// already exists (falls back to a throwaway entry otherwise — the next
    /// server start overwrites port/token anyway).
    static func markOnboardingCompleted() {
        if let data = try? Data(contentsOf: fileURL),
           var config = try? JSONDecoder().decode(PetConfig.self, from: data) {
            guard !config.onboardingCompleted else { return }
            config.onboardingCompleted = true
            try? config.write()
        } else {
            try? PetConfig(port: 0, token: makeToken(), onboardingCompleted: true).write()
        }
    }
}
