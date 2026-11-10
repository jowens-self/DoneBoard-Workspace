import Foundation

// This file, Store.swift, and the JSON format they define are deliberately free of any
// UI or platform imports. They are the parts an iOS or Windows client would reuse as-is.

/// One thing you actually did.
///
/// A record is never removed from the archive - deleting sets `deletedAt` and leaves
/// the row behind as a tombstone. That is what makes two copies of the file mergeable:
/// without it, "this device deleted B" and "this device has not seen B yet" look
/// identical, and a merge has no choice but to resurrect everything ever deleted.
struct Entry: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date
    /// The day this counts toward, as "yyyy-MM-dd" in local time.
    var day: String
    /// When this record last changed - edited, moved, deleted or restored. Merging
    /// keeps whichever copy was touched most recently.
    var updatedAt: Date
    /// Set when deleted. The row stays in the file; the app filters it out.
    var deletedAt: Date?

    var isDeleted: Bool { deletedAt != nil }

    /// The moment this record last changed in any way, deletion included.
    var touchedAt: Date { max(updatedAt, deletedAt ?? .distantPast) }

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(),
         day: String, updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.day = day
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, day, updatedAt, deletedAt
    }

    /// Files written before tombstones existed have no `updatedAt` or `deletedAt`.
    /// Treating creation as the last change and nothing as deleted reads them exactly
    /// as they were meant, so no migration step is needed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        day = try c.decode(String.self, forKey: .day)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

/// Days are plain "yyyy-MM-dd" strings rather than `Date`s, so the file stays readable
/// and no timezone arithmetic is needed to answer "what did I do on the 3rd".
/// Zero padding means string ordering is also date ordering.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func of(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ key: String) -> Date? { formatter.date(from: key) }
    static var today: String { of(Date()) }
    static var yesterday: String { adding(-1, to: today) }

    /// `key` shifted by `days`, or `key` unchanged if it can't be parsed.
    static func adding(_ days: Int, to key: String) -> String {
        guard let d = date(key),
              let moved = Calendar.current.date(byAdding: .day, value: days, to: d)
        else { return key }
        return of(moved)
    }

    static func isFuture(_ key: String) -> Bool { key > today }

    /// "yyyy-MM" — the prefix shared by every day in a month.
    static func monthPrefix(_ date: Date) -> String { String(of(date).prefix(7)) }

    /// `time`'s reading on the clock, placed on the day `key` names. An entry typed in
    /// after the fact is stamped with the date it was written; this is the moment it
    /// actually describes.
    static func at(_ time: Date, on key: String) -> Date? {
        let clock = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
        guard let day = date(key),
              let hour = clock.hour, let minute = clock.minute, let second = clock.second
        else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: day)
    }

    /// How far into its day `date` falls, by the clock on the wall - so a thing logged
    /// days late still sorts by the hour it says it happened. Read from the hour and
    /// minute rather than measured from midnight, which a daylight-saving change would
    /// throw off by an hour.
    static func clockSeconds(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }
}

/// One month as a calendar lays it out: blank squares until the 1st reaches its weekday's
/// column, then a square per day. Kept apart from the view that draws it, so the layout can
/// be checked on its own - across clock changes, leap years and either first weekday.
struct MonthLayout {
    /// The first moment of the 1st.
    let start: Date
    let dayCount: Int
    /// Empty squares before the 1st.
    let leadingBlanks: Int
    private let calendar: Calendar

    init(containing date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        leadingBlanks = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    }

    /// The month `months` after this one, or before it for a negative count.
    func adding(_ months: Int) -> MonthLayout {
        MonthLayout(containing: calendar.date(byAdding: .month, value: months, to: start) ?? start,
                    calendar: calendar)
    }

    /// "yyyy-MM", the prefix every day in it shares.
    var prefix: String { DayKey.monthPrefix(start) }

    /// Rows of squares it takes, blanks included: four to six.
    var weekCount: Int { (leadingBlanks + dayCount + 6) / 7 }

    /// The key of the day numbered `number`, the 1st being 1.
    func key(_ number: Int) -> String {
        guard let date = calendar.date(byAdding: .day, value: number - 1, to: start) else { return "" }
        return DayKey.of(date)
    }

    /// One-letter weekday names, in the order the columns run.
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}

