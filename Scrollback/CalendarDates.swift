import Foundation

func collectionCalendarDays(month: Date, calendar: Calendar) -> [Date] {
    guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
    let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
}
