import AppKit
import SwiftUI
import XCTest
@testable import TinyClash

final class ThemeTests: XCTestCase {
    private func resolve(_ token: Color, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(token).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let l1 = luminance(first)
        let l2 = luminance(second)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func blend(_ foreground: NSColor, over background: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    func testBrandOrangePulseRampIsUnifiedAcrossAppearances() throws {
        // AppIcon 脉冲点渐变两端不随外观变化
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let top = try resolve(Theme.accentHighlight, in: name)
            XCTAssertEqual(top.redComponent, 255 / 255, accuracy: 0.0001)
            XCTAssertEqual(top.greenComponent, 150 / 255, accuracy: 0.0001)
            XCTAssertEqual(top.blueComponent, 97 / 255, accuracy: 0.0001)

            let bottom = try resolve(Theme.brandPulseBottom, in: name)
            XCTAssertEqual(bottom.redComponent, 242 / 255, accuracy: 0.0001)
            XCTAssertEqual(bottom.greenComponent, 114 / 255, accuracy: 0.0001)
            XCTAssertEqual(bottom.blueComponent, 52 / 255, accuracy: 0.0001)

            // 设置页控件与全应用强调色统一
            let accent = try resolve(Theme.accent, in: name)
            let settingsTint = try resolve(Theme.settingsControlTint, in: name)
            XCTAssertEqual(accent.redComponent, settingsTint.redComponent, accuracy: 0.0001)
            XCTAssertEqual(accent.greenComponent, settingsTint.greenComponent, accuracy: 0.0001)
            XCTAssertEqual(accent.blueComponent, settingsTint.blueComponent, accuracy: 0.0001)

            let accentFg = try resolve(Theme.accentForeground, in: name)
            let settingsFg = try resolve(Theme.settingsActionForeground, in: name)
            XCTAssertEqual(accentFg.redComponent, settingsFg.redComponent, accuracy: 0.0001)
            XCTAssertEqual(accentFg.greenComponent, settingsFg.greenComponent, accuracy: 0.0001)
            XCTAssertEqual(accentFg.blueComponent, settingsFg.blueComponent, accuracy: 0.0001)
        }

        let darkAccent = try resolve(Theme.accent, in: .darkAqua)
        XCTAssertEqual(darkAccent.redComponent, 245 / 255, accuracy: 0.0001)
        XCTAssertEqual(darkAccent.greenComponent, 123 / 255, accuracy: 0.0001)
        XCTAssertEqual(darkAccent.blueComponent, 63 / 255, accuracy: 0.0001)

        let lightAccent = try resolve(Theme.accent, in: .aqua)
        XCTAssertEqual(lightAccent.redComponent, 224 / 255, accuracy: 0.0001)
        XCTAssertEqual(lightAccent.greenComponent, 90 / 255, accuracy: 0.0001)
        XCTAssertEqual(lightAccent.blueComponent, 31 / 255, accuracy: 0.0001)
    }

    func testStatusAndSelectedControlsMaintainReadableContrastInBothAppearances() throws {
        let pairs: [(Color, Color)] = [
            (Theme.accentForeground, Theme.canvas),
            (Theme.accentForeground, Theme.panel),
            (Theme.accentForeground, Theme.controlFill),
            (Theme.accentForeground, Theme.selectedSurface),
            (Theme.settingsActionForeground, Theme.panel),
            (Theme.statusActive, Theme.statusActiveFill),
            (Theme.download, Theme.panel),
            (Theme.upload, Theme.panel),
            (Theme.active, Theme.panel),
            (Theme.warning, Theme.panel),
            (Theme.warningText, Theme.panel),
            (Theme.failure, Theme.panel),
            (Theme.chartLabel, Theme.panel),
            (Theme.toolbarHoverForeground, Theme.canvas),
            (Theme.ruleTypeTint("DOMAIN"), Theme.panel),
            (Theme.ruleTypeTint("IP-CIDR"), Theme.panel),
            (Theme.ruleTypeTint("RULE-SET"), Theme.panel),
            (Theme.ruleTypeTint("MATCH"), Theme.panel),
        ]
        let tagTints: [Color] = [
            Theme.accentForeground,
            Theme.active,
            Theme.warning,
            Theme.download,
            Theme.upload,
            Theme.ruleTypeTint("IP-CIDR"),
            Theme.ruleTypeTint("RULE-SET"),
            Theme.ruleTypeTint("MATCH"),
        ]

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for (foreground, background) in pairs {
                let fg = try resolve(foreground, in: name)
                let bg = try resolve(background, in: name)
                XCTAssertGreaterThanOrEqual(contrast(fg, bg), 4.5, "Contrast < 4.5 in \(name.rawValue)")
                XCTAssertEqual(bg.alphaComponent, 1)
            }
            let panel = try resolve(Theme.panel, in: name)
            for tint in tagTints {
                let fg = try resolve(tint, in: name)
                let tagBg = blend(fg, over: panel, alpha: 0.12)
                XCTAssertGreaterThanOrEqual(contrast(fg, tagBg), 4.5, "Tag contrast < 4.5 in \(name.rawValue)")
            }
        }
    }

    func testCanvasAndPanelsAreOpaqueInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for color in [Theme.canvas, Theme.panel, Theme.controlFill, Theme.selectedSurface, Theme.statusActiveFill] {
                XCTAssertEqual(try resolve(color, in: name).alphaComponent, 1)
            }
        }
    }

    func testControlFillUsesSoftWarmTonesInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let fill = try resolve(Theme.controlFill, in: name)
            XCTAssertGreaterThan(fill.redComponent, fill.greenComponent)
            XCTAssertGreaterThan(fill.greenComponent, fill.blueComponent)
            if name == .aqua {
                XCTAssertGreaterThan(fill.blueComponent, 0.85)
                XCTAssertLessThan(fill.redComponent - fill.blueComponent, 0.15)
            } else {
                XCTAssertLessThan(fill.redComponent, 0.25)
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
