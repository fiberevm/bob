import XCTest
@testable import BobCore

final class ConversationDayGroupTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, year: Int = 2026, month: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func session(at date: Date) -> Session {
        var session = Session(projectPath: "/fixture")
        session.updatedAt = date
        return session
    }

    func testGroupsAndSortsByLatestActivityWithoutLosingSessions() {
        let earlier = session(at: date(8, 1))
        let later = session(at: date(8, 23))
        let yesterday = session(at: date(7))
        let groups = ConversationDayGroup.grouped([yesterday, earlier, later], calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].sessions.map(\.id), [later.id, earlier.id])
        XCTAssertEqual(groups[1].sessions.map(\.id), [yesterday.id])
        XCTAssertEqual(groups[0].day, calendar.startOfDay(for: later.updatedAt))
        XCTAssertTrue(ConversationDayGroup.grouped([], calendar: calendar).isEmpty)
    }

    func testRelativeLabelsAcrossDaylightSavingAndMidnight() {
        let groups = ConversationDayGroup.grouped([session(at: date(8, 0))], calendar: calendar)
        // March 8 is only 23 hours long in this time zone.
        XCTAssertEqual(groups[0].title(now: date(8, 23), calendar: calendar), "Today")
        XCTAssertEqual(groups[0].title(now: date(9, 0), calendar: calendar), "Yesterday")
    }

    func testOlderDaysUseDatesAndIncludeYearWhenNeeded() {
        let locale = Locale(identifier: "en_US")
        let groups = ConversationDayGroup.grouped([
            session(at: date(6)), session(at: date(31, year: 2025, month: 12))
        ], calendar: calendar)
        XCTAssertEqual(groups[0].title(now: date(9), calendar: calendar, locale: locale), "March 6")
        XCTAssertEqual(groups[1].title(now: date(9), calendar: calendar, locale: locale), "December 31, 2025")
    }

    func testEqualTimestampsPreserveInputOrder() {
        let first = session(at: date(8))
        let second = session(at: first.updatedAt)
        let groups = ConversationDayGroup.grouped([first, second], calendar: calendar)
        XCTAssertEqual(groups[0].sessions.map(\.id), [first.id, second.id])
    }
}
