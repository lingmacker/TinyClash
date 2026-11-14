import Foundation
import XCTest
@testable import TinyClash

final class UpdateAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUpdatesWithinOneMinuteShowJustNow() {
        for elapsed: TimeInterval in [0, 1, 30, 59, 59.999] {
            XCTAssertEqual(Format.updateAge(now.addingTimeInterval(-elapsed), now: now), "刚刚")
        }
    }

    func testMinuteGranularityDoesNotIncludeSeconds() {
        for (elapsed, expected): (TimeInterval, String) in [
            (60, "1 分钟前"), (119, "1 分钟前"), (120, "2 分钟前"), (3599, "59 分钟前")
        ] {
            XCTAssertEqual(Format.updateAge(now.addingTimeInterval(-elapsed), now: now), expected)
        }
    }

    func testHourGranularityDoesNotIncludeMinutes() {
        for (elapsed, expected): (TimeInterval, String) in [
            (3600, "1 小时前"), (7199, "1 小时前"), (7200, "2 小时前"), (86399, "23 小时前")
        ] {
            XCTAssertEqual(Format.updateAge(now.addingTimeInterval(-elapsed), now: now), expected)
        }
    }

    func testDayGranularityDoesNotIncludeHours() {
        for (elapsed, expected): (TimeInterval, String) in [
            (86400, "1 天前"), (172799, "1 天前"), (172800, "2 天前"), (2592000, "30 天前")
        ] {
            XCTAssertEqual(Format.updateAge(now.addingTimeInterval(-elapsed), now: now), expected)
        }
    }

    func testFutureTimestampFromClockSkewShowsJustNow() {
        XCTAssertEqual(Format.updateAge(now.addingTimeInterval(120), now: now), "刚刚")
    }
}
