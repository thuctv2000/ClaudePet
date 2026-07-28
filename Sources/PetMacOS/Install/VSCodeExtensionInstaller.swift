import Foundation

/// Puts the bridge extension where VS Code (and its forks) will find it.
///
/// The extension is what lets a reply reach a Claude Code session in an
/// integrated terminal without touching the window — see `VSCodeBridge`. It has
/// to live inside the editor, so the pet ships a copy and installs it.
///
/// ## Copying the folder IS the install
///
/// `code --install-extension bridge.vsix` and copying the folder into
/// `~/.vscode/extensions/` produce byte-for-byte the same result (measured:
/// same directory name, same two files). The copy is used because it needs no
/// `code` binary on PATH, no subprocess, and works the same for every fork —
/// Cursor and Windsurf read their own `~/.cursor/extensions` and
/// `~/.windsurf/extensions` with no CLI of their own to find.
///
/// ## It takes effect at the next window reload
///
/// Neither route activates the extension in a window that is already open —
/// measured both ways, no lock file appeared until VS Code restarted. So this
/// installs quietly and says nothing: until the user's next reload the pet
/// falls back to driving the window, which works, and after it deliveries go
/// silent on their own. Nagging someone to reload their editor for a fallback
/// they cannot see is not worth it.
enum VSCodeExtensionInstaller {
    /// Editor data directories that hold an `extensions` folder.
    private static let editorDirectories = [".vscode", ".vscode-insiders", ".cursor", ".windsurf"]

    /// Installs or updates the extension, returning one line for the log.
    @discardableResult
    static func installIfNeeded() -> String {
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("vscode-extension"),
              let version = bundledVersion(at: source) else {
            return "vscode bridge: not shipped in this build, skipping"
        }
        let folderName = "claudepet.claudepet-bridge-\(version)"

        var touched: [String] = []
        var failures: [String] = []
        for extensions in existingExtensionDirectories() {
            do {
                let removed = try removeOtherVersions(keeping: folderName, in: extensions)
                let destination = extensions.appendingPathComponent(folderName)
                if try upToDate(destination, matching: source) {
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                touched.append(extensions.deletingLastPathComponent().lastPathComponent
                    + (removed > 0 ? " (updated)" : " (installed)"))
            } catch {
                failures.append("\(extensions.path): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { return "vscode bridge failed: " + failures.joined(separator: "; ") }
        if touched.isEmpty { return "vscode bridge: already current" }
        return "vscode bridge \(version) → " + touched.joined(separator: ", ")
            + " (active after the next VS Code reload)"
    }

    private static func existingExtensionDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return editorDirectories
            .map { home.appendingPathComponent($0).appendingPathComponent("extensions") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func bundledVersion(at source: URL) -> String? {
        guard let data = try? Data(contentsOf: source.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    /// Deletes older copies, so the editor never sees two versions of the same
    /// extension and pick whichever it scanned first.
    private static func removeOtherVersions(keeping folderName: String, in directory: URL) throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var removed = 0
        for name in names where name.hasPrefix("claudepet.claudepet-bridge-") && name != folderName {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    /// Whether the installed copy already matches the shipped one. Compared by
    /// content, not just by version: a half-finished copy from a previous run
    /// carries the right folder name and the wrong files.
    private static func upToDate(_ destination: URL, matching source: URL) throws -> Bool {
        for file in ["package.json", "extension.js"] {
            let installed = try? Data(contentsOf: destination.appendingPathComponent(file))
            let shipped = try Data(contentsOf: source.appendingPathComponent(file))
            guard installed == shipped else { return false }
        }
        return true
    }
}
