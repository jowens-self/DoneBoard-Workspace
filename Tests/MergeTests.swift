import Foundation

// The merge is the whole sync design: two devices each merge the same pair of files on their own
// and have to land on the same board. These check what that rests on against random boards built
// to collide - shared records, exact timestamp ties, deletions racing edits - as well as a few
// cases worth spelling out.

/// Reproducible randomness, so a failure can be run again exactly. SplitMix64.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Copies of one board as different devices might hold it. Few ids, few distinct moments and few
/// texts, so random copies keep colliding in the ways that matter.
///
/// Every record is made from its id, when it was touched, whether that touch deleted it, and its
/// text, and the settings from their stamp. So two copies that agree on those are the same edit -
/// as they always are in the app, whose clock never issues the same stamp twice.
struct Boards {
    private var random: SeededRandom
    private let ids = (0..<10).map { _ in UUID() }
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let texts = ["Ship it", "Call the bank", "Write the report"]

    init(seed: UInt64) { random = SeededRandom(seed: seed) }

    mutating func next() -> Archive {
        var entries: [Entry] = []
        var todos: [Todo] = []
        for (n, id) in ids.enumerated() {
            guard let (touched, deleted, text) = version(of: n) else { continue }
            let made = start.addingTimeInterval(Double(n))
            if n % 2 == 0 {
                entries.append(Entry(id: id, text: text, createdAt: made,
                                     day: String(format: "2026-01-%02d", n + 1),
                                     updatedAt: touched, deletedAt: deleted ? touched : nil))
            } else {
                todos.append(Todo(id: id, text: text, createdAt: made, updatedAt: touched,
                                  deletedAt: deleted ? touched : nil))
            }
        }
        let stamp = Int.random(in: 0..<6, using: &random)
        return Archive(dailyGoal: 1 + stamp, soundEnabled: stamp % 2 == 0,
                       goalSound: stamp % 3 == 0 ? .stock : ChimeSound(name: "Chime \(stamp)"),
                       settingsUpdatedAt: stamp == 0 ? .distantPast : start.addingTimeInterval(Double(stamp) * 50),
                       entries: entries.shuffled(using: &random),
                       todos: todos.shuffled(using: &random))
    }

    /// How one device holds record `n`: not at all, as first written, edited, or deleted.
    private mutating func version(of n: Int) -> (Date, Bool, String)? {
        switch Int.random(in: 0..<4, using: &random) {
        case 0: return nil
        case 1: return (start.addingTimeInterval(Double(n)), false, "Task \(n)")
        default:
            // Three moments shared between every edit and deletion, so exact ties are common.
            let moment = start.addingTimeInterval(100 + Double(Int.random(in: 0..<3, using: &random)))
            return (moment, Bool.random(using: &random), texts.randomElement(using: &random)!)
        }
    }
}

/// Every record either side had is in the result, as the copy that was touched last - nothing
/// dropped, and nothing blended out of two copies.
func keepsEverything<T: Mergeable & Hashable>(_ mine: [T], _ theirs: [T], _ merged: [T]) -> Bool {
    let ids = Set(mine.map(\.id)).union(theirs.map(\.id))
    guard merged.count == ids.count, Set(merged.map(\.id)) == ids else { return false }
    return merged.allSatisfy { record in
        let copies = (mine + theirs).filter { $0.id == record.id }
        return copies.contains(record) && copies.allSatisfy { $0.touchedAt <= record.touchedAt }
    }
}

func mergeProperties() {
    var boards = Boards(seed: 20_261_023)
    var reordered = 0, regrouped = 0, changedItself = 0, dropped = 0, settingsLost = 0
    for _ in 0..<500 {
        let a = boards.next(), b = boards.next(), c = boards.next()
        let ab = Archive.merged(a, b)
        if !same(ab, Archive.merged(b, a)) { reordered += 1 }
        if !same(Archive.merged(ab, c), Archive.merged(a, Archive.merged(b, c))) { regrouped += 1 }
        if !same(Archive.merged(a, a), a) { changedItself += 1 }
        if !keepsEverything(a.entries, b.entries, ab.entries)
            || !keepsEverything(a.todos, b.todos, ab.todos) { dropped += 1 }
        if ab.settingsUpdatedAt != max(a.settingsUpdatedAt, b.settingsUpdatedAt) { settingsLost += 1 }
    }
    check(reordered == 0, "\(reordered) of 500 merges came out differently in the other order")
    check(regrouped == 0, "\(regrouped) of 500 three-way merges depended on which pair went first")
    check(changedItself == 0, "\(changedItself) of 500 boards changed when merged with themselves")
    check(dropped == 0, "\(dropped) of 500 merges dropped or blended a record")
    check(settingsLost == 0, "\(settingsLost) of 500 merges kept older settings")
}

func mergeCases() {
    let made = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let original = Entry(text: "Draft the proposal", createdAt: made, day: "2026-01-05")
    func edited(_ text: String, at seconds: Double) -> Entry {
        var copy = original
        copy.text = text
        copy.updatedAt = made.addingTimeInterval(seconds)
        return copy
    }
    func deleted(at seconds: Double) -> Entry {
        var copy = original
        copy.updatedAt = made.addingTimeInterval(seconds)
        copy.deletedAt = copy.updatedAt
        return copy
    }
    func winner(_ a: Entry, _ b: Entry) -> Entry? {
        let one = Archive.merge([a], [b]), other = Archive.merge([b], [a])
        return one == other && one.count == 1 ? one[0] : nil
    }

    check(winner(edited("v2", at: 10), deleted(at: 20))?.isDeleted == true,
          "a deletion lost to an edit made before it")
    check(winner(edited("v3", at: 30), deleted(at: 20))?.text == "v3",
          "an edit made after a deletion didn't bring the entry back")
    check(winner(edited("v2", at: 40), deleted(at: 40))?.isDeleted == true,
          "a deletion and an edit at the same moment didn't settle on the deletion")
    check(winner(edited("Apple", at: 50), edited("Banana", at: 50)) != nil,
          "two edits at the same moment settled differently depending on order")
    check(winner(original, original) == original, "a record merged with itself changed")

    // Settings travel as one block, so the later change brings the other settings with it.
    let goal = Archive(dailyGoal: 7, settingsUpdatedAt: made.addingTimeInterval(1))
    let quiet = Archive(soundEnabled: false, settingsUpdatedAt: made.addingTimeInterval(2))
    let settled = Archive.merged(goal, quiet)
    check(settled.dailyGoal == Archive.defaultGoal && !settled.soundEnabled,
          "the later settings didn't win as a block")
}

func clockChecks() {
    // Another device running an hour fast. Anything stamped after seeing its work has to outrank
    // that work, or this device would lose every exchange with it until the clocks agreed.
    let ahead = Date().addingTimeInterval(3600)
    var clock = HybridClock()
    clock.observe(ahead)
    let first = clock.now()
    check(first > ahead, "a change made after seeing a later stamp didn't outrank it")
    check(clock.now() > first, "two stamps in a row weren't increasing")

    var reading = HybridClock()
    reading.observe(Archive(entries: [Entry(text: "Theirs", day: "2026-01-01", updatedAt: ahead)]))
    check(reading.now() > ahead, "reading a board didn't move the clock past what it held")
}
