import Foundation

/// Sidebar sections based on the conversation's most recent activity, in local calendar days.
public struct ConversationDayGroup: Identifiable {
    public let day: Date
    public let sessions: [Session]
    public var id: Date { day }

    public static func grouped(_ sessions: [Session], calendar: Calendar = .current) -> [Self] {
        let days = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.updatedAt) }
        return days.keys.sorted(by: >).map { day in
            // Preserve the original order when timestamps are equal.
            let sorted = days[day]!.enumerated().sorted {
                if $0.element.updatedAt == $1.element.updatedAt { return $0.offset < $1.offset }
                return $0.element.updatedAt > $1.element.updatedAt
            }.map(\.element)
            return Self(day: day, sessions: sorted)
        }
    }

    public func title(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdyyyy")
        return formatter.string(from: day)
    }
}
