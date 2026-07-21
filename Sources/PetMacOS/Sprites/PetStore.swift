import AppKit
import Observation

/// One saved pet: a named folder of per-mood sprite clips under
/// `~/.petmacos/pets/<id>/` (same per-state layout `SpriteLibrary` reads).
/// With no pet active (`activeID == nil`, e.g. every pet deleted) the app
/// shows a paw placeholder until one is added — there is no built-in pet.
struct PetInfo: Identifiable, Equatable {
    let id: String          // folder name (a UUID, or PetStore.builtinID)
    var name: String
    /// States that have at least one frame, out of `SpriteLibrary.states`.
    var coverage: Int
    /// First idle frame (or the first frame of any state) — the pet's face in
    /// the library list. Derived, never stored.
    var avatar: NSImage?
    /// The bundled default pet (Dino). Always present, can't be deleted; the
    /// app re-provisions it on launch if its folder is missing.
    var isBuiltin: Bool { id == PetStore.builtinID }
}

/// Manages the pet library: create/delete/switch, plus the one-time migration
/// of the legacy single `~/.petmacos/sprites/` folder into the first pet.
@MainActor
@Observable
final class PetStore {
    private(set) var pets: [PetInfo] = []
    /// Folder name of the active pet; nil = none (paw placeholder).
    private(set) var activeID: String? = UserDefaults.standard.string(forKey: PetStore.activeKey)

    private static let activeKey = "pet.active"
    static let petsRoot = PetConfig.directory.appendingPathComponent("pets", isDirectory: true)

    /// Fixed folder id of the bundled default pet, so it can be recognised
    /// (and protected from deletion) across launches — unlike user pets, which
    /// get random UUIDs.
    nonisolated static let builtinID = "dino-default"
    nonisolated static let builtinName = "Dino"

    /// Maps each app mood to the bundled GIF that supplies its frames.
    /// (`row02_excited` → the tap reaction `click`; `row06_confused` → `asking`;
    /// `row08_upset` → `error`; `row09_celebrate` → the clean-finish `happy`.)
    private static let builtinGIFs: [(state: String, gif: String)] = [
        ("idle", "row01_idle"),
        ("click", "row02_excited"),
        ("thinking", "row03_thinking"),
        ("working", "row04_working_laptop"),
        ("talking", "row05_waving"),
        ("asking", "row06_confused"),
        ("sleep", "row07_sleeping"),
        ("error", "row08_upset"),
        ("happy", "row09_celebrate"),
    ]

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

    /// Renames a pet (rewrites its meta.json) and refreshes the list.
    func renamePet(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? Self.writeName(trimmed, to: Self.directory(for: id))
        reload()
    }

    /// Moves the pet's folder to the Trash (recoverable — never a hard delete).
    /// Deleting the active pet hands the stage to the first remaining pet, if
    /// any. The bundled Dino is protected: it can't be deleted (and would be
    /// re-provisioned on next launch anyway), so the library is never empty.
    func deletePet(id: String) {
        guard id != Self.builtinID else { return }
        try? FileManager.default.trashItem(
            at: Self.directory(for: id), resultingItemURL: nil)
        let wasActive = activeID == id
        reload()
        if wasActive { setActive(pets.first?.id) }
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

    // MARK: - Bundled default pet

    /// Ensures the bundled Dino pet exists on disk. Runs on every launch (fresh
    /// install *and* update): if the `dino-default` folder has no frames yet, it
    /// converts the bundled GIFs into it — one clip per mood. A no-op once
    /// provisioned, so a user who renamed it keeps their name and frames.
    /// Returns true if it created the pet this call (caller may make it active).
    @discardableResult
    func provisionBuiltinIfNeeded() -> Bool {
        let dir = Self.directory(for: Self.builtinID)
        guard Self.coverage(of: dir) == 0 else { return false }
        var wrote = false
        for (state, gif) in Self.builtinGIFs {
            guard let url = Self.bundledGIF(gif) else { continue }
            if (try? SpriteImporter.replaceFrames(of: state, with: [url], into: dir)) != nil {
                wrote = true
            }
        }
        guard wrote else { return false }   // resources missing (bare dev run)
        try? Self.writeName(Self.builtinName, to: dir)
        reload()
        return true
    }

    /// Locates a bundled GIF by name in whichever bundle this build uses
    /// (`Bundle.module` under SPM, `Bundle.main` in the xcodegen .app).
    private static func bundledGIF(_ name: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: "gif")
        #else
        return Bundle.main.url(forResource: name, withExtension: "gif")
        #endif
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
