import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#endif

/// A record of what the app was doing, kept somewhere that outlives the app.
///
/// The failure worth planning for is a freeze on the phone. It ends with the system killing the
/// app, which takes everything in memory with it - including any idea of what the app was stuck
/// on. So every event goes to a file as it happens, written from a queue of its own rather than
/// from the thread being described, where a later launch can report it and `Tools/diagnose.sh`
/// can pull it off the device.
///
/// Nothing leaves the device on its own. The files sit in the app's container, and Settings can
/// share them.
enum Diagnostics {
    enum Category: String {
        case app, sync, store, hang, crash
    }

    /// `Library/Application Support/DoneBoardWorkspace/Diagnostics`, or beside the file `DONEBOARD_DATA`
    /// names, so a test pointed at a temporary board never writes into the real log.
    static let folder: URL = {
        let base = ProcessInfo.processInfo.environment["DONEBOARD_DATA"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .deletingLastPathComponent()
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DoneBoardWorkspace", isDirectory: true)
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Freeze and crash reports, one file each.
    static let reportsFolder: URL = {
        let dir = folder.appendingPathComponent("Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let sessionID = String(format: "%04x", UInt16.random(in: .min ... .max))

    /// How the run before this one ended, worked out at launch. Nil on a first launch.
    private(set) static var previousRun: String?

    /// Everything file-shaped happens here, in order. Never the main queue: the point is to still
    /// be writing while the main thread is stuck.
    private static let writer = DispatchQueue(label: "DoneBoard.diagnostics", qos: .utility)

    // MARK: - Events

    /// Records one event. Cheap, and safe from any thread.
    static func log(_ category: Category, _ message: String) {
        let when = Date()
        let thread = Thread.isMainThread ? "main" : "bg  "
        #if canImport(os)
        logger(category).log("\(message, privacy: .public)")
        #endif
        writer.async {
            events.append("\(stamp(when)) [\(sessionID)] \(thread) \(category.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n")
        }
    }

    /// Returns once everything logged so far is on disk - for the moment before the process ends.
    static func flush() {
        writer.sync {}
    }

    /// The event log, oldest file first.
    static var logFiles: [URL] { [events.previous, events.current] }

    private static let events = RollingFile(folder: folder, name: "events", limit: 1_000_000)

    #if canImport(os)
    private static let loggers: [Category: Logger] = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.example.doneboard"
        var made: [Category: Logger] = [:]
        for category in [Category.app, .sync, .store, .hang, .crash] {
            made[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return made
    }()

    private static func logger(_ category: Category) -> Logger { loggers[category]! }
    #endif

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Only called on `writer`, which is what makes sharing one formatter safe.
    private static func stamp(_ date: Date) -> String { stampFormat.string(from: date) }

    /// Seconds, the way a person reads a duration.
    static func seconds(_ interval: TimeInterval) -> String {
        interval < 10 ? String(format: "%.2fs", interval) : String(format: "%.0fs", interval)
    }

    // MARK: - Timing what might stall

    /// Something under way that could take as long as a network does. The watchdog reads these
    /// to say what a stuck thread was in the middle of.
    final class Activity {
        let category: Category
        let name: String
        let started = Date()
        let onMain = Thread.isMainThread
        #if canImport(Darwin)
        /// Borrowed, not retained: `pthread_mach_thread_np` adds no reference to release.
        let thread: mach_port_t = pthread_mach_thread_np(pthread_self())
        #endif

        init(_ category: Category, _ name: String) {
            self.category = category
            self.name = name
        }
    }

    private static let activityLock = NSLock()
    private static var activities: [ObjectIdentifier: Activity] = [:]

    static func begin(_ category: Category, _ name: String) -> Activity {
        let activity = Activity(category, name)
        activityLock.lock()
        activities[ObjectIdentifier(activity)] = activity
        activityLock.unlock()
        return activity
    }

    /// Ends an activity, logging it when it took longer than `threshold`.
    static func end(_ activity: Activity, reportOver threshold: TimeInterval = 0.5) {
        activityLock.lock()
        activities[ObjectIdentifier(activity)] = nil
        activityLock.unlock()
        let took = Date().timeIntervalSince(activity.started)
        if took >= threshold {
            log(activity.category, "\(activity.name) took \(seconds(took))")
        }
    }

    /// What is under way right now, longest-running first.
    static var inFlight: [Activity] {
        activityLock.lock()
        defer { activityLock.unlock() }
        return activities.values.sorted { $0.started < $1.started }
    }

    /// Runs `work` as an activity: visible to the watchdog while it runs, logged if it was slow.
    @discardableResult
    static func timed<T>(_ category: Category, _ name: String, reportOver threshold: TimeInterval = 0.5,
                         _ work: () throws -> T) rethrows -> T {
        let activity = begin(category, name)
        defer { end(activity, reportOver: threshold) }
        return try work()
    }

    // MARK: - Sessions

    /// What `session.json` holds: enough about the current run that the next launch can tell how
    /// it ended, which on a phone is otherwise invisible - the system closes apps without a word.
    private struct Session: Codable {
        var id: String
        var started: Date
        var build: String
        var state: String
        var stateAt: Date
        var frozenSince: Date?
        var frozenIn: String?
    }

    private static var session: Session?
    private static let sessionFile = folder.appendingPathComponent("session.json", isDirectory: false)

    /// First thing at launch: reads how the last run ended, then starts recording this one.
    static func startSession() {
        writer.sync {
            if let data = try? Data(contentsOf: sessionFile),
               let last = try? JSONDecoder.diagnostics.decode(Session.self, from: data) {
                previousRun = describe(last)
            }
            session = Session(id: sessionID, started: Date(), build: build, state: "launching", stateAt: Date())
            saveSession()
        }
        writer.async { pruneReports() }
        log(.app, "launch: DoneBoard \(build) on \(device)")
        if let previousRun { log(.app, "previous run: \(previousRun)") }
    }

    /// Records the app changing state - active, inactive, background, quit - whenever `name` is posted.
    static func follow(_ name: Notification.Name, as state: String) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            note(state: state)
        }
    }

    static func note(state: String) {
        log(.app, "state: \(state)")
        writer.async {
            session?.state = state
            session?.stateAt = Date()
            saveSession()
        }
        // A process about to end has no later moment to finish writing in.
        if state == "quit" { flush() }
    }

    /// Marks the main thread as frozen since `since`, in `activity`, or clears it with nil. Kept in
    /// the session file so a freeze the system ends by killing the app is still known next launch.
    static func noteFreeze(since: Date?, in activity: String?) {
        writer.async {
            session?.frozenSince = since
            session?.frozenIn = since == nil ? nil : activity
            if since != nil { session?.stateAt = Date() }
            saveSession()
        }
    }

    private static func saveSession() {
        guard let session, let data = try? JSONEncoder.diagnostics.encode(session) else { return }
        try? data.write(to: sessionFile, options: .atomic)
    }

    private static func describe(_ last: Session) -> String {
        let when = stamp(last.stateAt)
        if let since = last.frozenSince {
            let held = seconds(last.stateAt.timeIntervalSince(since))
            return "froze at \(stamp(since)) in \(last.frozenIn ?? "unknown work"), still frozen \(held) later, and never recovered (build \(last.build))"
        }
        switch last.state {
        case "quit":
            return "quit normally at \(when) (build \(last.build))"
        #if os(iOS)
        case "background":
            // Where every phone app ends up: the system closes it from here when it wants the memory.
            return "went to the background at \(when) and was closed from there (build \(last.build))"
        #endif
        default:
            return "ended unexpectedly - last \(last.state) at \(when); a crash, a force quit, or the system killing it (build \(last.build))"
        }
    }

    // MARK: - Where this is running

    static let build: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let number = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["DBGitCommit"] as? String
        return "\(version) (\(number))" + (commit.map { " commit \($0)" } ?? "")
    }()

    static let device: String = {
        #if canImport(Darwin)
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(key, &bytes, &size, nil, 0)
        let model = String(cString: bytes)
        #else
        let model = "unknown"
        #endif
        return "\(model), \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }()

    // MARK: - Reading it back

    /// The newest report - a freeze, a crash, slow work, or one from the system - by file name.
    static func latestReport() -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reportsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent != "crash-pending.txt" }
            .max { modified($0) < modified($1) }?
            .lastPathComponent
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// How many reports a device keeps. Nothing else ever removes one, and a phone syncing through
    /// a share that is often away writes a slow-work report most times it is - each only a few
    /// kilobytes, but every one also goes into the exported file.
    static let reportsKept = 50

    /// Removes all but the newest reports. Runs on `writer`, after launch has been recorded; a
    /// crash still waiting to be named is never touched.
    private static func pruneReports() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reportsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let reports = files.filter { $0.lastPathComponent != "crash-pending.txt" }
            .sorted { modified($0) > modified($1) }
        for old in reports.dropFirst(reportsKept) { try? FileManager.default.removeItem(at: old) }
    }

    /// Everything recorded, as one text file to hand over: how the last run ended, every report,
    /// the session file and the event log. Written to the temporary folder. Reads files, so keep
    /// it off the main thread.
    static func exportFile() -> URL {
        writer.sync {
            let now = stamp(Date())
            var text = "DoneBoard diagnostics, exported \(now)\n"
                + "build \(build)\ndevice \(device)\nsession \(sessionID)\n"
                + "previous run: \(previousRun ?? "none recorded")\n"
            let reports = (try? FileManager.default.contentsOfDirectory(at: reportsFolder, includingPropertiesForKeys: nil)) ?? []
            for file in reports.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                text += section(file.lastPathComponent, file)
            }
            text += section("session.json", sessionFile)
            for file in logFiles { text += section(file.lastPathComponent, file) }

            let name = "DoneBoard diagnostics " + now.replacingOccurrences(of: ":", with: ".") + ".txt"
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
            try? Data(text.utf8).write(to: out, options: .atomic)
            return out
        }
    }

