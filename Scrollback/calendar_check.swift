// Run: cat Scrollback/CalendarDates.swift Scrollback/calendar_check.swift | swift -
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
calendar.firstWeekday = 2
func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
let september = collectionCalendarDays(month: date(2026, 9, 30), calendar: calendar)
assert(september.count == 42)
assert(september.first == date(2026, 8, 31))
assert(september.last == date(2026, 10, 11))
assert(september[30] == date(2026, 9, 30))
let february = collectionCalendarDays(month: date(2024, 2, 15), calendar: calendar)
assert(february.contains(date(2024, 2, 29)))
calendar.firstWeekday = 1
let sunday = collectionCalendarDays(month: date(2026, 9, 30), calendar: calendar)
assert(sunday.first == date(2026, 8, 30))
assert(Set(sunday).count == 42)
print("Calendar checks passed: month boundaries, leap day, locale week start")
