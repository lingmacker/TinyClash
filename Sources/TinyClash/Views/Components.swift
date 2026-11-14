import SwiftUI

/// TinyClash 品牌几何标志：阶跃流柱（三枚斜切胶囊 + 脉冲节点）
struct TinyClashMark: Shape {
    private static func transform(in rect: CGRect) -> CGAffineTransform {
        let s = min(rect.width, rect.height)
        let scale = s / 1024.0 * 1.34
        let rad = -24.0 * CGFloat.pi / 180.0
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: rad)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -512, y: -512)
    }

    static func secondaryPath(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 266, y: 346, width: 124, height: 360),
                         cornerSize: CGSize(width: 62, height: 62),
                         transform: transform(in: rect))
        return p
    }

    static func primaryPath(in rect: CGRect) -> Path {
        let t = transform(in: rect)
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 450, y: 226, width: 124, height: 386), cornerSize: CGSize(width: 62, height: 62), transform: t)
        p.addRoundedRect(in: CGRect(x: 634, y: 308, width: 124, height: 332), cornerSize: CGSize(width: 62, height: 62), transform: t)
        return p
    }

    static func pulsePath(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 450, y: 692, width: 124, height: 124), transform: transform(in: rect))
        return p
    }

    func path(in rect: CGRect) -> Path {
        var p = Self.secondaryPath(in: rect)
        p.addPath(Self.primaryPath(in: rect))
        p.addPath(Self.pulsePath(in: rect))
        return p
    }
}

/// 面板左上角品牌徽章：石墨底 + 银白流柱 + 暖橙脉冲点（未接管时退为柔和磨砂态）
struct TinyClashBadge: View {
    var active: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    active
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Color(red: 0.215, green: 0.220, blue: 0.235),
                                 Color(red: 0.145, green: 0.149, blue: 0.161)],
                        startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Theme.inset)
                )
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? Color.white.opacity(0.14) : Theme.panelBorder, lineWidth: 0.5)
            ZStack {
                TinyClashLayerShape(kind: .secondary)
                    .fill(active ? AnyShapeStyle(Color(red: 0.76, green: 0.79, blue: 0.84))
                                 : AnyShapeStyle(.secondary.opacity(0.65)))
                TinyClashLayerShape(kind: .primary)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(
                              colors: [Color(red: 0.973, green: 0.969, blue: 0.953),
                                       Color(red: 0.843, green: 0.863, blue: 0.886)],
                              startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(.secondary))
                TinyClashLayerShape(kind: .pulse)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(
                              colors: [Theme.accentHighlight, Theme.accent],
                              startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(.tertiary))
            }
            .frame(width: 19, height: 19)
        }
        .frame(width: 30, height: 30)
    }
}

private struct TinyClashLayerShape: Shape {
    enum Kind { case secondary, primary, pulse }
    var kind: Kind

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .secondary: return TinyClashMark.secondaryPath(in: rect)
        case .primary: return TinyClashMark.primaryPath(in: rect)
        case .pulse: return TinyClashMark.pulsePath(in: rect)
        }
    }
}

/// 大号开关磁贴：系统代理 / TUN
struct ToggleTile: View {
    var title: String
    var icon: String
    var isOn: Bool
    var enabled: Bool = true
    var action: (Bool) async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var working = false

    var body: some View {
        Button {
            working = true
            Task {
                await action(!isOn)
                working = false
            }
        } label: {
            HStack(spacing: Theme.Space.s + 2) {
                ZStack {
                    Circle().fill(isOn ? Theme.accentForeground.opacity(0.08) : Theme.inset)
                    if working {
                        ProgressView().controlSize(.small).tint(isOn ? Theme.accentForeground : nil)
                    } else {
                        Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(isOn ? "已开启" : "已关闭").font(.caption)
                        .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.primary))
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(Theme.controlFill) : AnyShapeStyle(Theme.inset))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOn)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled || working)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

/// 路由带：模式 → 分组 → … → 节点 · 延迟
struct RouteRibbon: View {
    @Environment(AppState.self) private var state
    var compact = false

