import SwiftUI
import UniformTypeIdentifiers

/// The sync controls, shared by both platforms' settings screens.
///
/// A folder is picked rather than a file, which sidesteps the awkward first-run case:
/// there is no archive to point at until one has been made, and folder permission
/// covers the file the app creates inside it.
///
/// Nothing here moves the store. `SyncLocation` tells it whenever the file changes, which is
/// the only way the lookups it runs in the background could reach it anyway.
struct SyncSection: View {
    @Environment(Store.self) private var store
    @State private var sync = SyncLocation.shared
    @State private var picking = false
    @State private var problem: String?
    /// Set by Try again, so a lookup that comes back empty-handed says so.
    @State private var retried = false

    var body: some View {
        Section {
            switch sync.state {
            case .connected(let folder):
                folderRow(folder.lastPathComponent, icon: "folder.fill",
                          note: "Every device pointed here shares one board.")
                Button("Stop syncing", role: .destructive) { sync.stop() }
            case .connecting(let name):
                folderRow(name, icon: "folder",
                          note: "Looking for it\u{2026} The board works as usual meanwhile, on this device's own copy.")
                Button("Stop syncing", role: .destructive) { sync.stop() }
            case .unreachable(let name):
                folderRow(name, icon: "folder.badge.questionmark",
                          note: "Can't reach it right now, so this device is keeping its own copy. It all merges in once the folder is back.")
                Button("Try again") { tryAgain() }
                Button("Stop syncing", role: .destructive) { sync.stop() }
            case .local:
                Button("Choose a sync folder\u{2026}") { picking = true }
            }

            if let problem {
                Text(problem)
                    .scaledFont(size: 11)
                    .foregroundStyle(.red)
            }

            // A save or read that keeps failing. The store retries on its own, and without
            // this line those retries were invisible - a device that couldn't reach the
            // shared file looked exactly like one that could.
            if let trouble = store.syncProblem {
                Text(trouble)
                    .scaledFont(size: 11)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(sync.isSyncing
                 ? "Entries already on this device were merged in, and nothing was replaced. Deleting on one device deletes everywhere."
                 : "Pick a folder every device can reach - one shared from a Mac, or one in Dropbox - and point the others at the same one. Whatever is already on each device is merged in rather than overwritten.")
                .scaledFont(size: 11)
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            adopt(result)
        }
        .onChange(of: sync.state) { _, state in
            switch state {
            case .connecting:
                break
            case .unreachable(let name) where retried:
                problem = "Still can't reach \u{201C}\(name)\u{201D}."
                retried = false
            default:
                retried = false
            }
        }
    }

    private func folderRow(_ name: String, icon: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(name, systemImage: icon)
                .scaledFont(size: 13, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(note)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }

    private func adopt(_ result: Result<[URL], Error>) {
        problem = nil
        guard case .success(let urls) = result, let folder = urls.first else {
            if case .failure(let error) = result { problem = error.localizedDescription }
            return
        }
        sync.use(folder) { error in
            // Say what actually went wrong - a generic line here is what made the phone's
            // failure to keep a folder impossible to see.
            problem = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    private func tryAgain() {
        problem = nil
        retried = true
        sync.connect()
    }
}
