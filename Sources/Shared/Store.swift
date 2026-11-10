import Foundation
import Observation

/// Everything you have ever done, plus the settings that decide when to celebrate.
///
/// The file is the unit of sync: two devices pointed at the same one converge, because
/// every write merges with whatever is already on disk rather than overwriting it, and
/// deletions are tombstones rather than absences. Nothing here knows how the file gets
/// between machines - that is iCloud Drive's or Dropbox's problem, not this type's.
@Observable
final class Store {
    /// Every record, tombstones included. This is what gets written.
    private(set) var records: [Entry] = []
    /// Live entry count per day key. Only days with entries appear.
    private(set) var countsByDay: [String: Int] = [:]
    /// Planned work, tombstones included.
    private(set) var todos: [Todo] = []

    private var goalStorage = Archive.defaultGoal
    private var soundStorage = true
    private var soundChoice = ChimeSound.fallback
    private var settingsStamp = Date.distantPast

    @ObservationIgnored private var directoryWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var clock = HybridClock()

    /// Set when a write could not be completed, so the interface can say so rather
    /// than letting the board quietly stop being saved.
    private(set) var syncProblem: String?

    /// Number of entries in a day that counts as a win. Fireworks when you cross it.
    var dailyGoal: Int {
        get { goalStorage }
        set {
            let clamped = min(max(newValue, 1), 99)
            guard clamped != goalStorage else { return }
            goalStorage = clamped
            settingsStamp = clock.now()
            save("setting the daily goal to \(clamped)")
        }
    }

    var soundEnabled: Bool {
        get { soundStorage }
        set {
            guard newValue != soundStorage else { return }
            soundStorage = newValue
            settingsStamp = clock.now()
            save("turning the sound \(newValue ? "on" : "off")")
        }
    }

    /// Which sound a celebration makes. Travels with the other settings.
    var goalSound: ChimeSound {
        get { soundChoice }
        set {
            guard newValue != soundChoice else { return }
            soundChoice = newValue
            settingsStamp = clock.now()
            save("choosing a sound")
        }
    }

    private(set) var fileURL: URL

    /// This device's own copy of a shared board, kept beside it - see `keepsLocalCopy`.
    /// Nil when the store's file already is the local one, or no copy was asked for.
    @ObservationIgnored private var localCopy: URL? = nil
    private let keepsLocalCopy: Bool

    /// `keepsLocalCopy` is for the apps, and off in tests. A shared file can disappear from
    /// under a running app - a phone leaving the Wi-Fi a Mac's share is on - and without a
    /// copy on the device, anything added until it came back lived only in memory: gone if
    /// the system closed the app first. A reopened app showed an empty board as well, since
    /// the only file it could read was one that syncing never updated.
    init(fileURL: URL? = nil, keepsLocalCopy: Bool = false, watchForChanges: Bool = true) {
        let file = fileURL ?? Store.localFileURL()
        self.fileURL = file
        self.keepsLocalCopy = keepsLocalCopy
        localCopy = Store.localCopy(for: file, enabled: keepsLocalCopy)
        load()
        if watchForChanges { startWatching() }
    }

    deinit {
        reloadWork?.cancel()
        retryWork?.cancel()
        slowWork?.cancel()
        checkInTimer?.invalidate()
        directoryWatcher?.cancel()
        fileWatcher?.cancel()
    }

    // MARK: - Reading

    /// A day's entries, latest first by the time each one shows. Tombstones never appear.
    ///
    /// Sorted on the clock reading rather than the full timestamp, because a thing logged
    /// after the fact is stamped with the date it was typed in, and sorting on that would
    /// put an entry set to 11pm below one set to 9am that was written down a day later.
    func entries(on day: String) -> [Entry] {
        records.filter { $0.day == day && !$0.isDeleted }
            .sorted {
                let a = DayKey.clockSeconds($0.createdAt), b = DayKey.clockSeconds($1.createdAt)
                return a != b ? a > b : $0.createdAt > $1.createdAt
            }
    }

    func count(on day: String) -> Int { countsByDay[day] ?? 0 }

    func metGoal(on day: String) -> Bool { count(on: day) >= dailyGoal }

    /// Entries logged in the month containing `date`.
    func monthTotal(_ date: Date) -> Int {
        let prefix = DayKey.monthPrefix(date)
        return countsByDay.reduce(0) { $1.key.hasPrefix(prefix) ? $0 + $1.value : $0 }
    }

    /// The busiest day in the month containing `date`.
    func monthBest(_ date: Date) -> Int {
        let prefix = DayKey.monthPrefix(date)
        return countsByDay.reduce(0) { $1.key.hasPrefix(prefix) ? max($0, $1.value) : $0 }
    }

