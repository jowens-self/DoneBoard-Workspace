import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                CelebrationSection()

                SyncSection()

                Section("Data") {
                    Text(store.fileURL.path)
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                DiagnosticsSection()
            }
            .navigationTitle("Settings")
        }
    }
}
