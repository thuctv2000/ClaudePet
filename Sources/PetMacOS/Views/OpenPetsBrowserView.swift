import AppKit
import SwiftUI

/// Browse the free pets on openpets.dev and install one with a click.
///
/// Only OpenPets' own artwork is listed — see `OpenPetsCatalog` for why the
/// community half of the gallery is left out, and why nothing is ever bundled
/// into ClaudePet: the pack is fetched by the user's own machine, on demand.
struct OpenPetsBrowserView: View {
    var delegate: PetAppDelegate
    var onClose: () -> Void

    @State private var entries: [OpenPetsEntry] = []
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var search = ""
    @State private var loadError: String?
    @State private var loading = true
    @State private var installing: String?
    @State private var installError: String?

    private var shown: [OpenPetsEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.systemAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Pets from OpenPets"))
                    .font(.system(size: 15, weight: .semibold))
                Text(tr("Free pets drawn by OpenPets themselves"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField(tr("Search"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Button(tr("Close")) { onClose() }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            centered { ProgressView().controlSize(.small) }
        } else if let loadError {
            centered {
                VStack(spacing: 8) {
                    Text(tr("Could not reach openpets.dev"))
                        .font(.system(size: 13, weight: .medium))
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(tr("Try again")) { Task { await load() } }
                }
                .padding(.horizontal, 30)
            }
        } else if shown.isEmpty {
            centered { Text(tr("No pets match that.")).foregroundStyle(.secondary) }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { entry in
                        row(entry)
                        Divider().padding(.leading, 74)
                    }
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }

    private func row(_ entry: OpenPetsEntry) -> some View {
        let id = OpenPetsInstaller.petID(for: entry)
        let installed = delegate.petStore.pets.contains { $0.id == id }
        return HStack(spacing: 12) {
            thumbnail(entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if installing == entry.id {
                ProgressView().controlSize(.small)
            } else {
                Button(installed ? tr("Reinstall") : tr("Install")) {
                    Task { await install(entry) }
                }
                .buttonStyle(.bordered)
                .disabled(installing != nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func thumbnail(_ entry: OpenPetsEntry) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .frame(width: 48, height: 48)
            .overlay {
                if let image = thumbnails[entry.id] {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: "pawprint")
                        .foregroundStyle(.tertiary)
                }
            }
            .task { await loadThumbnail(entry) }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let installError {
                    Text(installError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                // Says out loud what the app is doing on the user's behalf:
                // the art belongs to OpenPets, ClaudePet ships none of it, and
                // the download happens from their site to this machine.
                Text(tr("Artwork by OpenPets. ClaudePet ships none of it — your Mac downloads the pet you pick straight from openpets.dev."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Link(tr("openpets.dev"), destination: OpenPetsCatalog.siteURL)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Work

    private func load() async {
        loading = true
        loadError = nil
        do {
            entries = try await OpenPetsCatalog.fetchOriginals()
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadThumbnail(_ entry: OpenPetsEntry) async {
        guard thumbnails[entry.id] == nil else { return }
        guard let (data, _) = try? await URLSession.shared.data(
            for: OpenPetsCatalog.request(entry.thumbnail)), let image = NSImage(data: data) else { return }
        thumbnails[entry.id] = image
    }

    /// Installs and immediately puts the pet on screen — picking one from a
    /// gallery and then having to go find it in a list would be a strange way
    /// to end this.
    private func install(_ entry: OpenPetsEntry) async {
        installing = entry.id
        installError = nil
        do {
            let id = try await OpenPetsInstaller.install(entry)
            delegate.petStore.reload()
            delegate.petStore.setActive(id)
            delegate.reloadSprites()
        } catch {
            installError = String(format: tr("Could not install %@: %@"),
                                  entry.displayName, error.localizedDescription)
        }
        installing = nil
    }
}