    var allTimeTotal: Int { records.lazy.filter { !$0.isDeleted }.count }

    /// The to-do list, newest first - matching the board, and putting whatever you just
    /// typed directly under the field you typed it into.
    ///
    /// The id breaks ties. Two rows can only share a creation time if they were made on
    /// separate devices in the same instant, and an arbitrary-but-identical answer on
    /// both beats a list that shuffles depending on which device you are looking at.
    var openTodos: [Todo] {
        todos.filter { !$0.isDeleted }.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt > $1.createdAt
        }
    }

    // MARK: - Writing

    /// Puts a new task up on the board. Returns the celebration it earned, if any.
    @discardableResult
    func add(_ rawText: String, to day: String) -> Celebration? {
        append(rawText, to: day, doing: "adding an entry to")
    }

    /// The write behind `add` and `complete`. `doing` names the change in the log.
    @discardableResult
    private func append(_ rawText: String, to day: String, doing: String) -> Celebration? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let before = count(on: day)
        records.append(Entry(text: text, day: day, updatedAt: clock.now()))
        reindex()
        save("\(doing) \(day), \(before + 1) there now")

        let after = before + 1
        if before < dailyGoal, after >= dailyGoal {
            return .goalReached(count: after)
        } else if dailyGoal >= 2, after > dailyGoal, after % dailyGoal == 0 {
            return .encore(count: after)
        }
        return nil
    }

    /// Rewrites an entry's text and, when `time` is given, the time of day it was done.
    ///
    /// The time lands on the entry's own day - changing which day is `move`'s job - and
    /// never later than now. A time whose hour and minute already match is no change,
    /// so opening the editor and closing it again stamps nothing that would win a merge.
    func update(_ entry: Entry, text: String, time: Date? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(of: entry) else { return }

        var changed = false
        if records[i].text != trimmed {
            records[i].text = trimmed
            changed = true
        }
        if let time, let retimed = Store.retimed(records[i], to: time) {
            records[i].createdAt = retimed
            changed = true
        }
        guard changed else { return }
        records[i].updatedAt = clock.now()
        save("editing an entry")
    }

    private static func retimed(_ entry: Entry, to time: Date) -> Date? {
        let calendar = Calendar.current
        guard calendar.dateComponents([.hour, .minute], from: time)
                != calendar.dateComponents([.hour, .minute], from: entry.createdAt),
              let placed = DayKey.at(time, on: entry.day) else { return nil }
        return min(placed, Date())
    }

    /// Moves an entry to another day, carrying its clock time with it so it still
    /// reads as the hour you did the thing. Refuses to move anything into the future.
    func move(_ entry: Entry, to day: String) {
        guard !DayKey.isFuture(day),
              let i = index(of: entry),
              records[i].day != day,
              let from = DayKey.date(records[i].day),
              let to = DayKey.date(day) else { return }

        let shift = Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
        records[i].day = day
        if let moved = Calendar.current.date(byAdding: .day, value: shift, to: records[i].createdAt) {
            records[i].createdAt = moved
        }
        records[i].updatedAt = clock.now()
        reindex()
        save("moving an entry to \(day)")
    }

    /// Leaves a tombstone rather than removing the row. See `Entry`.
    func delete(_ entry: Entry) {
        guard let i = index(of: entry), !records[i].isDeleted else { return }
        let now = clock.now()
        records[i].deletedAt = now
        records[i].updatedAt = now
        reindex()
        save("deleting an entry from \(records[i].day)")
    }

    // MARK: - Planned work

    func addTodo(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Created on the clock's stamp rather than the bare time: the file keeps milliseconds,
        // and two added within one of them would otherwise come back in either order.
        let now = clock.now()
        todos.append(Todo(text: text, createdAt: now, updatedAt: now))
        save("adding a to-do")
    }

    func updateTodo(_ todo: Todo, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = todoIndex(of: todo) else { return }
        guard todos[i].text != trimmed else { return }
        todos[i].text = trimmed
        todos[i].updatedAt = clock.now()
        save("editing a to-do")
    }

    /// Drops a to-do without doing it.
    func removeTodo(_ todo: Todo) {
        guard let i = todoIndex(of: todo), !todos[i].isDeleted else { return }
        let now = clock.now()
        todos[i].deletedAt = now
        todos[i].updatedAt = now
        save("dropping a to-do")
    }

    /// Checks a to-do off: it leaves the list and lands on the board as something you
    /// did. This is the only bridge between the two, and it only runs in this direction.
    /// Returns the celebration the entry earned, if any.
    @discardableResult
    func complete(_ todo: Todo, on day: String) -> Celebration? {
        guard let i = todoIndex(of: todo), !todos[i].isDeleted else { return nil }
        let text = todos[i].text
        let earned = append(text, to: day, doing: "checking off a to-do onto")

        // `append` saved on the way through, and every save merges with the file and
        // adopts the result - so `todos` has been replaced and `i` may no longer point
        // at this row. Find it again rather than tombstoning whatever landed there.
        guard let row = todoIndex(of: todo) else { return earned }
        let now = clock.now()
        todos[row].deletedAt = now
        todos[row].updatedAt = now
        save()
        return earned
    }

    private func todoIndex(of todo: Todo) -> Int? {
        todos.firstIndex { $0.id == todo.id }
    }

    private func index(of entry: Entry) -> Int? {
        records.firstIndex { $0.id == entry.id }
    }

    private func reindex() {
        var counts: [String: Int] = [:]
        for entry in records where !entry.isDeleted { counts[entry.day, default: 0] += 1 }
        countsByDay = counts
    }

    // MARK: - Disk

    /// This device's own copy, used when no shared folder has been picked.
    /// `DONEBOARD_DATA` overrides it, which is handy on a Mac and for tests.
    static func localFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["DONEBOARD_DATA"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return url
        }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DoneBoardWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("doneboard.json", isDirectory: false)
    }

    // Timestamps decide every merge, so they are written with milliseconds. Foundation's
    // stock .iso8601 strategy truncates to whole seconds, which would make two edits in
    // the same second indistinguishable and hand the decision to a tiebreak instead of
    // to the clock. Reading still accepts the second-resolution form that v1 files used.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // Each timestamp is parsed, and each date formatted, once. The formatters take tens of
    // microseconds a time and every read of the file brings back the same few thousand stamps -
    // on a board three years old that was 430ms of the 520ms a single tap spent saving, all on
    // the main thread. The same formatters still do every conversion the first time, so every
    // date read and every byte written is exactly what it was.
    private static let datesRead = Memo<String, Date?>()
    private static let datesWritten = Memo<Date, String>()

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = datesRead.value(for: text, { isoFractional.date(from: $0) ?? isoWhole.date(from: $0) }) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(datesWritten.value(for: date) { isoFractional.string(from: $0) })
        }
        return e
    }

    /// What came back from trying to read the file. The difference between "there is
    /// no file" and "there is a file I could not read" matters enormously: the first
    /// means write ours, and the second must never lead to a write, because the most
    /// likely cause is an iCloud file that has not finished arriving. Overwriting one
    /// of those replaces the other device's board with this one's.
    private enum ReadOutcome {
        case ok(Archive)
        case absent
        /// Carries whatever the system said, when it said anything - the only way to tell
        /// a file still arriving from one this device isn't able to open.
        case unavailable(Error?)
        case corrupt(Data)
    }

    /// Coordinated, because a file in iCloud Drive has a second writer - the sync
    /// daemon - and an uncoordinated read can catch it half-replaced.
    ///
    /// Never call this from inside a coordination block for the same file: a second
    /// coordinator waiting on access the first one already holds deadlocks outright.
    /// Code already inside a block holds exclusive access and wants `parse` instead.
    ///
    /// Never call it on the main thread either. On the phone a coordinated call waits behind
    /// whatever coordination the app still has out, whatever file that is for - on 2026-10-27 a
    /// read of this device's own copy sat 20 seconds behind an exchange with a share that wasn't
    /// answering. A Mac doesn't do this with its own files, so no test here can show it.
    private static func read(_ url: URL) -> ReadOutcome {
        var outcome = ReadOutcome.unavailable(nil)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { actual in
            outcome = parse(actual)
        }
        // Coordination that fails never runs the block, so without this the reason was
        // dropped and the read merely looked unavailable.
        if let coordinationError { return .unavailable(coordinationError) }
        return outcome
    }

    /// Whether a file read and written in place - on the main thread - is coordinated. Only when
    /// `DONEBOARD_DATA` names it, since a Mac can point that into iCloud Drive and its sync daemon.
    /// Otherwise the file in place is this device's own, in the app's own folder, and nothing else
    /// ever writes it. Settable so the tests, which do set `DONEBOARD_DATA`, can run their in-place
    /// checks the way the apps do too.
    static var coordinatesInPlace =
        !(ProcessInfo.processInfo.environment["DONEBOARD_DATA"] ?? "").isEmpty

    private static func readInPlace(_ url: URL) -> ReadOutcome {
        coordinatesInPlace ? read(url) : parse(url)
    }

    /// The same read without coordination, for callers that already hold access.
    private static func parse(_ url: URL) -> ReadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else {
                // A placeholder for a file iCloud hasn't pulled down yet looks like
                // nothing being there at all. Ask for it, and treat this attempt as
                // unavailable rather than as an empty board.
                if requestDownload(url) { return .unavailable(error) }
                return .absent
            }
            return .unavailable(error)
        }

        if let archive = try? decoder().decode(Archive.self, from: data) { return .ok(archive) }
        return .corrupt(data)
    }

    /// True if the path turned out to be an iCloud item that simply isn't local yet.
    private static func requestDownload(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud", isDirectory: false)
        guard FileManager.default.fileExists(atPath: placeholder.path) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }

    /// An error as a person can read it, with its domain and code kept on the end. The
    /// description alone is often just "The file couldn't be opened", which says nothing
    /// about why.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        // The outer error is often a generic Cocoa one. The system call's own error underneath is
        // what tells a refused rename from a missing folder.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    /// The local copy to keep for `url`, if one is wanted and `url` isn't already it.
    private static func localCopy(for url: URL, enabled: Bool) -> URL? {
        let local = localFileURL()
        guard enabled, !samePlace(url, local) else { return nil }
        return local
    }

    /// Whether two file URLs name the same file, decided from their text alone.
    ///
    /// `standardizedFileURL` asks the file system - a `stat` of the path - and asked of a share
    /// that wasn't answering, on the main thread, it froze the phone in `relocate` twice in
    /// October. These URLs come from the system and from bookmarks, never typed, so the only way
    /// one file gets two spellings is the `/private` that `/var` and `/tmp` stand in for.
    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        spelling(a) == spelling(b)
    }

    private static func spelling(_ url: URL) -> [Substring] {
        var parts: [Substring] = []
        for part in url.path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        if parts.count > 1, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) {
            parts.removeFirst()
        }
        return parts
    }

    /// Mirrors the board into this device's own copy, merged with what the copy already
    /// holds - nothing else writes it, but a merge costs nothing and can't lose a row.
    /// True when there is a copy and it was written.
    @discardableResult
    private func keepLocalCopy() -> Bool {
        guard let localCopy else { return false }
        var board = snapshot()
        // Read directly, never coordinated: nothing else writes this file, and a coordinated read
        // waits behind any coordination still out on the shared one. On 2026-10-27 that held the
        // main thread for 20 seconds - a to-do added while the Mac sharing the folder was out of
        // reach, its exchange waiting 30 seconds for the network to give up.
        if case .ok(let held) = Store.parse(localCopy) { board = Archive.merged(board, held) }
        guard let data = try? Store.encoder().encode(board) else { return false }
        do {
            try data.write(to: localCopy, options: .atomic)
            return true
        } catch {
            Diagnostics.log(.store, "couldn't write this device's copy: \(Store.describe(error))")
            return false
        }
    }

    /// Whether two boards would be written differently - the test for "we hold something
    /// the file doesn't". False when either can't be encoded, so a failure never writes.
    private static func differ(_ a: Archive, _ b: Archive) -> Bool {
        guard let x = try? encoder().encode(a), let y = try? encoder().encode(b) else { return false }
        return x != y
    }

    /// Keeps the bytes of a file we could not parse, without moving the file itself.
    /// Moving it would be fine for a private copy and disastrous for a shared one -
    /// the other devices would watch their board vanish.
    private static func setAside(_ data: Data, from url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? data.write(to: backup)
        Diagnostics.log(.store, "\(url.path) couldn't be parsed; its bytes are kept in \(backup.lastPathComponent)")
    }

    private func snapshot() -> Archive {
        Archive(dailyGoal: goalStorage, soundEnabled: soundStorage, goalSound: soundChoice,
                settingsUpdatedAt: settingsStamp, entries: records, todos: todos)
    }

    private func adopt(_ archive: Archive) {
        // Anything we have now seen has to outrank anything we write next.
        clock.observe(archive)
        records = archive.entries
        todos = archive.todos
        goalStorage = min(max(archive.dailyGoal, 1), 99)
        soundStorage = archive.soundEnabled
        soundChoice = archive.goalSound
        settingsStamp = archive.settingsUpdatedAt
        reindex()
    }

    /// Folds a board read from a file into what is held now, which may have moved on while the
    /// file was being read. True when that changed anything.
    @discardableResult
    private func absorb(_ board: Archive) -> Bool {
        let current = snapshot()
        let combined = Archive.merged(current, board)
        guard Store.differ(combined, current) else {
            clock.observe(board)
            return false
        }
        adopt(combined)
        return true
    }

    /// Whether the file is shared - somewhere another device writes too, reached however slowly
    /// the network allows. Only a shared file has a device copy kept beside it, and only a shared
    /// file is read and written in the background. This device's own file is quick, so it is
    /// read and written where it is, and a test's store with no copy behaves the same way.
    private var isShared: Bool { localCopy != nil }

    /// True while the shared file is being read or written, or another exchange is waiting to go.
    /// For tests, which have to wait for the background to finish before checking what it did.
    var isExchanging: Bool { inFlight == generation || exchangeWanted }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "DoneBoard.store-io", qos: .userInitiated)
    }

    private func load() {
        guard let localCopy else {
            loadInPlace()
            return
        }
        // A shared file can take as long to read as the network takes to give up. Show this
        // device's copy now, and let the exchange bring in the rest when it can.
        if case .ok(let copy) = Store.parse(localCopy) { adopt(copy) }
        Diagnostics.log(.store, "opened \(records.count) records from this device's copy; the shared file follows")
        exchange("opening the board")
    }

    private func loadInPlace() {
        switch Store.readInPlace(fileURL) {
        case .ok(let archive):
            adopt(archive)
            Diagnostics.log(.store, "opened \(records.count) records from \(fileURL.path)")
        case .corrupt(let data):
            Store.setAside(data, from: fileURL)
            syncProblem = "The saved file couldn't be read. A copy of it is kept alongside."
        case .absent:
            Diagnostics.log(.store, "no board yet at \(fileURL.path)")
        case .unavailable(let error):
            Diagnostics.log(.store, "can't read \(fileURL.path): \(error.map(Store.describe) ?? "no reason given")")
        }
    }

    /// Writes, but never blindly: every write merges with whatever the file already holds.
    ///
    /// This device's own file is written here and now. For a shared file, this device's copy is
    /// written here and now - that is what makes the change safe - and the shared file follows
    /// in the background, however long the network takes.
    ///
    /// `change` goes in the log, saying what the save is for, before anything is written - so a
    /// save that never returns still says what it was doing, and an exchange's own line says what
    /// sent it. Left out for a second save in the same change, and for saves no one asked for.
    func save(_ change: String? = nil) {
        if let change { Diagnostics.log(.store, change) }
        if isShared {
            keepLocalCopy()
            exchange(change ?? "a change on this device")
        } else {
            saveInPlace()
        }
    }

    private func saveInPlace() {
        let outcome = Diagnostics.timed(.store, "saving \(fileURL.lastPathComponent)", reportOver: 0.25) {
            Store.coordinatesInPlace ? Store.write(snapshot(), to: fileURL) : Store.merge(snapshot(), into: fileURL)
        }
        if let board = outcome.board { adopt(board) }
        syncProblem = outcome.problem
        lastWriteFailed = outcome.problem != nil
        if let problem = outcome.problem {
            Diagnostics.log(.store, "save to \(fileURL.path) failed: \(problem)")
            scheduleRetry()
        } else {
            retryDelay = 0
        }
    }

    /// What an attempt on a file came to.
    private struct Outcome {
        /// What the file and the board sent now hold between them. Nil when the file couldn't be
        /// read, in which case nothing was written.
        var board: Archive?
        var problem: String?
        var wrote = false
    }

    /// Merges `mine` into the file and writes the result, unless the file already holds it. The
    /// read, the merge and the write all happen inside a single coordinated block, so another
    /// process cannot slip a write in between our reading the file and our replacing it - which
    /// would have silently dropped whatever it wrote. Touches nothing but the file, so it is safe
    /// from any thread.
    private static func write(_ mine: Archive, to url: URL) -> Outcome {
        var outcome = Outcome()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [],
                                       error: &coordinationError) { actual in
            outcome = merge(mine, into: actual)
        }
        if let coordinationError {
            outcome.problem = outcome.problem ?? "Couldn't reach the file: \(describe(coordinationError))"
        }
        return outcome
    }

    /// The read, the merge and the write themselves, for a caller that already holds access -
    /// `write`, inside its block, or a save in place to a file nothing else writes.
    private static func merge(_ mine: Archive, into url: URL) -> Outcome {
        var outcome = Outcome()
        var combined = mine
        var onDisk: Archive?

        switch parse(url) {
        case .ok(let held):
            onDisk = held
            combined = Archive.merged(mine, held)
        case .corrupt(let data):
            setAside(data, from: url)
            outcome.problem = "The saved file couldn't be read. A copy of it is kept alongside."
        case .absent:
            break
        case .unavailable(let error):
            // The file is there but unreadable - still arriving from a sync service, or
            // not openable from here. Writing now would replace it with a board that
            // has never seen its contents. Leave it alone, try again shortly, and say
            // why, since the retries are otherwise silent.
            outcome.problem = "Can't read the shared file yet"
                + (error.map { ": " + describe($0) } ?? ".")
            return outcome
        }

        outcome.board = combined
        guard let data = try? encoder().encode(combined) else {
            outcome.problem = "The board couldn't be encoded."
            return outcome
        }
        // Nothing new for the file. Leaving it alone is what stops two devices watching
        // each other from writing in circles. The same test as `differ`, reusing the bytes
        // about to be written rather than encoding the board a third time.
        if let onDisk, (try? encoder().encode(onDisk)) == data { return outcome }
        do {
            try data.write(to: url, options: .atomic)
            outcome.wrote = true
        } catch {
            outcome.problem = "Couldn't save: \(describe(error))"
        }
        return outcome
    }

    // MARK: - The shared file, in the background

    /// Where a shared file is read and written - never the main thread, which is what used to
    /// wait there until the system killed the app. A new queue for each file, so a read still
    /// stuck on a share that went away can't hold up the next folder.
    @ObservationIgnored private var io = Store.makeQueue()
    /// Bumped whenever the store moves, so an exchange that returns after a move is recognised:
    /// its board still counts, but its news about the old file isn't news about the new one.
    @ObservationIgnored private var generation = 0
    /// The generation of the exchange that is out right now, if any.
    @ObservationIgnored private var inFlight: Int?
    /// Asked for while one was out. One more goes when it returns, however many piled up - a
    /// single exchange carries every change made before it starts.
    @ObservationIgnored private var exchangeWanted = false
    @ObservationIgnored private var slowWork: DispatchWorkItem?
    @ObservationIgnored private var retryDelay: TimeInterval = 0
    /// Whether the last write - an exchange, or a save to this device's own file - failed. While it
    /// did, what the watcher reports is left to the retry; see `fileChanged`.
    @ObservationIgnored private var lastWriteFailed = false
    /// The watcher reported a change while an exchange was out, to be looked at once it returns.
    @ObservationIgnored private var changedDuringExchange = false
    @ObservationIgnored private var checkInTimer: Timer?

    /// Asks the system for time to finish an exchange, and returns how to say it has finished. The
    /// apps point it at the platform's own - on a phone, the half minute or so iOS allows an app
    /// that has just been left. Unset, it does nothing, which is what tests want.
    static var keepRunning: (String) -> () -> Void = { _ in {} }

    /// Brings this board and the shared file together: reads the file, merges, and writes back
    /// whatever it is missing, all on `io`.
    private func exchange(_ reason: String) {
        guard inFlight != generation else {
            exchangeWanted = true
            return
        }
        inFlight = generation
        exchangeWanted = false
        retryWork?.cancel()
        retryWork = nil

        let url = fileURL, mine = snapshot(), token = generation, started = Date()

        // A share that doesn't answer doesn't fail either; it just doesn't answer. Say so,
        // rather than showing nothing while the exchange waits.
        slowWork?.cancel()
        let slow = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation, self.inFlight == token else { return }
            self.syncProblem = "Still waiting on the shared folder. Everything is saved on this device meanwhile."
            Diagnostics.log(.store, "exchange with \(url.path), for \(reason), still waiting after 8s")
        }
        slowWork = slow
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: slow)

        // Held until the exchange returns, so leaving the app doesn't suspend it partway.
        let release = Store.keepRunning("Syncing the board")
        io.async { [weak self] in
            // Timed so the watchdog can see it running; `finishExchange` logs how it went.
            let outcome = Diagnostics.timed(.store, "exchange with \(url.lastPathComponent)", reportOver: .infinity) {
                Store.exchange(mine, with: url)
            }
            DispatchQueue.main.async {
                self?.finishExchange(outcome, token: token, url: url, started: started, reason: reason)
                release()
            }
        }
    }

    /// Runs on `io`. A read first, and a coordinated write only when the file is missing
    /// something - most exchanges are the app coming to the front with nothing new either side.
    private static func exchange(_ mine: Archive, with url: URL) -> Outcome {
        // Joining a folder is the first exchange with it, and it may never have been used.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if case .ok(let onDisk) = read(url) {
            let combined = Archive.merged(mine, onDisk)
            if !differ(combined, onDisk) { return Outcome(board: combined) }
        }
        return write(mine, to: url)
    }

    private func finishExchange(_ outcome: Outcome, token: Int, url: URL, started: Date, reason: String) {
        guard token == generation else {
            // The store moved while this was out. What it read is still the board, so keep it.
            if let board = outcome.board, absorb(board) { save() }
            Diagnostics.log(.store, "an exchange with \(url.path) returned after the store moved on")
            return
        }
        inFlight = nil
        slowWork?.cancel()
        slowWork = nil

        let brought = outcome.board.map { absorb($0) } ?? false
        if brought { keepLocalCopy() }
        let took = Diagnostics.seconds(Date().timeIntervalSince(started))
        let changed = changedDuringExchange
        changedDuringExchange = false
        lastWriteFailed = outcome.problem != nil
        if let problem = outcome.problem {
            syncProblem = "Saved on this device, and it syncs once the shared file is back. \(problem)"
            Diagnostics.log(.store, "exchange with \(url.path) failed after \(took), for \(reason): \(problem)")
            scheduleRetry()
        } else {
            syncProblem = nil
            retryDelay = 0
            // Every one, quick or not - a log that only mentions slow exchanges can't tell a quick one
            // from one that never came back. Check-ins that find nothing are the exception: there is
            // one every half minute.
            if reason != Store.checkingIn || outcome.wrote || brought {
                Diagnostics.log(.store, "exchange with \(url.lastPathComponent) took \(took), for \(reason): "
                    + (outcome.wrote ? "wrote the file" : "the file already had everything")
                    + (brought ? ", and brought changes to this device" : ""))
            }
        }
        // The file we were watching may have been replaced out from under us.
        if directoryWatcher != nil { watchFile() }
        if exchangeWanted {
            exchange("changes made while the last one was out")
        } else if changed, !lastWriteFailed {
            exchange("the file changing")
        }
    }

    /// A save that had to be abandoned is worth another attempt - the file may only have been
    /// mid-download, or the Mac sharing it just waking. The wait doubles up to a minute, so a
    /// folder that is gone for the afternoon isn't knocked on every five seconds.
    private func scheduleRetry() {
        retryWork?.cancel()
        retryDelay = min(max(retryDelay * 2, 5), 60)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isShared { self.exchange("trying again") } else { self.saveInPlace() }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    /// The app is being left. A change still waiting to reach the shared file - a failed exchange
    /// sitting out its delay before trying again - goes now, while the system still allows the
    /// time; a suspended app's timers don't fire. An exchange already out holds that time itself.
    func sendBeforeLeaving() {
        guard isShared, inFlight != generation, retryWork != nil else { return }
        exchange("leaving the app")
    }

    /// Looks at the shared file for another device's changes. Nothing reliably tells a phone that a
    /// Mac wrote to a share - the watcher can't be counted on through one - so the apps do this every
    /// half minute while in front. While writes are failing, the retry is already on its way.
    func checkIn() {
        guard isShared, inFlight != generation, !lastWriteFailed else { return }
        exchange(Store.checkingIn)
    }

    func startCheckingIn(every interval: TimeInterval = 30) {
        checkInTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.checkIn() }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        checkInTimer = timer
    }

    func stopCheckingIn() {
        checkInTimer?.invalidate()
        checkInTimer = nil
    }

    private static let checkingIn = "checking in"

    /// Points the store at a different file - a saved folder turning up, the user picking one,
    /// or giving one up - folding whatever is already there into what we hold.
    ///
    /// Nothing is lost in either direction: entries only on this device get written
    /// out, and entries already in the target are adopted. It is the same merge two
    /// devices use every day, so joining a folder is simply the first exchange.
    func relocate(to url: URL) {
        guard !Store.samePlace(url, fileURL) else { return }
        Diagnostics.log(.store, "moving from \(fileURL.path) to \(url.path)")
        stopWatching()
        retryWork?.cancel()
        slowWork?.cancel()
        syncProblem = nil
        retryDelay = 0
        generation += 1
        io = Store.makeQueue()
        exchangeWanted = false
        changedDuringExchange = false
        lastWriteFailed = false

        fileURL = url
        localCopy = Store.localCopy(for: url, enabled: keepsLocalCopy)
        if isShared {
            // Everything held so far goes into this device's copy before anything else, so it is
            // safe whatever the folder does. The exchange carries it across.
            keepLocalCopy()
            exchange("joining the folder")
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if case .ok(let target) = Store.readInPlace(url) { adopt(Archive.merged(snapshot(), target)) }
            saveInPlace()
        }
        startWatching()
    }

    /// Folds whatever is on disk into memory. Call it on any hint another device wrote -
    /// the app coming to the front, or the file changing underneath us.
    func reload(_ reason: String = "coming to the front") {
        guard !isShared else {
            exchange(reason)
            return
        }
        guard case .ok(let onDisk) = Store.readInPlace(fileURL) else { return }
        let combined = Archive.merged(snapshot(), onDisk)
        adopt(combined)
        syncProblem = nil
        // Write back only when we hold something the file doesn't. Otherwise two
        // devices watching each other would write in circles forever.
        if Store.differ(combined, onDisk) { saveInPlace() }
        // The file we were watching may have been replaced out from under us.
        if directoryWatcher != nil { watchFile() }
    }

    // MARK: - Noticing the other device

    /// Two watches, because the two ways a file can change look nothing alike to the
    /// kernel. A sync daemon - and our own atomic save - *replaces* the file, which is
    /// a change to the directory and not to the inode we were holding. A writer that
    /// edits in place is the exact reverse: the directory never changes at all.
    /// Watching only one of them misses half the ways the other device can reach us.
    private func startWatching() {
        watchDirectory()
        watchFile()
    }

    private func stopWatching() {
        reloadWork?.cancel()
        reloadWork = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private func watchDirectory() {
        watch(fileURL.deletingLastPathComponent().path, [.write, .rename, .delete, .attrib]) { store, source in
            store.directoryWatcher?.cancel()
            store.directoryWatcher = source
        }
    }

    /// Re-established after every reload: once the file has been replaced, this
    /// descriptor refers to an inode nobody is going to write to again.
    private func watchFile() {
        watch(fileURL.path, [.write, .extend, .rename, .delete]) { store, source in
            store.fileWatcher?.cancel()
            store.fileWatcher = source
        }
    }

    /// Opens `path` for events and hands the watch to `install` on the main thread. A shared
    /// file's path is opened on `io`, because opening anything on a share waits on the network.
    private func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                       _ install: @escaping (Store, DispatchSourceFileSystemObject) -> Void) {
        guard isShared else {
            let descriptor = open(path, O_EVTONLY)
            if descriptor >= 0 { install(self, makeSource(descriptor, mask)) }
            return
        }
        let token = generation
        io.async { [weak self] in
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            DispatchQueue.main.async {
                guard let self, token == self.generation else {
                    Store.closeOffMain(descriptor)
                    return
                }
                install(self, self.makeSource(descriptor, mask, onShare: true))
            }
        }
    }

    private func makeSource(_ descriptor: Int32, _ mask: DispatchSource.FileSystemEvent,
                            onShare: Bool = false) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler {
            if onShare { Store.closeOffMain(descriptor) } else { close(descriptor) }
        }
        source.resume()
        return source
    }

    /// Closing a descriptor on a share is a call on the share like opening one, and one that has
    /// gone away can keep any call waiting - so it is made where waiting freezes nothing.
    private static func closeOffMain(_ descriptor: Int32) {
        DispatchQueue.global(qos: .utility).async { close(descriptor) }
    }

    /// The watcher saw the file or its folder change. Usually that is another device - but a write of
    /// this store's own changes the folder too, failed ones included, since an atomic write makes and
    /// removes a temporary file beside the target. Answering that at once is a loop: on a share that
    /// was refusing writes, the phone tried again every 0.65s, 71 times. So after a failed write the
    /// news is left to the retry, and news that arrives mid-exchange waits for it to return.
    private func fileChanged() {
        guard !lastWriteFailed else { return }
        if isShared, inFlight == generation {
            changedDuringExchange = true
            return
        }
        reload("the file changing")
    }

    /// A single sync update can fire a burst of events, so settle before reading.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fileChanged() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// Cross-window UI state: which day the board is showing, and anything a menu item