    private static func section(_ title: String, _ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        // A runaway log shouldn't make a file too big to send; the end is the part that matters.
        return "\n===== \(title) =====\n" + String(decoding: data.suffix(2_000_000), as: UTF8.self) + "\n"
    }
}

/// A log that keeps its size bounded by rolling over to one previous file.
private final class RollingFile {
    let current: URL
    let previous: URL
    private let limit: Int
    private var handle: FileHandle?
    private var size = 0

    init(folder: URL, name: String, limit: Int) {
        current = folder.appendingPathComponent("\(name).log", isDirectory: false)
        previous = folder.appendingPathComponent("\(name).1.log", isDirectory: false)
        self.limit = limit
    }

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { open() }
        if size + data.count > limit { roll() }
        guard let handle else { return }
        handle.write(data)
        size += data.count
    }

    private func open() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: current.path) {
            manager.createFile(atPath: current.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: current)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func roll() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        open()
    }
}

/// With milliseconds. A freeze's length is worked out from two of these, and whole seconds made a
/// three-second freeze read as one.
private let preciseDates: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

extension JSONEncoder {
    static var diagnostics: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(preciseDates.string(from: date))
        }
        return e
    }
}

extension JSONDecoder {
    static var diagnostics: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = preciseDates.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return d
    }
}
