import Foundation

// Editing the board and the list through the store, as the app's views do.

func addingChecks() {
    let (store, url) = freshStore("adding")
    let day = "2026-02-10"
    store.add("   \n", to: day)
    check(store.records.isEmpty, "a blank entry was added")
    store.add("  Fixed the sink \n", to: day)
    check(store.entries(on: day).map(\.text) == ["Fixed the sink"], "an entry's text wasn't trimmed")
    check(board(at: url).count(on: day) == 1, "an entry wasn't saved")

    store.dailyGoal = 0
    check(store.dailyGoal == 1, "a goal of zero was allowed")
    store.dailyGoal = 500
    check(store.dailyGoal == 99, "a goal over 99 was allowed")
}

func celebrationChecks() {
    let (store, _) = freshStore("celebrations")
    store.dailyGoal = 3
    let earned = (1...7).map { store.add("Thing \($0)", to: "2026-02-11") }
    check(earned == [nil, nil, .goalReached(count: 3), nil, nil, .encore(count: 6), nil],
          "fireworks came at \(earned)")

    store.dailyGoal = 1
    let first = store.add("One", to: "2026-02-12"), second = store.add("Two", to: "2026-02-12")
    check(first == .goalReached(count: 1) && second == nil, "a goal of one celebrated \(first as Any), \(second as Any)")
}

func entryEditingChecks() {
    let (store, url) = freshStore("editing")
    let today = DayKey.today
    store.add("Walked the dog", to: today)
    var entry = store.entries(on: today)[0]
    func current() -> Entry { store.records.first { $0.id == entry.id }! }

    store.update(entry, text: "  Walked the dog twice ")
    check(current().text == "Walked the dog twice", "an edit didn't take, or wasn't trimmed")

    // Opening the editor and closing it again changes nothing, so it stamps nothing that would
    // win a merge.
    entry = current()
    store.update(entry, text: entry.text, time: entry.createdAt)
    check(current().updatedAt == entry.updatedAt, "an edit that changed nothing stamped a change")

    store.update(entry, text: entry.text, time: time(23, 59, on: today))
    check(current().createdAt <= Date(), "an entry was given a time that hasn't happened yet")

    store.delete(current())
    check(store.count(on: today) == 0 && store.entries(on: today).isEmpty, "a deleted entry still counts")
    check(current().isDeleted, "deleting removed the row instead of leaving a tombstone")
    check(board(at: url).count(on: today) == 0, "a deletion wasn't saved")
}

func movingChecks() {
    let (store, _) = freshStore("moving")
    store.add("Planted bulbs", to: "2026-03-07")
    var entry = store.entries(on: "2026-03-07")[0]
    // Give it 10:15 on its own day, then move it across the night the clocks go forward.
    store.update(entry, text: entry.text, time: time(10, 15, on: "2026-03-07"))
    entry = store.records.first { $0.id == entry.id }!
    store.move(entry, to: "2026-03-10")
    let moved = store.records.first { $0.id == entry.id }!
    check(moved.day == "2026-03-10" && store.count(on: "2026-03-07") == 0 && store.count(on: "2026-03-10") == 1,
          "an entry didn't move days")
    check(DayKey.clockSeconds(moved.createdAt) == 10 * 3600 + 15 * 60,
          "moving across the clock change made 10:15 into \(DayKey.clockSeconds(moved.createdAt) / 60) minutes past midnight")

    store.move(moved, to: DayKey.adding(2, to: DayKey.today))
    check(store.records.first { $0.id == entry.id }!.day == "2026-03-10", "an entry was moved into the future")
}

func dayOrderChecks() {
    // Latest first by the time each one says, not by when it was typed in.
    let (store, _) = freshStore("day-order")
    let day = "2026-02-14"
    for (text, hour) in [("Lunch", 12), ("Breakfast", 8), ("Dinner", 19)] {
        store.add(text, to: day)
        let entry = store.records.first { $0.text == text }!
        store.update(entry, text: text, time: time(hour, 0, on: day))
    }
    check(store.entries(on: day).map(\.text) == ["Dinner", "Lunch", "Breakfast"],
          "a day's entries came out as \(store.entries(on: day).map(\.text))")
}

