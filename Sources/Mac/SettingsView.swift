import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var store = store

        Form {
            CelebrationSection()

            SyncSection()

            Section("Data") {
                HStack {
                    Text(store.fileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                }
                HStack {
                    Text("Diagnostics are kept beside it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.folder])
                    }
                }
            }

            DiagnosticsSection()
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 480)
    }
}
