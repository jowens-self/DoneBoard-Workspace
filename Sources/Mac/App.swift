import SwiftUI

@main
struct DoneBoardApp: App {
    @State private var store = Launch.openBoard()
    @State private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("DoneBoard", id: "main") {
            ContentView()
                .environment(store)
                .environment(app)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Board") {
                Button("New Entry") { app.focusTick += 1 }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Today") { app.show(app.today) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Previous Day") { app.show(DayKey.adding(-1, to: app.selectedDay)) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Day") { app.show(DayKey.adding(1, to: app.selectedDay)) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(app.isFuture(DayKey.adding(1, to: app.selectedDay)))
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
