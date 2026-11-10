import Foundation

// Day keys, in a zone with daylight saving - test.sh sets one - since a day isn't always 24 hours.

func dayChecks() {
    check(TimeZone.current.identifier == "America/Chicago",
          "these expect test.sh's zone, America/Chicago, not \(TimeZone.current.identifier)")
    check(DayKey.adding(1, to: "2026-03-07") == "2026-03-08", "adding a day before the clocks go forward")
    check(DayKey.adding(1, to: "2026-03-08") == "2026-03-09", "adding a day on the night the clocks go forward")
    check(DayKey.adding(1, to: "2026-11-01") == "2026-11-02", "adding a day on the night the clocks go back")
    check(DayKey.adding(-1, to: "2026-11-02") == "2026-11-01", "going back across the clocks going back")
    check(DayKey.adding(1, to: "2028-02-28") == "2028-02-29", "reaching a leap day")
    check(DayKey.adding(1, to: "2026-12-31") == "2027-01-01", "crossing a year")
    check(DayKey.adding(3, to: "not a day") == "not a day", "a key that isn't a day didn't come back unchanged")

    check(!DayKey.isFuture(DayKey.today) && DayKey.isFuture(DayKey.adding(1, to: DayKey.today)), "telling the future from today")
    check(DayKey.yesterday == DayKey.adding(-1, to: DayKey.today), "yesterday")

    // A time placed on another day keeps its reading on the clock, across a clock change too.
    let placed = DayKey.at(time(10, 15, on: "2026-03-07"), on: "2026-03-09")
    check(placed.map(DayKey.of) == "2026-03-09" && placed.map(DayKey.clockSeconds) == 10 * 3600 + 15 * 60,
          "placing 10:15 on the day after the clocks changed")
    check(DayKey.monthPrefix(time(9, 0, on: "2026-03-31")) == "2026-03", "the month prefix")
}

// Months as the calendar lays them out, the two with a clock change in them included. The calendars
// are built here rather than taken from the system, so the week starts where each check says it does.
func monthChecks() {
    var sundayFirst = Calendar(identifier: .gregorian)
    sundayFirst.locale = Locale(identifier: "en_US")
    sundayFirst.firstWeekday = 1
    var mondayFirst = sundayFirst
    mondayFirst.firstWeekday = 2

    let november = MonthLayout(containing: time(23, 30, on: "2026-11-30"), calendar: sundayFirst)
    check(november.prefix == "2026-11" && november.dayCount == 30, "November 2026, from late on its last day")
    check(november.leadingBlanks == 0, "November 2026 starts on a Sunday, so in the first column")
    check(november.key(1) == "2026-11-01" && november.key(2) == "2026-11-02" && november.key(30) == "2026-11-30",
          "the days either side of the clocks going back")
    check(MonthLayout(containing: time(9, 0, on: "2026-11-15"), calendar: mondayFirst).leadingBlanks == 6,
          "a week starting Monday puts that Sunday in the last column")

    let march = MonthLayout(containing: time(0, 0, on: "2026-03-08"), calendar: sundayFirst)
    check(march.dayCount == 31 && march.key(8) == "2026-03-08" && march.key(9) == "2026-03-09",
          "the days either side of the clocks going forward")
    check(MonthLayout(containing: time(9, 0, on: "2026-10-27"), calendar: sundayFirst).leadingBlanks == 4,
          "October 2026 starts on a Thursday")

    check(MonthLayout(containing: time(9, 0, on: "2028-02-10"), calendar: sundayFirst).dayCount == 29, "a leap February")
    check(MonthLayout(containing: time(9, 0, on: "2026-02-10"), calendar: sundayFirst).dayCount == 28, "an ordinary February")

    let january = MonthLayout(containing: time(9, 0, on: "2026-12-31"), calendar: sundayFirst).adding(1)
    check(january.prefix == "2027-01" && january.adding(-1).prefix == "2026-12", "stepping across a year and back")
    check(january.leadingBlanks == 5, "January 2027 starts on a Friday")

    check(november.weekCount == 5 && january.weekCount == 6, "five rows for November 2026, six for January 2027")
    check(MonthLayout(containing: time(9, 0, on: "2026-02-10"), calendar: sundayFirst).weekCount == 4,
          "February 2026 starts on a Sunday and fills four rows exactly")

    check(november.weekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"], "the column heads for a week starting Sunday")
    check(MonthLayout(containing: Date(), calendar: mondayFirst).weekdaySymbols == ["M", "T", "W", "T", "F", "S", "S"],
          "the column heads for a week starting Monday")
}