/// Something you plan to do.
///
/// The to-do list is a staging area, not the point of the app. Checking one off writes
/// it onto the board as a thing you did and the to-do itself goes away - the board and
/// the calendar only ever show work that actually happened.
struct Todo: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    /// Set when it leaves the list, whether it was checked off or simply dropped. Why
    /// it left doesn't need recording here: if it was done, there is an entry on the
    /// board saying so. A tombstone, for the same reason entries have them.
    var deletedAt: Date?

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(),
         updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, updatedAt, deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

/// What both record types need in order to be merged. The rules are subtle enough that
/// having two copies of them would be a way to end up with two different answers.
protocol Mergeable: Identifiable, Codable where ID == UUID {
    var text: String { get }
    var createdAt: Date { get }
    var isDeleted: Bool { get }
    var touchedAt: Date { get }
}

extension Entry: Mergeable {}

extension Todo: Mergeable {
    var isDeleted: Bool { deletedAt != nil }
    var touchedAt: Date { max(updatedAt, deletedAt ?? .distantPast) }
}

/// What just happened that is worth setting off fireworks over.
enum Celebration: Equatable {
    /// You crossed the daily goal with this entry.
    case goalReached(count: Int)
    /// You crossed another whole multiple of it.
    case encore(count: Int)

    var count: Int {
        switch self {
        case .goalReached(let n), .encore(let n): return n
        }
    }
}

/// A celebration asked for but not yet running. The `id` makes every request distinct,
/// so asking for the same kind twice in a row still fires twice.
struct CelebrationRequest: Equatable {
    let id = UUID()
    let kind: Celebration
}

/// The sound a celebration makes.
///
/// Not an enum, because the choices aren't known at compile time: the list is whatever
/// audio the app was built with, plus the platform's own alert. That keeps adding a
/// sound to a matter of dropping a file into `Resources/Sounds`.
struct ChimeSound: Codable, Hashable, Identifiable {
    let name: String

    var id: String { name }
    var isStock: Bool { name == ChimeSound.stock.name }

    /// The platform's own celebratory alert - referenced, never shipped.
    static let stock = ChimeSound(name: "Default")
    static let fallback = stock

    /// What the picker offers: the stock sound, then any bundled audio.
    static var available: [ChimeSound] {
        [stock] + SoundFile.bundledNames.map(ChimeSound.init)
    }

    init(name: String) { self.name = name }

    /// A name is kept exactly as stored even when this build has no audio for it. The
    /// alternative - quietly resolving it to the stock sound - would write that back on
    /// the next save and wipe the choice for whichever device *does* have the file.
    init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// A hybrid logical clock: wall time, except never allowed to go backwards past
/// anything already seen.
///
/// Merging picks whichever copy of a record was touched last, which quietly assumes the
/// two devices agree what "last" means. They don't - one can be minutes or hours off,
/// and a device running behind would lose every exchange, silently, forever.
///
/// The fix is to make a timestamp carry causality rather than only the hour. After
/// reading another device's work, this clock never issues a stamp below what it just
/// read. So an edit made *after* seeing someone else's edit always outranks it, whatever
/// the wall clocks say. Wrong clocks can still misorder two edits that genuinely never
/// saw each other - nothing can fix that - but they can no longer undo one you made
/// with the other already in front of you.
struct HybridClock {
    private var last = Date.distantPast

    /// The stamp to put on a change being made right now.
    mutating func now() -> Date {
        let issued = max(Date(), last.addingTimeInterval(0.001))
        last = issued
        return issued
    }

    /// Note a timestamp seen in someone else's data, so later stamps outrank it.
    mutating func observe(_ seen: Date) {
        if seen > last { last = seen }
    }

    mutating func observe(_ archive: Archive) {
        for entry in archive.entries { observe(entry.touchedAt) }
        for todo in archive.todos { observe(todo.touchedAt) }
        observe(archive.settingsUpdatedAt)
    }
}

/// The whole document, exactly as it sits on disk.
struct Archive: Codable {
    var version: Int
    var dailyGoal: Int
    var soundEnabled: Bool
    var goalSound: ChimeSound
    /// When the settings above last changed, so two copies can be merged by time
    /// rather than by whichever file happened to be read second.
    var settingsUpdatedAt: Date
    /// Every record, tombstones included.
    var entries: [Entry]
    /// Planned work, tombstones included. Checked-off to-dos live on as entries.
    var todos: [Todo]

