import Foundation

/// One pet offered by openpets.dev.
struct OpenPetsEntry: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let thumbnail: URL
    let zip: URL
}

/// The pet gallery at openpets.dev, narrowed to the part we are allowed to use.
///
/// Two separate reasons the app only ever shows **originals** (`original: true`
/// in the catalog — the packs OpenPets drew in-house):
///
/// 1. **Third-party characters.** The rest of the gallery is community pixel
///    art, and openpets.dev says so plainly: "Some gallery pets may be
///    unofficial fan-made content or may reference third-party characters,
///    brands, or artwork." Shipping a browser that hands those to users is
///    handing out fan art of someone else's characters.
/// 2. **The art is not MIT.** OpenPets' code is MIT, but their own docs carve
///    the assets out: "Pet spritesheets and preview images are not covered by
///    the OpenPets code license… pet creators retain the rights to their
///    artwork unless they explicitly relicense it." No pack carries a licence
///    grant in its `pet.json`.
///
/// So ClaudePet **never redistributes** a pet: nothing is bundled into the app
/// or into a release. The catalog is read at runtime and the user's own machine
/// downloads the pack they picked, from openpets.dev, exactly as the OpenPets
/// app itself does. Community packs are deliberately left out for now.
enum OpenPetsCatalog {
    static let siteURL = URL(string: "https://openpets.dev")!
    private static let indexURL = URL(string: "https://openpets.dev/pets/catalog.v3.json")!

    enum CatalogError: LocalizedError {
        case badResponse(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "openpets.dev answered \(code)"
            case .malformed: return "The pet catalog was not in the expected format"
            }
        }
    }

    /// Originals whose *name* borrows someone else's, even though OpenPets drew
    /// the art. The `original` flag says who held the pen, not whether the
    /// character is free of third-party claims — and a pet called "Astro Bot"
    /// that is a small white robot is the PlayStation character by any other
    /// name. Judgment call, deliberately a short list, easy to extend.
    private static let brandCollisions: Set<String> = [
        "astro-bot",   // Sony's Astro Bot
        "tmuxai",      // mascot of the TmuxAI project, not ours to hand out
    ]

    /// Fetches every original pet, newest catalog first.
    ///
    /// The catalog is paginated (13 pages of 100 at the time of writing) and the
    /// `original` flag lives on the page entries, not on the index — so the
    /// pages are all fetched, concurrently, and filtered here.
    static func fetchOriginals() async throws -> [OpenPetsEntry] {
        let index = try await json(from: indexURL)
        guard let pages = index["pages"] as? [String] else { throw CatalogError.malformed }

        var entries: [OpenPetsEntry] = []
        try await withThrowingTaskGroup(of: [OpenPetsEntry].self) { group in
            for page in pages {
                guard let url = URL(string: page) else { continue }
                group.addTask { try await originals(onPage: url) }
            }
            for try await batch in group { entries += batch }
        }
        return entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func originals(onPage url: URL) async throws -> [OpenPetsEntry] {
        let page = try await json(from: url)
        let items = (page["pets"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard item["original"] as? Bool == true,
                  let id = item["id"] as? String,
                  !brandCollisions.contains(id),
                  let thumb = (item["thumbnail"] as? String).flatMap(URL.init(string:)),
                  let zip = (item["zip"] as? String).flatMap(URL.init(string:)) else { return nil }
            return OpenPetsEntry(
                id: id,
                displayName: (item["displayName"] as? String) ?? id,
                description: (item["description"] as? String) ?? "",
                thumbnail: thumb,
                zip: zip
            )
        }
    }

    private static func json(from url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CatalogError.badResponse(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.malformed
        }
        return object
    }

    /// Every request identifies the app. openpets.dev serves the catalog to
    /// anyone, but a nameless client is the kind of traffic that gets blocked
    /// later — and if they ever want to say no to us, they should be able to
    /// tell it is us.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        request.setValue("ClaudePet/\(version) (+https://github.com/thuctv2000/ClaudePet)",
                         forHTTPHeaderField: "User-Agent")
        return request
    }
}
