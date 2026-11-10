import Foundation

// How long the app stops for when the board is big. Every save runs on the main thread for this
// device's own file, so a slow one is a frozen app, not a slow background job.

func largeBoardChecks() {
    // Three years of five a day: every stamp different, as real ones are, and a third of the
    // entries edited after they were made. Written the way the app writes it - ISO 8601 with
    // milliseconds, keys sorted.
    let url = freshFile("large-board")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(formatter.string(from: date))
    }
    var random = SeededRandom(seed: 3)
    var entries: [Entry] = []
    let start = time(12, 0, on: "2023-10-01")
    for day in 0..<1100 {
        let noon = start.addingTimeInterval(Double(day) * 86_400)
        for n in 0..<5 {
            let made = noon.addingTimeInterval(Double(n) * 3001 + Double.random(in: 0..<1000, using: &random))
            entries.append(Entry(text: "Something finished, number \(n) of the day",
                                 createdAt: made, day: DayKey.of(noon),
                                 updatedAt: n % 3 == 0 ? made.addingTimeInterval(Double.random(in: 60..<90_000, using: &random)) : made))
        }
    }
    try! encoder.encode(Archive(entries: entries)).write(to: url)

    let store = board(at: url)
    let started = Date()
    for n in 0..<5 { store.add("Tap \(n)", to: DayKey.today) }
    let perTap = Date().timeIntervalSince(started) / 5
    // About 90ms on an M-series Mac, from 520ms before timestamps were remembered. The limit
    // leaves room for a slower machine; a return to re-reading every stamp lands far past it.
    check(perTap < 0.25, "adding an entry to a three-year board took \(Int(perTap * 1000))ms")
    check(board(at: url).records.count == entries.count + 5, "the large board lost entries on saving")
}
