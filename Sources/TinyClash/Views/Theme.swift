import AppKit
import SwiftUI

/// TinyClash 的视觉系统：画布 + 凸起面板、语义色、数字字体
enum Theme {
    enum Radius {
        static let panel: CGFloat = 14
        static let tile: CGFloat = 10
        /// 设置分组（PanelSection），对应 DESIGN.md 的 rounded.section
        static let section: CGFloat = 12
        static let chip: CGFloat = 6
    }

    enum Space {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    /// 不透明画布：深色为石墨炭黑，浅色为冷白灰，避免桌面颜色透入菜单栏面板。
    static let canvas = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 22 / 255, green: 23 / 255, blue: 26 / 255, alpha: 1)
                 : NSColor(srgbRed: 244 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    })

    /// 不透明卡片底色：与 AppIcon 石墨底一脉相承，用明度区分画布与内容。
    static let panel = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 33 / 255, green: 34 / 255, blue: 38 / 255, alpha: 1) : .white
    })

    /// 卡片细描边，保留克制的层次。
    static let panelBorder = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.07)
    })

    /// 面板内的次级填充（未选中的磁贴、轨道、输入区）
    static let inset = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.05)
    })

    /// 品牌色 OrangePulse（取自 AppIcon 脉冲点 #FF9661 → #F27234）。
    /// 深色外观直接用高辨识度的 #F57B3F；浅色外观适度加深至 #E05A1F 保持清晰边界（≥3.7:1）。
    private static let darkBrandAccent = NSColor(srgbRed: 245 / 255, green: 123 / 255, blue: 63 / 255, alpha: 1)
    private static let lightBrandAccent = NSColor(srgbRed: 224 / 255, green: 90 / 255, blue: 31 / 255, alpha: 1)
    static let accent = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? darkBrandAccent : lightBrandAccent
    })
    /// AppIcon 脉冲点渐变两端：高光 #FF9661 与主色 #F27234。
    static let accentHighlight = Color(.sRGB, red: 255 / 255, green: 150 / 255, blue: 97 / 255, opacity: 1)
    static let brandPulseBottom = Color(.sRGB, red: 242 / 255, green: 114 / 255, blue: 52 / 255, opacity: 1)

    /// 设置页开关与行内操作统一沿用品牌色体系。
    static let settingsControlTint = accent
    static let settingsActionForeground = accentForeground
    /// 设置页开关关闭时的轨道
    static let settingsSwitchOffTrack = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.12)
    })

    /// 凸起选中面（当前标签、模式滑块、路由终点、颜色模式滑块）：深色用冷冽石墨灰 #2F3137，避免发棕发闷；浅色用纯白。
    static let selectedSurface = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 47 / 255, green: 49 / 255, blue: 55 / 255, alpha: 1) : .white
    })
    /// 暖橙轻填底（选中节点卡、设置行内按钮）：浅色为柔白杏 #FFF2EB，深色为深炭暖灰 #2D231E，与橙字均保持 ≥5:1 对比度。
    static let controlFill = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 45 / 255, green: 35 / 255, blue: 30 / 255, alpha: 1)
                 : NSColor(srgbRed: 255 / 255, green: 242 / 255, blue: 235 / 255, alpha: 1)
    })
    /// 已开启的开关卡片：品牌橙色系立体渐变（#D45218 → #BC4210），保持白字清晰可读。
    static let activeTileGradient = LinearGradient(
        colors: [Color(.sRGB, red: 212 / 255, green: 82 / 255, blue: 24 / 255, opacity: 1),
                 Color(.sRGB, red: 188 / 255, green: 66 / 255, blue: 16 / 255, opacity: 1)],
        startPoint: .top, endPoint: .bottom)
    /// 已开启开关卡片的顶部微高光描边，增强质感层次。
    static let activeTileStroke = LinearGradient(
        colors: [Color.white.opacity(0.24), Color.white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom)
    /// 开关卡片投影：仅浅色外观使用柔和橙影；深色背景上不发光。
    static let activeTileShadow = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? .clear : NSColor(srgbRed: 212 / 255, green: 82 / 255, blue: 24 / 255, alpha: 0.26)
    })
    /// 品牌橙文字与小图标：深色 #FF8E53（在画布/卡片/选中面均 ≥5.7:1），浅色 #B8410C（≥5.0:1）。
    static let accentForeground = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 255 / 255, green: 142 / 255, blue: 83 / 255, alpha: 1)
                 : NSColor(srgbRed: 184 / 255, green: 65 / 255, blue: 12 / 255, alpha: 1)
    })

    /// 接管状态使用不透明翡翠底色，保持稳定的小字对比度。
    static let statusActive = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 155 / 255, green: 232 / 255, blue: 184 / 255, alpha: 1)
                 : NSColor(srgbRed: 20 / 255, green: 94 / 255, blue: 47 / 255, alpha: 1)
    })
    static let statusActiveFill = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 24 / 255, green: 59 / 255, blue: 39 / 255, alpha: 1)
                 : NSColor(srgbRed: 220 / 255, green: 242 / 255, blue: 228 / 255, alpha: 1)
    })

    static let chartLabel = Color(nsColor: NSColor(name: nil) { a in
        a.isDark ? NSColor(srgbRed: 158 / 255, green: 163 / 255, blue: 173 / 255, alpha: 1)
                 : NSColor(srgbRed: 91 / 255, green: 96 / 255, blue: 106 / 255, alpha: 1)
    })

    /// 调和后的语义色：深浅外观均针对各自面板底色精确校准（含 12% 标签底均 ≥4.5:1），
    /// 并与品牌橙（H≈20°）在色相上明确区分（警示偏琥珀金 H≈38°，下载蓝与上传青拉开色距）。
    private static func adaptive(dark dr: CGFloat, _ dg: CGFloat, _ db: CGFloat,
                                 light lr: CGFloat, _ lg: CGFloat, _ lb: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.isDark ? NSColor(srgbRed: dr / 255, green: dg / 255, blue: db / 255, alpha: 1)
                     : NSColor(srgbRed: lr / 255, green: lg / 255, blue: lb / 255, alpha: 1)
        })
    }

    static let toolbarHoverForeground = adaptive(dark: 255, 167, 120, light: 152, 50, 7)
    static let download = adaptive(dark: 77, 163, 255, light: 10, 102, 208)
    static let upload = adaptive(dark: 50, 210, 196, light: 0, 118, 123)
    static let active = adaptive(dark: 69, 212, 131, light: 21, 118, 54)
    static let warning = adaptive(dark: 245, 180, 59, light: 153, 94, 0)
    private static let indigo = adaptive(dark: 142, 144, 255, light: 78, 72, 198)
    private static let purple = adaptive(dark: 196, 132, 250, light: 135, 56, 184)
    private static let pink = adaptive(dark: 248, 114, 157, light: 192, 34, 90)
    /// 警示文字与图标统一使用琥珀金，与品牌橙色相明确区分且双外观均 ≥4.5:1
    static let warningText = warning
    static let failure = adaptive(dark: 255, 100, 103, light: 204, 31, 44)

    /// 策略名的颜色：直连绿、拒绝红，其余用主文字色。橙色只表示「已开启 / 已选中」，不给普通策略名
    static func policyTint(_ policy: String) -> Color {
        switch policy.uppercased() {
        case "DIRECT": return active
        case "REJECT", "REJECT-DROP": return failure
        case "未知策略": return .secondary
        default: return .primary
        }
    }

    /// 请求日志中最终出站节点的颜色：直连绿、拒绝红、代理节点用暖橙强调色，与前置策略组区分
    static func outboundNodeTint(_ node: String) -> Color {
        switch node.uppercased() {
        case "DIRECT": return active
        case "REJECT", "REJECT-DROP": return failure
        case "COMPATIBLE", "PASS", "未知策略": return .secondary
        default: return accentForeground
        }
    }

    /// 传输层协议标签颜色：TCP 蓝、UDP 青
    static func networkTint(_ network: String) -> Color {
        switch network.lowercased() {
        case "tcp": return download
        case "udp": return upload
        default: return .secondary
        }
    }

    /// 规则类型按匹配对象分色：域名蓝、IP 靛、规则集紫、兜底 MATCH 粉，其余中性
    static func ruleTypeTint(_ yamlType: String) -> Color {
        if yamlType.hasPrefix("DOMAIN") || yamlType == "GEOSITE" { return download }
        if yamlType.hasPrefix("IP") || yamlType.hasPrefix("SRC-IP") || yamlType == "GEOIP" { return indigo }
        if yamlType == "RULE-SET" { return purple }
        if yamlType == "MATCH" { return pink }
        return .secondary
    }

    /// 策略组类型：手动是默认类型，保持中性；自动类按策略分色
    static func groupTypeTint(_ apiType: String) -> Color {
        switch apiType {
        case "Selector": return .secondary
        case "URLTest": return download
        case "Fallback": return upload
        case "LoadBalance": return indigo
        default: return .secondary
        }
    }

    /// 规则集来源：远程青、本地靛、内联粉
    static func ruleProviderSourceTint(_ type: String) -> Color {
        switch type {
        case "http": return upload
        case "file": return indigo
        case "inline": return pink
        default: return .secondary
        }
    }

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

    /// 各标签页顶部工具栏与子页面顶部栏（返回、标题、保存）共用的字号
    static let toolbarFont: Font = .subheadline

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

    /// 列表顶部工具栏的文字操作：统一图标 + 文字；主操作用暖橙文字色，其余用主文字色。
    /// 不直接用 OrangePulse 作文字色，它在浅色画布上的小字对比度只有约 2.6:1。
    func toolbarAction(prominent: Bool = false) -> some View {
        modifier(ToolbarActionStyle(prominent: prominent))
    }

    /// 列表卡片：面板底色 + tile 圆角 + 细描边
    func card(cornerRadius: CGFloat = Theme.Radius.tile) -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
            )
    }

    /// 设置行内的可编辑文本框：浅色内嵌底，与只读数值区分开
    func panelField(alignment: TextAlignment = .trailing) -> some View {
        textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }

    @ViewBuilder
    func selectionStretch(on selection: some Equatable, reduceMotion: Bool, amplitude: CGFloat = 0.14) -> some View {
        if reduceMotion {
            self
        } else {
            keyframeAnimator(initialValue: CGFloat.zero, trigger: selection) { indicator, stretch in
                indicator.scaleEffect(x: 1 + stretch, y: 1 - stretch / 2)
            } keyframes: { _ in
                CubicKeyframe(amplitude, duration: 0.08)
                SpringKeyframe(0, duration: 0.24, spring: .snappy)
            }
        }
    }

    /// 可点击面板的悬停反馈
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.panel, enabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, enabled: enabled))
    }
}

