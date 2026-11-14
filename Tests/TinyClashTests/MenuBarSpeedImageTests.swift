import AppKit
import XCTest
@testable import TinyClash

@MainActor
final class MenuBarSpeedImageTests: XCTestCase {
    func testSpeedFormattingUsesBinaryUnitsAndTwoDecimalPlaces() {
        let cases: [(Int64, String)] = [
            (0, "  0.00KB/s"),
            (1, "  0.00KB/s"),
            (1024, "  1.00KB/s"),
            (1536, "  1.50KB/s"),
            (1_048_576, "  1.00MB/s"),
            (1_073_741_824, "  1.00GB/s"),
            (1_099_511_627_776, "  1.00TB/s"),
            (Int64.max, "  8.00EB/s"),
            (Int64.min, "  0.00KB/s")
        ]
        for (speed, expected) in cases {
            XCTAssertEqual(MenuBarSpeedImage.formattedSpeed(speed), expected)
        }
    }

    func testUploadIsAboveDownload() {
        XCTAssertEqual(MenuBarSpeedImage.text(upload: 1024, download: 1_048_576),
                       "↑   1.00KB/s\n↓   1.00MB/s")
    }

    func testImageHasFixedSizeAndUsesSystemTemplateTinting() {
        for speed: Int64 in [0, 1024, 1_048_576, Int64.max] {
            let image = MenuBarSpeedImage.image(upload: speed, download: speed, active: true)
            XCTAssertEqual(image.size, NSSize(width: 88, height: 22))
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testUnchangedFormattedTextReusesImage() {
        let first = MenuBarSpeedImage.image(upload: 1024, download: 0, active: true)
        let second = MenuBarSpeedImage.image(upload: 1025, download: 0, active: true)
        XCTAssertTrue(first === second)
        let changed = MenuBarSpeedImage.image(upload: 2048, download: 0, active: true)
        XCTAssertFalse(second === changed)
    }

    func testProxyStateChangeInvalidatesImage() {
        let active = MenuBarSpeedImage.image(upload: 0, download: 0, active: true)
        let idle = MenuBarSpeedImage.image(upload: 0, download: 0, active: false)
        XCTAssertFalse(active === idle)
    }

    func testDisplayedRatesFitTheFixedSpeedColumn() {
        let speeds: [Int64] = [0, 1023, 1024, 1_048_575, 1_048_576, 1_073_741_823,
                               1_073_741_824, Int64.max]
        for speed in speeds {
            let line = "↑ \(MenuBarSpeedImage.formattedSpeed(speed))" as NSString
            let size = line.size(withAttributes: [.font: MenuBarSpeedImage.font])
            XCTAssertLessThanOrEqual(size.width, MenuBarSpeedImage.speedSize.width)
            XCTAssertLessThanOrEqual(size.height * 2, MenuBarSpeedImage.speedSize.height)
        }
    }
}
