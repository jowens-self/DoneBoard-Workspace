import Foundation

/// What both apps do before their first window, in the order it has to happen.
enum Launch {
    /// Starts the diagnostics record, opens the board, and sends the sync folder lookup off.
    ///
    /// The board opens from this device's own file, which is always quick to read. A saved sync
    /// folder is looked for in the background and the store moves onto it once it turns up - so a
    /// share on a sleeping Mac costs a board that updates a moment later, not a launch that hangs
    /// until the system kills it.
    static func openBoard() -> Store {
        Diagnostics.startSession()
        CrashCapture.start()
        // Before anything that could freeze, so a freeze in opening the board is caught too.
        HangWatch.shared.start()
        Diagnostics.follow(.appBecameActive, as: "active")
        Diagnostics.follow(.appResignedActive, as: "inactive")
        Diagnostics.follow(.appWentToBackground, as: "background")
        Diagnostics.follow(.appWillQuit, as: "quit")

        Store.keepRunning = BackgroundTime.begin
        let sync = SyncLocation.shared
        let store = Store(fileURL: sync.fileURL, keepsLocalCopy: true)
        sync.fileChanged = { url in store.relocate(to: url) }
        sync.connect()
        NotificationCenter.default.addObserver(forName: .appWentToBackground, object: nil, queue: .main) { _ in
            store.sendBeforeLeaving()
        }
        // Nothing reliably tells the phone when the Mac writes to the share, so while the app is in
        // front it looks for itself every half minute.
        NotificationCenter.default.addObserver(forName: .appBecameActive, object: nil, queue: .main) { _ in
            store.startCheckingIn()
        }
        NotificationCenter.default.addObserver(forName: .appResignedActive, object: nil, queue: .main) { _ in
            store.stopCheckingIn()
        }
        return store
    }
}
