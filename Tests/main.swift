import Foundation

// Run by test.sh, which compiles the app's model sources in alongside these files.

group("merging is order-independent and loses nothing", mergeProperties)
group("merging: deletions, ties and settings", mergeCases)
group("a change made after seeing another device's outranks it", clockChecks)
group("an old file opens as it was meant", oldFileChecks)
group("a sound this build doesn't know survives a save", unknownValueChecks)
group("a file that won't parse is kept aside", corruptFileChecks)
group("a file that can't be read is never written over", unreadableFileChecks)
group("adding", addingChecks)
group("fireworks at the goal and its multiples", celebrationChecks)
group("editing, deleting and restoring entries", entryEditingChecks)
group("moving an entry keeps its time, across a clock change", movingChecks)
group("a day's entries in order of the time they say", dayOrderChecks)
group("month totals", totalChecks)
group("the to-do list", todoChecks)
group("checking off a to-do", completingChecks)
group("every edit stamps a change", stampChecks)
group("two devices sharing one file", twoDeviceChecks)
group("a shared folder that stops answering", sharedFolderChecks)
group("the main thread never waits on a share", mainThreadChecks)
group("leaving a share that has stopped answering", leavingAHeldShareChecks)
group("files told apart by name, never by asking the disk", samePlaceChecks)
group("a board in place, uncoordinated as the apps keep their own file") {
    Store.coordinatesInPlace = false
    defer { Store.coordinatesInPlace = true }
    twoDeviceChecks()
    corruptFileChecks()
    unreadableFileChecks()
}
group("day keys across clock changes", dayChecks)
group("months as the calendar lays them out", monthChecks)
group("launch keeps only the newest reports", reportPruningChecks)
group("the log says what each save was for", saveReasonChecks)
group("a new entry on a three-year board saves quickly", largeBoardChecks)

print("\n\(checks) checks, \(failures == 0 ? "all passed" : "\(failures) failed")")
exit(failures == 0 ? 0 : 1)