    var body: some View {
        let chain = state.routeChain
        HStack(spacing: compact ? 5 : 6) {
            if !compact { segment(state.currentMode.title + "模式", systemImage: modeIcon, emphasis: false) }
            if state.currentMode == .direct {
                if !compact { arrow }
                segment("所有流量直连", systemImage: nil, emphasis: true)
            } else if chain.isEmpty {
                if !compact { arrow }
                Text(state.proxies.isEmpty ? "加载策略组…" : "暂无策略组").font(font).foregroundStyle(.secondary)
            } else {
                ForEach(Array(chain.enumerated()), id: \.offset) { i, name in
                    if i > 0 || !compact { arrow }
                    segment(name, systemImage: nil, emphasis: i == chain.count - 1)
                }
                if let last = chain.last {
                    LatencyLabel(ms: state.delay(of: last), font: Theme.numeral(compact ? 11 : 12, weight: .medium))
                        .padding(.leading, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .help("当前出站路径：从主策略组（\(state.primaryGroup?.name ?? "—")）解析到最终节点")
    }

    private var font: Font { compact ? .caption : .callout }

    private var modeIcon: String {
        switch state.currentMode {
        case .rule: return "arrow.triangle.branch"
        case .global: return "globe"
        case .direct: return "arrow.right"
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: compact ? 8 : 9, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func segment(_ text: String, systemImage: String?, emphasis: Bool) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: compact ? 10 : 11, weight: .semibold)) }
            Text(text).font(emphasis ? .callout.weight(.semibold) : font)
                .layoutPriority(emphasis ? 1 : 0)
        }
        .foregroundStyle(emphasis ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(emphasis ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Theme.inset),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .truncationMode(.middle)
        .layoutPriority(emphasis ? 1 : 0)
    }
}

struct PanelConfirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var action: @MainActor () -> Void
}

/// 绘制在面板内部的确认框：遮住面板内容，⎋ 取消；破坏性按钮不绑定回车，避免误删
struct ConfirmationOverlay: View {
    @Environment(AppState.self) private var state
    let confirmation: PanelConfirmation

    var body: some View {
        ZStack {
            Theme.canvas.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { state.confirmation = nil }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(confirmation.title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(confirmation.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Space.s) {
                    Button { state.confirmation = nil } label: { Text("取消").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button(role: .destructive) {
                        state.confirmation = nil
                        confirmation.action()
                    } label: {
                        // 红色文字不依赖窗口是否激活；系统的醒目样式在非活动窗口里会变灰
                        Text(confirmation.confirmTitle).fontWeight(.semibold).foregroundStyle(Theme.failure)
                            .frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(Theme.Space.l)
            .frame(width: 290)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
            )
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 18, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// 状态指示：接管中 / 未接管 / 需重启生效 / 内核状态
struct StatusBadge: View {
    @Environment(AppState.self) private var state

    private var needsRestart: Bool {
        state.coreState == .running && state.needsCoreRestart && !state.restarting && !state.quitting
    }

    var body: some View {
        if needsRestart {
            Button { Task { await state.applyPendingChanges() } } label: {
                badge.hoverHighlight(cornerRadius: 999)
            }
            .buttonStyle(PressableStyle())
            .help("配置已修改，点击重新加载配置以应用更改；重新加载失败时会重启内核")
            .accessibilityLabel("需重启生效，点击应用更改")
        } else {
            badge
        }
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.isProxying && !needsRestart && !state.restarting && !state.quitting
                    ? Theme.statusActiveFill : color.opacity(0.12), in: Capsule())
    }

    private var text: String {
        if state.quitting { return "关闭中" }
        if state.restarting { return "重启中" }
        switch state.coreState {
        case .running:
            if state.needsCoreRestart { return "需重启生效" }
            return state.isProxying ? "接管中" : "未接管流量"
        case .starting: return "启动中"
        case .stopped: return "内核已停止"
        case .failed: return "内核异常"
        }
    }

    private var color: Color {
        if state.quitting { return .secondary }
        if state.restarting { return Theme.warningText }
        switch state.coreState {
        case .running:
            if state.needsCoreRestart { return Theme.warningText }
            return state.isProxying ? Theme.statusActive : .secondary
        case .starting: return Theme.warningText
        case .stopped: return .secondary
        case .failed: return Theme.failure
        }
    }
}

/// 上下行速度读数
struct SpeedReadout: View {
    var label: String
    var icon: String
    var value: Int64
    var tint: Color
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            Text(Format.speed(value))
                .font(Theme.numeral(size))
                .contentTransition(.numericText())
        }
    }
}
