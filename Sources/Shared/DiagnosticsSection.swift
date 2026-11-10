import SwiftUI

/// What the app has recorded about its own troubles, and a way to hand it over - shared by both
/// platforms' settings screens.
///
/// The record itself never leaves the device on its own. Sharing it is the only way out, which is
/// why this exists: a phone away from the Mac can still send the log somewhere it can be read.
struct DiagnosticsSection: View {
    @State private var exported: URL?
    @State private var preparing = false
    @State private var latest = Diagnostics.latestReport()

    var body: some View {
        Section {
            if let previous = Diagnostics.previousRun {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last run")
                        .scaledFont(size: 13, weight: .medium)
                    Text(previous)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(latest.map { "Latest report: \($0)" } ?? "No freezes or crashes recorded.")
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)

            if let exported {
                ShareLink(item: exported) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
            } else {
                Button(preparing ? "Preparing\u{2026}" : "Prepare diagnostics to share") { prepare() }
                    .disabled(preparing)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("A record of what the app has been doing, kept on this device, with where it was stuck whenever it froze or crashed. Nothing is sent anywhere unless you share it.")
                .scaledFont(size: 11)
        }
    }

    private func prepare() {
        preparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let file = Diagnostics.exportFile()
            DispatchQueue.main.async {
                exported = file
                latest = Diagnostics.latestReport()
                preparing = false
            }
        }
    }
}
