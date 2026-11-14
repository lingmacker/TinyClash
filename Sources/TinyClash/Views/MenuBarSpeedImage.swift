import AppKit

/// 参考 TinyNet：固定宽度的双行网速模板图，避免菜单栏随数字变化跳动。
@MainActor
enum MenuBarSpeedImage {
    static let speedSize = NSSize(width: 66, height: 22)
    static let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
    private static let iconSize: CGFloat = 18
    private static let iconSpacing: CGFloat = 4
    private static var lastText: String?
    private static var lastActive: Bool?
    private static var lastImage: NSImage?

    /// mihomo 提供 bytes/s；菜单栏从 KB/s 起，保留两位小数和最小六字符数值宽度。
    static func formattedSpeed(_ bytesPerSecond: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(max(0, bytesPerSecond)) / 1024
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%6.2f%@/s", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }

    static func text(upload: Int64, download: Int64) -> String {
        "↑ \(formattedSpeed(upload))\n↓ \(formattedSpeed(download))"
    }

    static func image(upload: Int64, download: Int64, active: Bool) -> NSImage {
        let text = text(upload: upload, download: download)
        if text == lastText, active == lastActive, let lastImage { return lastImage }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let icon = NSImage(named: active ? "MenuBarIcon" : "MenuBarIconIdle")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        let textX = iconSize + iconSpacing
        let image = NSImage(size: NSSize(width: textX + speedSize.width, height: speedSize.height),
                            flipped: false) { rect in
            icon?.draw(in: NSRect(x: 0, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize),
                       from: .zero, operation: .sourceOver, fraction: 1)
            text.draw(in: NSRect(x: textX, y: 0, width: speedSize.width, height: speedSize.height),
                      withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        lastText = text
        lastActive = active
        lastImage = image
        return image
    }
}
