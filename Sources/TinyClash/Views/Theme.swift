import AppKit
import SwiftUI

/// TinyClash 的视觉系统：画布 + 凸起面板、语义色、数字字体
enum Theme {
    enum Radius {
        static let panel: CGFloat = 14
        static let tile: CGFloat = 10
        static let chip: CGFloat = 6
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 不透明画布，避免桌面颜色透入菜单栏面板。
    static let canvas = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 0.105, green: 0.108, blue: 0.118, alpha: 1)
                 : NSColor(srgbRed: 0.955, green: 0.960, blue: 0.970, alpha: 1)
    })

    /// 不透明卡片底色，用明度区分画布与内容。
    static let panel = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 0.165, green: 0.168, blue: 0.180, alpha: 1) : .white
    })

    /// 卡片细描边，保留克制的层次。
    static let panelBorder = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.06)
    })

    /// 面板内的次级填充（未选中的磁贴、输入区）
    static let inset = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.055)
    })

    /// 基于 OrangePulse 渐变，向浅色端略微提亮的暖橙色。
    private static let accentColor = NSColor(srgbRed: 245 / 255, green: 123 / 255, blue: 63 / 255, alpha: 1)
    static let accent = Color(nsColor: accentColor)
    static let accentHighlight = Color(.sRGB, red: 1, green: 150 / 255, blue: 97 / 255, opacity: 1)
    /// 选中态使用浅杏色底与深暖橙文字；深色外观保留柔和的暖色层次。
    static let controlFill = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 73 / 255, green: 52 / 255, blue: 41 / 255, alpha: 1)
                 : NSColor(srgbRed: 252 / 255, green: 233 / 255, blue: 221 / 255, alpha: 1)
    })
    static let accentForeground = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 255 / 255, green: 211 / 255, blue: 183 / 255, alpha: 1)
                 : NSColor(srgbRed: 140 / 255, green: 67 / 255, blue: 28 / 255, alpha: 1)
    })

    /// 接管状态使用不透明底色，保持稳定的小字对比度。
    static let statusActive = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 167 / 255, green: 229 / 255, blue: 186 / 255, alpha: 1)
                 : NSColor(srgbRed: 20 / 255, green: 92 / 255, blue: 47 / 255, alpha: 1)
    })
    static let statusActiveFill = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 24 / 255, green: 61 / 255, blue: 38 / 255, alpha: 1)
                 : NSColor(srgbRed: 220 / 255, green: 238 / 255, blue: 226 / 255, alpha: 1)
    })

    static let chartLabel = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.36, alpha: 1)
    })

    static let download = Color(nsColor: .systemBlue)
    static let upload = Color(nsColor: .systemTeal)
    static let active = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)

    /// 测速是经代理的完整 HTTPS 往返，500ms 以内视为良好
    static func latency(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        switch ms {
        case 0: return failure
        case ..<500: return active
        case ..<1000: return warning
        default: return failure
        }
    }

    static func latencyText(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms > 0 ? "\(ms) ms" : "超时"
    }

    /// 实时数字（速度、流量、延迟）用圆体 + 等宽数字
    static func numeral(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// 不透明卡片面板，用细描边区分边界
struct PanelBackground: ViewModifier {
    var padding: CGFloat = Theme.Space.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
            )
    }
}

extension View {
    func panel(padding: CGFloat = Theme.Space.l) -> some View { modifier(PanelBackground(padding: padding)) }

    /// 可点击面板的悬停反馈
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.panel) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

struct HoverHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.045 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// 按下时轻微缩小变暗，用于面板内的大号可点击区域
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 面板标题行：标题 + 可选的右侧附属内容
struct PanelHeader<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: Theme.Space.s)
            accessory
        }
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// 小标签（类型、来源）
struct Tag: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// 延迟读数：彩色圆点 + 数字；未测速时显示 placeholder（为 nil 则不显示）
struct LatencyLabel: View {
    var ms: Int?
    var font: Font = Theme.numeral(11, weight: .medium)
    var placeholder: String? = nil

    var body: some View {
        if let ms {
            HStack(spacing: 4) {
                Circle().fill(Theme.latency(ms)).frame(width: 6, height: 6)
                Text(Theme.latencyText(ms)).font(font).foregroundStyle(Theme.latency(ms))
            }
        } else if let placeholder {
            Text(placeholder).font(font).foregroundStyle(.tertiary)
        }
    }
}
