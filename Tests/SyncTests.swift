import Foundation

// Two devices on one file, and a board in a shared folder that keeps going when the folder doesn't
// answer.

func twoDeviceChecks() {
    // Two stores on one file are two devices sharing it: every save merges with what the other
    // wrote, and a reload is what the app does on coming to the front.
    let url = freshFile("two-devices")
    let mac = board(at: url), phone = board(at: url)
    let today = DayKey.today
    func texts(_ store: Store) -> Set<String> { Set(store.entries(on: today).map(\.text)) }

    mac.add("On the Mac", to: today)
    phone.add("On the phone", to: today)
    mac.reload()
    check(texts(mac) == ["On the Mac", "On the phone"] && texts(phone) == texts(mac),
          "two devices adding at once didn't end up with both entries")

    // The same entry edited on both: the later edit wins, on both.
    let both = mac.entries(on: today).first { $0.text == "On the Mac" }!
    mac.update(both, text: "The Mac's edit")
    // Later by more than the file can tell apart. It keeps milliseconds, and a stamp in memory keeps
    // the rest, so two edits inside one millisecond can settle differently on each side - a saved
    // file is quick enough for that now nothing in place waits on coordination.
    Thread.sleep(forTimeInterval: 0.005)
    phone.update(both, text: "The phone's later edit")
    mac.reload()
    check(texts(mac) == texts(phone) && texts(mac).contains("The phone's later edit"),
          "an entry edited on both devices settled on \(texts(mac)) and \(texts(phone))")

    // A deletion reaches the other device, and stays gone when that device saves something else.
    let doomed = phone.entries(on: today).first { $0.text == "On the phone" }!
    phone.delete(doomed)
    mac.add("Something else", to: today)
    phone.reload()
    check(!texts(mac).contains("On the phone") && !texts(phone).contains("On the phone"),
          "an entry deleted on one device came back")

    // Settings travel too.
    mac.dailyGoal = 8
    phone.reload()
    phone.soundEnabled = false
    mac.reload()
    check(phone.dailyGoal == 8 && !mac.soundEnabled, "settings didn't reach the other device")
}

func sharedFolderChecks() {
    try? FileManager.default.removeItem(at: deviceCopy)
    let shared = freshFile("shared-folder")
    let phone = Store(fileURL: shared, keepsLocalCopy: true, watchForChanges: false)
    check(settle(phone), "opening a shared board never finished")

    phone.add("Logged on the phone", to: DayKey.today)
    // This device's copy has it straight away - that is what makes a change safe before the
    // shared folder has answered.
    check(board(at: deviceCopy).records.map(\.text) == ["Logged on the phone"], "a change didn't reach this device's copy at once")
    check(settle(phone) && board(at: shared).records.map(\.text) == ["Logged on the phone"],
          "a change didn't reach the shared file")

    // The folder stops answering - a phone away from the Wi-Fi a Mac's share is on.
    let before = try! Data(contentsOf: shared)
    chmod(shared.path, 0)
    phone.add("Logged while away", to: DayKey.today)
    check(settle(phone) && phone.syncProblem != nil, "a shared file that couldn't be reached wasn't reported")
    check(board(at: deviceCopy).records.count == 2, "a change made while away wasn't kept on this device")
    chmod(shared.path, 0o644)
    check((try? Data(contentsOf: shared)) == before, "a shared file that couldn't be read was written over")

    // Back in reach: coming to the front sends what was made meanwhile.
    phone.reload()
    check(settle(phone) && phone.syncProblem == nil, "the problem didn't clear once the file was back")
    check(Set(board(at: shared).records.map(\.text)) == ["Logged on the phone", "Logged while away"],
          "what was made while away didn't reach the shared file")
}

func mainThreadChecks() {
    // A share on a sleeping Mac doesn't fail, it just doesn't answer - and iOS kills an app whose
    // main thread waits on one. Hold the shared file the way that looks, with another writer that
    // has claimed it and won't let go, and make sure a change still returns at once.
    try? FileManager.default.removeItem(at: deviceCopy)
    let shared = freshFile("held-share")
    let phone = Store(fileURL: shared, keepsLocalCopy: true, watchForChanges: false)
    settle(phone)

    let claimed = DispatchSemaphore(value: 0), letGo = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: shared, options: [], error: &error) { _ in
            claimed.signal()
            _ = letGo.wait(timeout: .now() + 15)
        }
    }
    claimed.wait()
    let started = Date()
    phone.add("While the share is held", to: DayKey.today)
    let waited = Date().timeIntervalSince(started)
    check(waited < 0.5, "adding an entry waited \(String(format: "%.1f", waited))s on a share that wasn't answering")
    check(board(at: deviceCopy).records.count == 1, "the change wasn't kept on this device while the share was held")
    letGo.signal()
    check(settle(phone) && board(at: shared).records.count == 1, "the change didn't reach the share once it let go")
}

func samePlaceChecks() {
    // Telling two files apart is done from their names alone - asking the disk was a network
    // round trip on the main thread, and it froze the phone on a share that had gone.
    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    check(Store.samePlace(url("/private/var/mobile/Library/board.json"), url("/var/mobile/Library/board.json")),
          "/private/var and /var weren't taken for the same place")
    check(Store.samePlace(url("/tmp/a/./b/../board.json"), url("/private/tmp/a/board.json")),
          "dots in a path changed the file it names")
    check(!Store.samePlace(url("/var/a/board.json"), url("/var/b/board.json")), "two folders were taken for one")
    check(!Store.samePlace(url("/private/Users/board.json"), url("/Users/board.json")),
          "a /private that stands for nothing was dropped")

    // Moving to the same file under its other name moves nothing.
    let (store, file) = freshStore("same-place")
    store.add("Kept", to: DayKey.today)
    let other = file.path.hasPrefix("/private/") ? String(file.path.dropFirst("/private".count)) : "/private" + file.path
    store.relocate(to: URL(fileURLWithPath: other))
    check(store.fileURL == file, "moving to the same file under its other name moved the store")
}

func leavingAHeldShareChecks() {
    // Stopping syncing because the share has stopped answering is exactly when its exchange is
    // stuck. Going back to this device's own file mustn't wait for it.
    let wasCoordinating = Store.coordinatesInPlace
    Store.coordinatesInPlace = false
    defer { Store.coordinatesInPlace = wasCoordinating }
    try? FileManager.default.removeItem(at: deviceCopy)
    let shared = freshFile("left-share")
    let phone = Store(fileURL: shared, keepsLocalCopy: true, watchForChanges: false)
    settle(phone)
    phone.add("Before the share went", to: DayKey.today)
    settle(phone)

    let claimed = DispatchSemaphore(value: 0), letGo = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: shared, options: [], error: &error) { _ in
            claimed.signal()
            _ = letGo.wait(timeout: .now() + 15)
        }
    }
    claimed.wait()
    phone.add("While the share is held", to: DayKey.today)
    let started = Date()
    phone.relocate(to: deviceCopy)
    phone.add("Back on this device", to: DayKey.today)
    let waited = Date().timeIntervalSince(started)
    check(waited < 0.5, "leaving a share that wasn't answering waited \(String(format: "%.1f", waited))s")
    check(phone.fileURL == deviceCopy && board(at: deviceCopy).records.count == 3,
          "going back to this device's file didn't keep everything")
    letGo.signal()
    settle(phone)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(Set(board(at: deviceCopy).records.map(\.text))
            == ["Before the share went", "While the share is held", "Back on this device"],
          "the stuck exchange coming back lost something")
}
