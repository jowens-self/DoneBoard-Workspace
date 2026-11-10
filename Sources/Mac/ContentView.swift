import SwiftUI

/// Calendar on the left, today's board on the right, fireworks over the top of both.
struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    @State private var run: CelebrationRun?
    @State private var runStart = Date()
    @State private var banner: CelebrationRequest?
    @State private var pane = Pane.board

    /// The board is the app; the list is a place to line things up for it. Keeping
    /// them side by side in one switch says that without needing a sentence.
    private enum Pane: String, CaseIterable, Identifiable {
        case board = "Board"
        case todo = "To-do"
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView {
            CalendarSidebar()
                .navigationSplitViewColumnWidth(min: 252, ideal: 276, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 12)
                .padding(.bottom, 2)

                switch pane {
                case .board: BoardView()
                case .todo: TodoView()
                }
            }
            .background(Palette.board)
            .navigationSplitViewColumnWidth(min: 420, ideal: 660)
        }
        .navigationSplitViewStyle(.balanced)
        .overlay { celebration }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .appBecameActive) {
                // A sync folder that couldn't be reached - a share on a Mac with its lid shut -
                // is looked for again in the background, and the store moves onto it once found.
                SyncLocation.shared.connect()
                // Another device may have written while we were away.
                store.reload()
            }
        }
        // Clicking a day in the calendar means you want to look at that day's board.
        .onChange(of: app.selectedDay) { _, _ in pane = .board }
        .onChange(of: app.pendingCelebration) { _, request in
            guard let request else { return }
            app.pendingCelebration = nil
            start(request)
        }
        // Kick the fireworks off when the run is set, and clear it when they burn out.
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
                    .padding(.top, 86)
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
