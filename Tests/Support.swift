import Foundation

// What every file of checks shares: counting, a scratch folder per test, and the comparisons the
// model types don't need for themselves.

var checks = 0
var failures = 0
private var pending: [String] = []

/// Records one expectation. A failure is noted and the run carries on, so one run shows every
/// broken thing rather than only the first.
func check(_ condition: Bool, _ what: @autoclosure () -> String,
           file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    pending.append("        \(what())  (\(file):\(line))")
}

/// Runs one named group of checks and says how it went, with what failed underneath.
func group(_ name: String, _ body: () throws -> Void) {
    let before = failures
    pending = []
    do { try body() } catch {
        failures += 1
        pending.append("        threw \(error)")
    }
    print((failures == before ? "ok      " : "FAILED  ") + name)
    pending.forEach { print($0) }
}

/// The run's temporary folder, made by test.sh and removed by it afterwards.
let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DONEBOARD_TEST_DIR"]
                    ?? NSTemporaryDirectory(), isDirectory: true)

/// A board file in a new, empty folder of its own.
func freshFile(_ name: String) -> URL {
    let folder = scratch.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("board.json", isDirectory: false)
}

/// A store on a board file of its own, as one device with nothing shared.
func freshStore(_ name: String) -> (Store, URL) {
    let url = freshFile(name)
    return (Store(fileURL: url, watchForChanges: false), url)
}

/// What a device opening `url` would see.
func board(at url: URL) -> Store {
    Store(fileURL: url, watchForChanges: false)
}

/// This device's own copy of a shared board, which `DONEBOARD_DATA` puts in the scratch folder.
/// Every store in the run shares it, so a test of a shared board starts by clearing it.
let deviceCopy = Store.localFileURL()

func write(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

/// The file as plain JSON, for checking what is actually on disk.
func json(at url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

/// Lets a store on a shared file finish talking to it. Its exchanges run in the background and
/// report back on the main queue, which only drains while the main run loop turns.
@discardableResult
func settle(_ store: Store, within seconds: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    } while store.isExchanging && Date() < deadline
    return !store.isExchanging
}

/// Archive has no == of its own; the app never needs one.
func same(_ a: Archive, _ b: Archive) -> Bool {
    a.dailyGoal == b.dailyGoal && a.soundEnabled == b.soundEnabled && a.goalSound == b.goalSound
        && a.settingsUpdatedAt == b.settingsUpdatedAt
        && canonical(a.entries) == canonical(b.entries) && canonical(a.todos) == canonical(b.todos)
}

/// Records in the order a merge leaves them, so two lists can be compared whatever order they
/// arrived in.
func canonical<T: Mergeable & Hashable>(_ records: [T]) -> [T] {
    records.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
}

/// A Date on `day` at a given reading of the clock.
func time(_ hour: Int, _ minute: Int, on day: String) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: DayKey.date(day)!)!
}
