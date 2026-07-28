import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns an openpets.dev pet pack into a ClaudePet pet.
///
/// An OpenPets pack is two files — `pet.json` and one `spritesheet.webp` laid
/// out as a fixed grid — while ClaudePet plays a folder of PNG frames per mood.
/// So installing is: download, unzip, slice the grid, write the frames the app
/// already knows how to read. Nothing about the running app changes.
///
/// The grid is theirs and is documented in their desktop source
/// (`reaction-animation-mapping.ts`): 8 columns × 9 rows of 192×208 frames, one
/// animation per row, each using only the first N cells of its row.
enum OpenPetsInstaller {
    /// Folder id an installed pack gets. Prefixed so it is obvious where the
    /// pet came from, and stable so re-installing replaces instead of piling up.
    static func petID(for entry: OpenPetsEntry) -> String { "openpets-\(entry.id)" }

    enum InstallError: LocalizedError {
        case download(Int)
        case unzipFailed(String)
        case noSpritesheet
        case undecodable
        case wrongGeometry(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case .download(let code): return "Download failed (HTTP \(code))"
            case .unzipFailed(let message): return "Could not unpack the pet: \(message)"
            case .noSpritesheet: return "The pack has no spritesheet"
            case .undecodable: return "The spritesheet could not be read"
            case .wrongGeometry(let w, let h): return "Unexpected spritesheet size (\(w)×\(h))"
            }
        }
    }

    // MARK: - The grid

    /// The sheet is always this grid; the cell size is derived from it so a
    /// pack shipping a 2× sheet still slices correctly.
    private static let sheetColumns = 8
    private static let sheetRows = 9   // one animation per row

    /// One animation on the sheet: which row, how many of its cells are used,
    /// and how long OpenPets plays them for.
    private struct Animation {
        let row: Int
        let frames: Int
        let seconds: Double
        var fps: Double { Double(frames) / seconds }
    }

    private static let idle = Animation(row: 0, frames: 6, seconds: 5.5)
    private static let waving = Animation(row: 3, frames: 4, seconds: 0.7)
    private static let jumping = Animation(row: 4, frames: 5, seconds: 0.84)
    private static let failed = Animation(row: 5, frames: 8, seconds: 1.22)
    private static let waiting = Animation(row: 6, frames: 6, seconds: 1.01)
    private static let running = Animation(row: 7, frames: 6, seconds: 0.82)
    private static let review = Animation(row: 8, frames: 6, seconds: 1.03)

    /// ClaudePet mood → the OpenPets animation that fits it, and whether it
    /// loops. Rows 1 and 2 (`running-left`/`running-right`) are skipped: they
    /// are for a pet that walks across the screen, which ours does not do.
    ///
    /// `sleep` reuses the idle frames deliberately — the sheet has no sleep
    /// animation, and idle at its own slow cadence reads as "resting" far
    /// better than freezing on one frame.
    private static let moods: [(state: String, animation: Animation, loops: Bool)] = [
        ("idle", idle, true),
        ("click", jumping, false),
        ("thinking", review, true),
        ("working", running, true),
        ("talking", waving, false),
        ("asking", waiting, true),
        ("sleep", idle, true),
        ("error", failed, true),
        ("happy", jumping, false),
    ]

    // MARK: - Install

    /// Downloads the pack and writes it in as a pet. Returns the pet's folder id.
    ///
    /// Runs off the main actor: a pack is ~2MB and slicing writes ~40 PNGs, and
    /// none of that should touch the UI thread.
    static func install(_ entry: OpenPetsEntry) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: OpenPetsCatalog.request(entry.zip))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.download(http.statusCode)
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openpets-\(entry.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("pack.zip")
        try data.write(to: zip)
        try unzip(zip, into: scratch)

        guard let sheet = spritesheet(in: scratch) else { throw InstallError.noSpritesheet }
        let id = petID(for: entry)
        try slice(sheet, into: PetStore.directory(for: id))
        try writeName(entry.displayName, id: id)
        return id
    }

    private static func unzip(_ zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zip.path, "-d", directory.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unzipFailed(message.isEmpty ? "unzip exited \(process.terminationStatus)" : message)
        }
    }

    /// The sheet, wherever the pack put it (some packs nest everything in a
    /// folder named after the pet).
    private static func spritesheet(in directory: URL) -> URL? {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files.first { $0.lastPathComponent.lowercased().hasSuffix("spritesheet.webp") }
            ?? files.first { $0.pathExtension.lowercased() == "webp" && !$0.lastPathComponent.contains("thumb") }
    }

    // MARK: - Slicing

    /// Cuts every mood's frames out of the sheet and writes them as PNGs.
    ///
    /// WebP needs no extra library: ImageIO on macOS decodes it, which is why
    /// the sheet can go straight from the download into `CGImage`.
    private static func slice(_ sheet: URL, into directory: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sheet as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw InstallError.undecodable
        }
        guard image.width % sheetColumns == 0, image.height % sheetRows == 0 else {
            throw InstallError.wrongGeometry(width: image.width, height: image.height)
        }
        let cellWidth = image.width / sheetColumns
        let cellHeight = image.height / sheetRows

        // Everything is cropped to one box — the union of what is actually
        // drawn across every frame we keep — so the pet fills the window
        // instead of floating inside the sheet's padding, and every mood still
        // lines up with every other one.
        var used: [(state: String, loops: Bool, fps: Double, frames: [CGImage])] = []
        for mood in moods {
            var frames: [CGImage] = []
            for column in 0..<mood.animation.frames {
                let rect = CGRect(x: column * cellWidth, y: mood.animation.row * cellHeight,
                                  width: cellWidth, height: cellHeight)
                if let frame = image.cropping(to: rect) { frames.append(frame) }
            }
            guard !frames.isEmpty else { continue }
            used.append((mood.state, mood.loops, mood.animation.fps, frames))
        }
        let box = contentBox(of: used.flatMap(\.frames)) ?? CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight)

        let fm = FileManager.default
        for mood in used {
            let stateDir = directory.appendingPathComponent(mood.state, isDirectory: true)
            try? fm.removeItem(at: stateDir)
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            for (index, frame) in mood.frames.enumerated() {
                guard let cropped = frame.cropping(to: box) else { continue }
                let url = stateDir.appendingPathComponent(String(format: "%@_%03d.png", mood.state, index))
                try write(cropped, to: url)
            }
            let clip = try JSONSerialization.data(
                withJSONObject: ["fps": (mood.fps * 100).rounded() / 100, "loop": mood.loops])
            try clip.write(to: stateDir.appendingPathComponent("clip.json"), options: .atomic)
        }
        // Scaffold the moods the sheet has nothing for, so the Settings list
        // still shows every state and the user can drop their own frames in.
        for state in SpriteLibrary.states where !used.contains(where: { $0.state == state }) {
            try? fm.createDirectory(at: directory.appendingPathComponent(state, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
    }

    /// The smallest rect containing every non-transparent pixel of `frames`.
    /// Returns nil for a fully transparent set (then the caller keeps the cell).
    private static func contentBox(of frames: [CGImage]) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for frame in frames {
            let width = frame.width, height = frame.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        // A couple of pixels of air so nothing touches the edge after scaling.
        let pad = 2
        let first = frames[0]
        let x = max(0, minX - pad), y = max(0, minY - pad)
        return CGRect(x: x, y: y,
                      width: min(first.width - x, maxX - minX + 1 + pad * 2),
                      height: min(first.height - y, maxY - minY + 1 + pad * 2))
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw InstallError.undecodable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw InstallError.undecodable }
    }

    private static func writeName(_ name: String, id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        try data.write(to: PetStore.directory(for: id).appendingPathComponent("meta.json"), options: .atomic)
    }
}
