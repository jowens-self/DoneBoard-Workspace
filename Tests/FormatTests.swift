import Foundation

// The file format, through the store the way the app reads and writes it. A file written by any
// earlier version has to open exactly as it was meant, and whatever this build doesn't understand
// has to survive it saving.

func oldFileChecks() {
    // A board from before deletions, to-dos and synced settings existed: no updatedAt,
    // whole-second dates, half the fields missing.
    let url = freshFile("old-file")
    write("""
    {
      "version": 1,
      "dailyGoal": 4,
      "soundEnabled": false,
      "entries": [
        { "id": "11111111-1111-1111-1111-111111111111", "text": "Wrote the report",
          "createdAt": "2025-03-01T15:04:05Z", "day": "2025-03-01" },
        { "id": "22222222-2222-2222-2222-222222222222", "text": "Called the bank",
          "createdAt": "2025-03-02T09:00:00Z", "day": "2025-03-02" }
      ]
    }
    """, to: url)

    let store = board(at: url)
    check(store.records.count == 2 && store.count(on: "2025-03-01") == 1, "an old file didn't open with both entries")
    let first = store.records.first { $0.text == "Wrote the report" }
    check(first?.updatedAt == first?.createdAt && first?.deletedAt == nil,
          "an old entry didn't read as unedited and undeleted")
    check(store.dailyGoal == 4 && !store.soundEnabled && store.goalSound == .stock,
          "an old file's settings didn't come through")
    check(store.todos.isEmpty, "an old file grew to-dos")

    // Saving rewrites it in the current format without losing anything.
    store.add("Something new", to: "2025-03-03")
    let saved = json(at: url)
    check(saved["version"] as? Int == Archive.currentVersion, "saving didn't move the file to the current version")
    check(board(at: url).records.count == 3, "saving an old file lost an entry")
}

func unknownValueChecks() {
    // A sound this build has never heard of, as a newer build or the other device might write.
    // It has to round-trip rather than being dropped on the next save.
    let url = freshFile("unknown-values")
    write("""
    {
      "version": 2,
      "goalSound": "Glass",
      "settingsUpdatedAt": "2026-01-01T00:00:00.000Z",
      "entries": [],
      "todos": []
    }
    """, to: url)

    let store = board(at: url)
    check(store.goalSound.name == "Glass", "a sound this build doesn't have was swapped for another")
    store.add("Saving something else", to: "2026-01-03")
    check(json(at: url)["goalSound"] as? String == "Glass", "a sound this build doesn't have was dropped on saving")
}

func corruptFileChecks() {
    let url = freshFile("corrupt")
    let garbage = "{ \"entries\": [ this is not JSON"
    write(garbage, to: url)

    let store = board(at: url)
    check(store.records.isEmpty && store.syncProblem != nil, "an unreadable board wasn't reported")
    let folder = url.deletingLastPathComponent()
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
        .filter { $0.hasPrefix("board.corrupt-") } ?? []
    check(kept.count == 1, "the unreadable file's bytes weren't kept aside")
    if let name = kept.first {
        let bytes = try? String(contentsOf: folder.appendingPathComponent(name, isDirectory: false), encoding: .utf8)
        check(bytes == garbage, "the copy kept aside isn't the original bytes")
    }

    // Working again from here: the next save writes a good file, and the copy stays.
    store.add("Starting over", to: "2026-01-04")
    check(board(at: url).records.map(\.text) == ["Starting over"], "the board didn't recover after a bad file")
}

func unreadableFileChecks() {
    // A file that's there but can't be read - still arriving from a sync service, or not openable
    // from here. Writing would replace a board this device has never seen, so it must not.
    let url = freshFile("unreadable")
    let first = board(at: url)
    first.add("Already on the board", to: "2026-01-05")
    let before = try! Data(contentsOf: url)

    chmod(url.path, 0)
    let store = board(at: url)
    store.add("Made while it couldn't be read", to: "2026-01-05")
    check(store.syncProblem != nil, "failing to save wasn't reported")
    chmod(url.path, 0o644)
    check((try? Data(contentsOf: url)) == before, "a file that couldn't be read was written over")

    // Once it can be read, the two come together and nothing is lost.
    store.reload()
    check(Set(board(at: url).records.map(\.text)) == ["Already on the board", "Made while it couldn't be read"],
          "the change made while the file was unreadable didn't reach it afterwards")
}
