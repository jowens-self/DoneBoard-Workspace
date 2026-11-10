import Foundation

// The diagnostics folder on a customer's device has to stay small however long the app runs.

func reportPruningChecks() {
    let folder = Diagnostics.reportsFolder
    let fm = FileManager.default
    for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
        try? fm.removeItem(at: old)
    }
    // Sixty reports a minute apart, newest last, and a crash still waiting to be named.
    let now = Date()
    for n in 0..<60 {
        let file = folder.appendingPathComponent(String(format: "slow-%02d.txt", n), isDirectory: false)
        write("report \(n)", to: file)
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(n - 60) * 60)], ofItemAtPath: file.path)
    }
    write("pending", to: folder.appendingPathComponent("crash-pending.txt", isDirectory: false))

    Diagnostics.startSession()
    Diagnostics.flush()
    let left = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
    let newest = Set((10..<60).map { String(format: "slow-%02d.txt", $0) })
    check(left == newest.union(["crash-pending.txt"]),
          "launch kept \(left.count) reports instead of the newest \(Diagnostics.reportsKept) and the pending crash")
}

func saveReasonChecks() {
    // A save says what it is for before it writes anything, so a freeze inside one still leaves
    // word of what was being done - which the log of 2026-10-27 had to be pieced together without.
    try? FileManager.default.removeItem(at: deviceCopy)
    let shared = freshFile("logged-saves")
    let phone = Store(fileURL: shared, keepsLocalCopy: true, watchForChanges: false)
    settle(phone)
    let today = DayKey.today
    phone.add("Logged", to: today)
    phone.addTodo("Planned")
    settle(phone)
    Diagnostics.flush()
    let file = Diagnostics.folder.appendingPathComponent("events.log", isDirectory: false)
    let log = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(log.contains("adding an entry to \(today), 1 there now"), "adding an entry left no line saying so")
    check(log.contains("for adding an entry to \(today), 1 there now:"), "the exchange didn't say which change sent it")
    check(log.contains("adding a to-do"), "adding a to-do left no line saying so")
}