/// or the settings window needs to reach into the main window to do.
@Observable
final class AppState {
    /// Today's key, in one place so every view agrees on it.
    var today: String { DayKey.today }

    var selectedDay: String = DayKey.today
    /// Bumped to pull keyboard focus back to the entry field.
    var focusTick = 0
    /// Set to ask the main window to run a celebration.
    var pendingCelebration: CelebrationRequest?

    func isFuture(_ day: String) -> Bool { day > today }

    func show(_ day: String) {
        guard !isFuture(day) else { return }
        selectedDay = day
    }

    func celebrate(_ kind: Celebration) {
        switch kind {
        case .goalReached(let count): Diagnostics.log(.app, "celebrating the goal, \(count) on the board")
        case .encore(let count): Diagnostics.log(.app, "celebrating an encore, \(count) on the board")
        }
        pendingCelebration = CelebrationRequest(kind: kind)
    }
}

/// What a slow conversion gave for each input it has already seen. Safe from any queue: the
/// store reads on its own queue and the main thread at once. The conversion itself runs outside
/// the lock, so two queues meeting here never wait on each other's work.
final class Memo<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    func value(for key: Key, _ make: (Key) -> Value) -> Value {
        lock.lock()
        let known = values[key]
        lock.unlock()
        if let known { return known }
        let made = make(key)
        lock.lock()
        // Only what this run has read and written is in here, a few stamps per record. The cap
        // is a backstop for an app left open for months, far beyond any real board.
        if values.count >= 200_000 { values.removeAll() }
        values[key] = made
        lock.unlock()
        return made
    }
}
