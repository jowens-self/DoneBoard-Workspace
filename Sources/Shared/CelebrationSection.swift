import SwiftUI

/// The celebration controls, shared by both platforms' settings screens so they can't
/// drift apart.
struct CelebrationSection: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    /// The bundled sounds, plus whatever is currently chosen even if this build has no
    /// audio for it - otherwise a choice made on a device that does would vanish here.
    private var options: [ChimeSound] {
        let available = ChimeSound.available
        return available.contains(store.goalSound) ? available : available + [store.goalSound]
    }

    var body: some View {
        @Bindable var store = store

        Section {
            Stepper(value: $store.dailyGoal, in: 1...50) {
                HStack {
                    Text("Daily goal")
                    Spacer()
                    Text("\(store.dailyGoal)")
                        .scaledFont(size: 14, weight: .semibold, design: .rounded)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            #if os(macOS)
            Toggle("Play a sound", isOn: $store.soundEnabled)
            #else
            Toggle("Sound and haptics", isOn: $store.soundEnabled)
            #endif

            // With no audio bundled there is exactly one option, and a picker offering
            // a single choice is just a row that does nothing.
            if options.count > 1 {
                Picker("Sound", selection: $store.goalSound) {
                    ForEach(options) { Text($0.name).tag($0) }
                }
                .disabled(!store.soundEnabled)
            }

            Button("Preview fireworks") {
                app.celebrate(.goalReached(count: store.dailyGoal))
            }
        } header: {
            Text("Celebration")
        } footer: {
            Text("Fireworks go off the moment you cross the goal, and again on every further multiple of it.")
                .scaledFont(size: 11)
        }
        // Picking a sound plays it, because choosing one from a list of names you have
        // never heard is not really choosing.
        .onChange(of: store.goalSound) { _, sound in
            if store.soundEnabled { Chime.play(sound) }
        }
    }
}
