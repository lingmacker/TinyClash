import AppKit
import SwiftUI
import XCTest
@testable import TinyClash

final class ThemeTests: XCTestCase {
    func testSettingsKeepsOriginalAccentWithoutChangingPanelPalette() throws {
        let palette: [(Color, CGFloat, CGFloat, CGFloat)] = [
            (Theme.settingsControlTint, 245, 123, 63),
            (Theme.accent, 203, 77, 23),
            (Theme.accentHighlight, 220, 100, 50)
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for (token, red, green, blue) in palette {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(token).usingColorSpace(.sRGB)
                }
                let color = try XCTUnwrap(resolved)
                XCTAssertEqual(color.redComponent, red / 255, accuracy: 0.0001)
                XCTAssertEqual(color.greenComponent, green / 255, accuracy: 0.0001)
                XCTAssertEqual(color.blueComponent, blue / 255, accuracy: 0.0001)
            }
        }
    }

    func testStatusAndSelectedControlsMaintainReadableContrastInBothAppearances() throws {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent)
                + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for (foreground, background) in [(Theme.settingsActionForeground, Theme.panel),
                                             (Theme.statusActive, Theme.statusActiveFill),
                                             (Theme.accentForeground, Theme.controlFill),
                                             (Theme.accentForeground, Theme.selectedSurface)] {
                var colors: [NSColor] = []
                appearance.performAsCurrentDrawingAppearance {
                    colors = [foreground, background].compactMap { NSColor($0).usingColorSpace(.sRGB) }
                }
                XCTAssertEqual(colors.count, 2)
                let first = luminance(try XCTUnwrap(colors.first))
                let second = luminance(try XCTUnwrap(colors.last))
                XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 4.5)
                XCTAssertEqual(colors.last?.alphaComponent, 1)
            }
        }
    }

    func testCanvasAndPanelsAreOpaqueInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for color in [Theme.canvas, Theme.panel, Theme.controlFill, Theme.selectedSurface] {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(color).usingColorSpace(.sRGB)
                }
                XCTAssertEqual(try XCTUnwrap(resolved).alphaComponent, 1)
            }
        }
    }

    func testControlFillUsesSoftWarmTonesInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(Theme.controlFill).usingColorSpace(.sRGB)
            }
            let fill = try XCTUnwrap(resolved)
            XCTAssertGreaterThan(fill.redComponent, fill.greenComponent)
            XCTAssertGreaterThan(fill.greenComponent, fill.blueComponent)
            if name == .aqua {
                XCTAssertGreaterThan(fill.blueComponent, 0.85)
                XCTAssertLessThan(fill.redComponent - fill.blueComponent, 0.15)
            } else {
                XCTAssertLessThan(fill.redComponent, 0.35)
            }
        }
    }

    func testOutboundNodeAndNetworkTintsFollowSemanticRoles() {
        XCTAssertEqual(Theme.outboundNodeTint("DIRECT"), Theme.active)
        XCTAssertEqual(Theme.outboundNodeTint("REJECT"), Theme.failure)
        XCTAssertEqual(Theme.outboundNodeTint("REJECT-DROP"), Theme.failure)
        XCTAssertEqual(Theme.outboundNodeTint("香港 ISP 5"), Theme.accentForeground)
        XCTAssertEqual(Theme.outboundNodeTint("未知策略"), .secondary)

        XCTAssertEqual(Theme.networkTint("tcp"), Theme.download)
        XCTAssertEqual(Theme.networkTint("UDP"), Theme.upload)
        XCTAssertEqual(Theme.networkTint("icmp"), .secondary)
    }
}
