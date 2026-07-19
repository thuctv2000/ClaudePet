import AppKit
import Observation

/// One saved pet: a named folder of per-mood sprite clips under
/// `~/.petmacos/pets/<id>/` (same per-state layout `SpriteLibrary` reads).
/// The built-in vector dog is deliberately NOT a `PetInfo` — it is what shows
/// when no pet is active (`activeID == nil`), so it can never be deleted.
struct PetInfo: Identifiable, Equatable {
    let id: String          // folder name (a UUID)
    var name: String
    /// States that have at least one frame, out of `SpriteLibrary.states`.
    var coverage: Int
    /// First idle frame (or the first frame of any state) — the pet's face in
    /// the library list. Derived, never stored.
    var avatar: NSImage?
}

/// Manages the pet library: create/delete/switch, plus the one-time migration
/// of the legacy single `~/.petmacos/sprites/` folder into the first pet.
@MainActor
@Observable
final class PetStore {
    private(set) var pets: [PetInfo] = []
    /// Folder name of the active pet; nil = built-in vector dog.
    private(set) var activeID: String? = UserDefaults.standard.string(forKey: PetStore.activeKey)

    private static let activeKey = "pet.active"
    static let petsRoot = PetConfig.directory.appendingPathComponent("pets", isDirectory: true)

    /// Directory of the currently active pet, if one is chosen and still on
    /// disk. Static so `SpriteLibrary.root` can consult it without a reference.
    static var activeDirectory: URL? {
        guard let id = UserDefaults.standard.string(forKey: activeKey) else { return nil }
        let dir = petsRoot.appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return dir
    }

    static func directory(for id: String) -> URL {
        petsRoot.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Library

    /// Rescans `pets/` and rebuilds the list (alphabetical by name).
    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.petsRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        pets = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { dir in
                PetInfo(
                    id: dir.lastPathComponent,
                    name: Self.readName(of: dir) ?? dir.lastPathComponent,
                    coverage: Self.coverage(of: dir),
                    avatar: Self.avatar(of: dir)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Active pet folder gone (deleted in Finder) → fall back to the dog.
        if let id = activeID, !pets.contains(where: { $0.id == id }) {
            setActive(nil)
        }
    }

    /// Switches the displayed pet. The caller reloads `SpriteLibrary` after.
    func setActive(_ id: String?) {
        activeID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    /// Creates an empty pet folder (scaffolded per state) with the given name
    /// and returns its id. The caller imports frames and sets it active.
    func createPet(named name: String) throws -> String {
        let id = UUID().uuidString
        let dir = Self.directory(for: id)
        for state in SpriteLibrary.states {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(state), withIntermediateDirectories: true)
        }
        try Self.writeName(name, to: dir)
        return id
    }

    /// Moves the pet's folder to the Trash (recoverable — never a hard delete).
    func deletePet(id: String) {
        try? FileManager.default.trashItem(
            at: Self.directory(for: id), resultingItemURL: nil)
        if activeID == id { setActive(nil) }
        reload()
    }

    // MARK: - Legacy migration

    /// One-time: an existing `~/.petmacos/sprites/` with frames (from before
    /// the multi-pet library) becomes the first pet, keeping it on screen
    /// exactly as it was.
    func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: Self.petsRoot.path)) ?? []
        guard existing.isEmpty else { return }
        let legacy = PetConfig.directory.appendingPathComponent("sprites", isDirectory: true)
        guard Self.coverage(of: legacy) > 0 else { return }
        let id = UUID().uuidString
        do {
            try fm.createDirectory(at: Self.petsRoot, withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: Self.directory(for: id))
            try Self.writeName(tr("My pet"), to: Self.directory(for: id))
            setActive(id)
        } catch {
            // Leave the legacy folder untouched; the old single-pet path
            // (SpriteLibrary.root fallback) keeps working.
        }
    }

    // MARK: - Folder inspection

    private static func readName(of dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["name"] as? String
    }

    private static func writeName(_ name: String, to dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    private static func pngs(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func coverage(of dir: URL) -> Int {
        SpriteLibrary.states.count {
            !pngs(in: dir.appendingPathComponent($0)).isEmpty
        }
    }

    private static func avatar(of dir: URL) -> NSImage? {
        for state in ["idle"] + SpriteLibrary.states {
            if let first = pngs(in: dir.appendingPathComponent(state)).first {
                return NSImage(contentsOf: first)
            }
        }
        return nil
    }
}
