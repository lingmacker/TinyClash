import Charts
import SwiftUI

struct HomeTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // 面板高度固定：内容至少撑满可视高度，流量图吸收剩余空间，底部不留空白；
        // 出现错误横幅等内容放不下时仍可滚动
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if state.profiles.isEmpty {
                        emptyState
                    } else {
                        controls
                        if state.isRunning {
                            TrafficPanel()
                        } else {
                            Spacer(minLength: 0)
                        }
                        actions
                    }
                }
                .padding(14)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - 主开关

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                ToggleTile(title: "系统代理", icon: "network", isOn: state.systemProxyEnabled, enabled: state.isRunning) {
                    await state.setSystemProxy($0)
                }
                ToggleTile(title: "TUN", icon: "shield.lefthalf.filled", isOn: state.tunActive, enabled: state.isRunning) {
                    await state.setTun($0)
                }
            }
            ModePicker(selection: state.currentMode, enabled: state.isRunning) { mode in
                Task { await state.setMode(mode) }
            }

            switch state.coreState {
            case .running:
                RouteRibbon(compact: true)
            case .starting:
                notice("内核启动中…", action: nil)
            case .stopped:
                notice("内核未运行", action: ("启动内核", { Task { await state.startCore() } }))
            case .failed(let msg):
                notice(msg, action: ("重启内核", { Task { await state.restartCore() } }), isError: true)
            }
        }
    }

    private func notice(_ text: String, action: (String, () -> Void)?, isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            if isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.failure).font(.system(size: 12))
            }
            Text(text).font(.caption).foregroundStyle(isError ? .primary : .secondary).lineLimit(3)
            Spacer(minLength: Theme.Space.s)
            if let action {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
        .padding(10)
        .background(isError ? AnyShapeStyle(Theme.failure.opacity(0.1)) : AnyShapeStyle(Theme.inset),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    // MARK: - 快捷操作

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            action("复制代理命令", icon: "terminal", enabled: state.isRunning) { state.copyTerminalCommand() }
                .help(state.terminalProxyCommand)
            action("Web 面板", icon: "safari", enabled: state.isRunning) {
                if let url = state.dashboardURL { NSWorkspace.shared.open(url) }
            }
            .help("在 metacubexd 中查看连接、规则与日志")
            action(state.isRunning ? "重启内核" : "启动内核", icon: "arrow.clockwise", enabled: state.coreState != .starting) {
                Task { await state.restartCore() }
            }
        }
    }

    private func action(_ title: String, icon: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .card()
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: Theme.Radius.tile)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            TinyClashMark()
                .frame(width: 38, height: 38)
                .foregroundStyle(.secondary)
            Text("添加一个配置开始使用").font(.headline)
            Text("添加订阅链接，或导入 mihomo 官方格式的 YAML 文件")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.s) {
                Button("添加订阅…") { state.addSubscriptionRequest = "" }
                    .buttonStyle(.borderedProminent)
                Button("导入配置文件…") { Task { await state.importProfileFromFile() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 流量面板单独成视图：每秒更新的速度、连接数和内存只让这一块重算
private struct TrafficPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            HStack(alignment: .firstTextBaseline) {
                SpeedReadout(label: "下载", icon: "arrow.down", value: state.downSpeed, tint: Theme.download)
                Spacer()
                SpeedReadout(label: "上传", icon: "arrow.up", value: state.upSpeed, tint: Theme.upload)
                    .frame(width: 130, alignment: .leading)
            }
            TrafficChart(points: state.trafficHistory).frame(minHeight: 72, maxHeight: .infinity)
            HStack(spacing: 0) {
                fact("连接", "\(state.connections.count)")
                fact("内存", Format.bytes(state.memory))
                fact("累计", Format.bytes(state.downloadTotal + state.uploadTotal))
                fact("端口", state.runtime.map { $0.httpPort > 0 ? "\($0.httpPort)" : "—" } ?? "—")
            }
        }
        .panel(padding: 12)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(Theme.numeral(12, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModePicker: View {
    var selection: ProxyMode
    var enabled: Bool
    var onSelect: (ProxyMode) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ProxyMode.allCases) { mode in
                let selected = mode == selection
                Button {
                    guard !selected else { return }
                    onSelect(mode)
                } label: {
                    Text(mode.title)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.tile - 2, style: .continuous)
                                .fill(selected ? AnyShapeStyle(Theme.controlFill) : AnyShapeStyle(.clear))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile - 2, style: .continuous))
                        .hoverHighlight(cornerRadius: Theme.Radius.tile - 2)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct TrafficChart: View {
    var points: [TrafficPoint]

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("t", p.id), y: .value("速度", p.down), series: .value("方向", "下载"))
                    .foregroundStyle(LinearGradient(colors: [Theme.download.opacity(0.3), Theme.download.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.id), y: .value("速度", p.down), series: .value("方向", "下载"))
                    .foregroundStyle(Theme.download)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.id), y: .value("速度", p.up), series: .value("方向", "上传"))
                    .foregroundStyle(Theme.upload)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let n = v.as(Int64.self) { Text(Format.compactSpeed(n)).font(.system(size: 10)).foregroundStyle(Theme.chartLabel) } }
            }
        }
        .chartLegend(.hidden)
        .animation(nil, value: points.count)
    }
}