struct HoverHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var cornerRadius: CGFloat
    var enabled: Bool = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled && enabled ? 0.045 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .onChange(of: isEnabled) { if !isEnabled { hovering = false } }
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

/// 设置页开关。菜单栏面板所在的 App 通常不是激活状态，原生开关会按非激活外观画成灰滑块、暗橙轨道，
/// 所以这里自绘，颜色不随窗口激活状态变化
struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Capsule()
            .fill(on ? Theme.settingsControlTint : Theme.settingsSwitchOffTrack)
            .frame(width: 32, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: on)
            // 辅助功能沿用原生开关的语义和标签
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

/// 设置页行内操作按钮：不透明柔橙底 + 细橙描边 + 高对比橙字，深浅外观皆清透利落
struct SettingsActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.settingsActionForeground) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                shape.fill(isEnabled ? AnyShapeStyle(Theme.controlFill) : AnyShapeStyle(Theme.inset))
                    .overlay(
                        shape.fill(Theme.accent.opacity(isEnabled && configuration.isPressed ? 0.14 : 0))
                    )
                    .overlay(
                        shape.strokeBorder(isEnabled ? Theme.accent.opacity(0.28) : .clear, lineWidth: 0.5)
                    )
            )
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SettingsActionStyle {
    static var settingsAction: SettingsActionStyle { SettingsActionStyle() }
}

struct ToolbarActionStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var prominent: Bool

    func body(content: Content) -> some View {
        content
            .labelStyle(.titleAndIcon)
            .foregroundStyle(!isEnabled ? AnyShapeStyle(.tertiary)
                             : hovering ? AnyShapeStyle(Theme.toolbarHoverForeground)
                             : prominent ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .onChange(of: isEnabled) { if !isEnabled { hovering = false } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEnabled)
    }
}

/// 列表区域的加载占位，与 EmptyHint 对应
struct LoadingHint: View {
    var text: String
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 小标签（类型、来源）；警示类标签带图标，不只靠颜色区分
struct Tag: View {
    var text: String
    var tint: Color = .secondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .fixedSize()
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
