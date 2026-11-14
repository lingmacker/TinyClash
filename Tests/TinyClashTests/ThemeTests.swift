import AppKit
import SwiftUI
import XCTest
@testable import TinyClash

final class ThemeTests: XCTestCase {
    func testAccentUsesLightenedOrangePulsePalette() throws {
        let accent = try XCTUnwrap(NSColor(Theme.accent).usingColorSpace(.sRGB))
        XCTAssertEqual(accent.redComponent, 245 / 255, accuracy: 0.0001)
        XCTAssertEqual(accent.greenComponent, 123 / 255, accuracy: 0.0001)
        XCTAssertEqual(accent.blueComponent, 63 / 255, accuracy: 0.0001)
        let highlight = try XCTUnwrap(NSColor(Theme.accentHighlight).usingColorSpace(.sRGB))
        XCTAssertEqual(highlight.redComponent, 1, accuracy: 0.0001)
        XCTAssertEqual(highlight.greenComponent, 150 / 255, accuracy: 0.0001)
        XCTAssertEqual(highlight.blueComponent, 97 / 255, accuracy: 0.0001)
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
            for (foreground, background) in [(Theme.statusActive, Theme.statusActiveFill),
                                             (Theme.accentForeground, Theme.controlFill)] {
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
            for color in [Theme.canvas, Theme.panel, Theme.controlFill] {
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
}
