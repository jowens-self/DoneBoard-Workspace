import SwiftUI

/// The phone can't put the calendar beside the board the way the Mac does, so the two
/// become tabs. Everything inside them is the same code the Mac runs.
struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    @State private var run: CelebrationRun?
    @State private var runStart = Date()
    @State private var banner: CelebrationRequest?
    @State private var tab = Tab.board

    private enum Tab { case board, todo, calendar, settings }

    var body: some View {
        TabView(selection: $tab) {
            BoardView()
                .tabItem { Label("Board", systemImage: "checkmark.circle.fill") }
                .tag(Tab.board)

            TodoView()
                .tabItem { Label("To-do", systemImage: "circle.dashed") }
                .tag(Tab.todo)

            CalendarSidebar()
                .background(Palette.calendar)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .overlay { celebration }
        // Choosing a day in the calendar means you want to see that day's board.
        .onChange(of: app.selectedDay) { _, _ in tab = .board }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .appBecameActive) {
                // A sync folder that couldn't be reached - a share on a Mac with its lid shut -
                // is looked for again in the background, and the store moves onto it once found.
                SyncLocation.shared.connect()
                // Another device may have written while we were away.
                store.reload()
            }
        }
        .onChange(of: app.pendingCelebration) { _, request in
            guard let request else { return }
            app.pendingCelebration = nil
            start(request)
        }
        .task(id: run?.id) {
            guard let duration = run?.duration else { return }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            run = nil
        }
        .task(id: banner?.id) {
            guard banner != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { banner = nil }
        }
    }

    @ViewBuilder
    private var celebration: some View {
        ZStack {
            if let run {
                FireworksOverlay(run: run, start: runStart)
            }
            if let banner {
                CelebrationBanner(kind: banner.kind)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    private func start(_ request: CelebrationRequest) {
        runStart = Date()
        run = CelebrationRun.make(for: request.kind)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
            banner = request
        }
        if store.soundEnabled { Chime.play(store.goalSound) }
    }
}
