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

    func testVersionComparisonAndNormalization() {
        XCTAssertEqual(UpdateChecker.normalizedVersion("v1.0.16"), "1.0.16")
        XCTAssertEqual(UpdateChecker.normalizedVersion(" 1.2.0 "), "1.2.0")
        XCTAssertTrue(UpdateChecker.isNewer(remote: "v1.0.17", than: "1.0.16"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.1.0", than: "1.0.16"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.16", than: "1.0.16-beta.1"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "v1.0.16", than: "1.0.16"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.15", than: "1.0.16"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.16-beta.1", than: "1.0.16"))
    }

    func testAppearanceModesFollowExpectedOrderAndTitles() {
        XCTAssertEqual(AppearanceMode.allCases, [.system, .dark, .light])
        XCTAssertEqual(AppearanceMode.allCases.map(\.title), ["跟随系统", "黑暗", "明亮"])
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
    }
}