func totalChecks() {
    let (month, _) = freshStore("month")
    for day in ["2026-04-01", "2026-04-01", "2026-04-09", "2026-05-01"] { month.add("Done", to: day) }
    let april = DayKey.date("2026-04-15")!
    check(month.monthTotal(april) == 3 && month.monthBest(april) == 2 && month.allTimeTotal == 4,
          "month totals came out \(month.monthTotal(april)), best \(month.monthBest(april))")
}

func todoChecks() {
    let (store, url) = freshStore("todos")
    for text in ["A", "B", "C", "D", "E"] { store.addTodo(text) }
    func order() -> [String] { store.openTodos.map(\.text) }
    check(order() == ["E", "D", "C", "B", "A"], "new to-dos didn't land on top: \(order())")
    store.addTodo("  ")
    check(store.openTodos.count == 5, "a blank to-do was added")
    check(board(at: url).openTodos.map(\.text) == order(), "another device sees a different order")

    store.updateTodo(store.openTodos[1], text: "  D, done properly ")
    check(order() == ["E", "D, done properly", "C", "B", "A"], "an edit didn't take, or wasn't trimmed: \(order())")
    store.removeTodo(store.openTodos[0])
    check(order() == ["D, done properly", "C", "B", "A"], "dropping a to-do left \(order())")
    check(store.todos.count == 5, "dropping a to-do removed the row instead of leaving a tombstone")
    check(board(at: url).openTodos.map(\.text) == order(), "dropping a to-do wasn't saved")
}

func completingChecks() {
    let (store, url) = freshStore("completing")
    let today = DayKey.today
    store.add("Pay rent", to: today)
    store.addTodo("Pay rent")
    let todo = store.openTodos[0]

    store.complete(todo, on: today)
    check(store.entries(on: today).map(\.text) == ["Pay rent", "Pay rent"], "the entry didn't carry the to-do's text")
    check(store.openTodos.isEmpty && store.count(on: today) == 2, "checking off didn't move it from the list to the board")
    store.complete(todo, on: today)
    check(store.count(on: today) == 2, "a to-do was checked off twice")
    let other = board(at: url)
    check(other.openTodos.isEmpty && other.count(on: today) == 2, "the check-off wasn't saved")

    // Checking off counts toward the goal exactly as typing it in would.
    store.dailyGoal = 3
    store.addTodo("Water the plants")
    check(store.complete(store.openTodos[0], on: today) == .goalReached(count: 3),
          "checking off the thing that reached the goal didn't celebrate")
}

func stampChecks() {
    // Every edit has to stamp a change, or the copy it replaced can win it back in a merge - on
    // another device, silently.
    let (store, _) = freshStore("stamps")
    let day = DayKey.yesterday
    let otherHour = (Calendar.current.component(.hour, from: Date()) + 12) % 24
    store.add("Original", to: day)
    let entryEdits: [(String, (Entry) -> Void)] = [
        ("editing an entry", { store.update($0, text: "Edited") }),
        ("retiming an entry", { store.update($0, text: $0.text, time: time(otherHour, 7, on: day)) }),
        ("moving an entry", { store.move($0, to: DayKey.adding(-3, to: day)) }),
        ("deleting an entry", { store.delete($0) }),
    ]
    for (what, edit) in entryEdits {
        let before = store.records[0]
        edit(before)
        let after = store.records[0]
        check(after.touchedAt > before.touchedAt, "\(what) didn't stamp a change")
        check(Archive.merge([before], [after]) == [after] && Archive.merge([after], [before]) == [after],
              "\(what) lost a merge to the copy it replaced")
    }

    store.addTodo("Second")
    store.addTodo("First")
    let todoEdits: [(String, (Todo) -> Void)] = [
        ("editing a to-do", { store.updateTodo($0, text: "Renamed") }),
        ("dropping a to-do", { store.removeTodo($0) }),
    ]
    let id = store.openTodos[0].id
    for (what, edit) in todoEdits {
        let before = store.todos.first { $0.id == id }!
        edit(before)
        let after = store.todos.first { $0.id == id }!
        check(after.touchedAt > before.touchedAt, "\(what) didn't stamp a change")
        check(Archive.merge([before], [after]) == [after] && Archive.merge([after], [before]) == [after],
              "\(what) lost a merge to the copy it replaced")
    }
}
