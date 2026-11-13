import SwiftUI

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
                    Circle().fill(isOn ? Color.white.opacity(0.22) : Theme.inset)
                    if working {
                        ProgressView().controlSize(.small).tint(isOn ? .white : nil)
                    } else {
                        Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(isOn ? "已开启" : "已关闭").font(.caption)
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
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

/// 状态指示：接管中 / 未接管 / 内核状态
struct StatusBadge: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var text: String {
        switch state.coreState {
        case .running: return state.isProxying ? "接管中" : "未接管流量"
        case .starting: return "启动中"
        case .stopped: return "内核已停止"
        case .failed: return "内核异常"
        }
    }

    private var color: Color {
        switch state.coreState {
        case .running: return state.isProxying ? Theme.active : .secondary
        case .starting: return Theme.warning
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
    var size: CGFloat = 26

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