    static let currentVersion = 2
    static let defaultGoal = 5

    init(version: Int = Archive.currentVersion,
         dailyGoal: Int = Archive.defaultGoal,
         soundEnabled: Bool = true,
         goalSound: ChimeSound = .fallback,
         settingsUpdatedAt: Date = .distantPast,
         entries: [Entry] = [],
         todos: [Todo] = []) {
        self.version = version
        self.dailyGoal = dailyGoal
        self.soundEnabled = soundEnabled
        self.goalSound = goalSound
        self.settingsUpdatedAt = settingsUpdatedAt
        self.entries = entries
        self.todos = todos
    }

    private enum CodingKeys: String, CodingKey {
        case version, dailyGoal, soundEnabled, goalSound, settingsUpdatedAt, entries, todos
    }

    /// Every field is optional on the way in, so a file written by an older or newer
    /// version of the app still opens instead of throwing the whole archive away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Archive.currentVersion
        dailyGoal = try c.decodeIfPresent(Int.self, forKey: .dailyGoal) ?? Archive.defaultGoal
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        goalSound = try c.decodeIfPresent(ChimeSound.self, forKey: .goalSound) ?? .fallback
        settingsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .settingsUpdatedAt) ?? .distantPast
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        todos = try c.decodeIfPresent([Todo].self, forKey: .todos) ?? []
    }

    /// Live records only - what the app actually shows.
    var live: [Entry] { entries.filter { !$0.isDeleted } }
    var liveTodos: [Todo] { todos.filter { !$0.isDeleted } }
}

extension Archive {
    /// Combines two copies of the archive that were edited independently.
    ///
    /// Each record is resolved on its own, keeping whichever side touched it last, so
    /// an edit on one device and a deletion on the other settle by time rather than by
    /// read order. A record only one side has simply carries over - and because a
    /// deletion is a tombstone rather than an absence, "deleted here" stays
    /// distinguishable from "not seen here", which is the whole point.
    ///
    /// The result does not depend on argument order: `merged(a, b)` and `merged(b, a)`
    /// produce the same archive, including for exact timestamp ties. That matters
    /// because two devices merge the same pair of files independently and must agree.
    ///
    /// The known weakness is the one every last-write-wins scheme has: it trusts the
    /// clocks. A device whose clock is badly wrong can win an exchange it should have
    /// lost. Nothing is ever silently dropped, though - the losing side's record is
    /// still a whole record, just not the one that won.
    static func merged(_ mine: Archive, _ theirs: Archive) -> Archive {
        let settings = theirs.settingsUpdatedAt > mine.settingsUpdatedAt ? theirs : mine
        return Archive(
            version: Archive.currentVersion,
            dailyGoal: settings.dailyGoal,
            soundEnabled: settings.soundEnabled,
            goalSound: settings.goalSound,
            settingsUpdatedAt: settings.settingsUpdatedAt,
            entries: merge(mine.entries, theirs.entries),
            todos: merge(mine.todos, theirs.todos))
    }

    /// Resolves two lists of the same records, id by id.
    static func merge<T: Mergeable>(_ mine: [T], _ theirs: [T]) -> [T] {
        var byID: [UUID: T] = [:]
        byID.reserveCapacity(mine.count + theirs.count)
        for record in mine { byID[record.id] = record }
        for record in theirs {
            guard let held = byID[record.id] else {
                byID[record.id] = record
                continue
            }
            if wins(record, over: held) { byID[record.id] = record }
        }
        // Creation time, then id. The id's string is only built for a tie - building it for
        // every comparison was most of what a merge of a large board cost.
        return byID.values.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Later touch wins. On an exact tie a deletion wins, and on a tie between two
    /// live records the text decides - arbitrary, but the same arbitrary answer on
    /// every device, which is what keeps the merge order-independent.
    private static func wins<T: Mergeable>(_ candidate: T, over held: T) -> Bool {
        if candidate.touchedAt != held.touchedAt { return candidate.touchedAt > held.touchedAt }
        if candidate.isDeleted != held.isDeleted { return candidate.isDeleted }
        return candidate.text > held.text
    }
}
