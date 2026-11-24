import Charts
import SwiftUI

struct HomeTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // 面板高度固定：放得下时不套滚动视图，流量图吸收剩余空间，正好撑满且没有滚动条；
        // 出现错误横幅等内容放不下时才退回可滚动的版本
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.profiles.isEmpty {
                emptyState
            } else {
                controls
                // 停止后流量面板保留，读数归零、端口显示「—」，避免主页布局随内核启停跳动
                TrafficPanel()
                TopProcessesPanel()
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 主开关

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 内核未运行时系统代理已被撤销、TUN 也随内核关闭，开关显示为关闭；偏好仍保留，内核启动后自动恢复
            HStack(spacing: Theme.Space.s) {
                ToggleTile(title: "系统代理", icon: "network", isOn: state.isRunning && state.systemProxyEnabled, enabled: state.isRunning) {
                    await state.setSystemProxy($0)
                }
                ToggleTile(title: "TUN", icon: "shield.lefthalf.filled", isOn: state.isRunning && state.tunActive, enabled: state.isRunning) {
                    await state.setTun($0)
                }
            }
            ModePicker(selection: state.currentMode, enabled: state.isRunning) { mode in
                Task { await state.setMode(mode) }
            }

            switch state.coreState {
            case .running:
                route
            case .starting, .stopped:
                // 停止和启动过程中保留最后的出站路径，和上方开关一样变暗表示未生效；没有可显示的路径时不占位
                if state.displayedRoute != nil {
                    RouteRibbon(compact: true)
                        .padding(.vertical, 4) // 与运行时可点击版本同高，启停时布局不跳动
                        .opacity(0.5)
                }
            case .failed(let msg):
                notice(msg, action: ("重启内核", { Task { await state.restartCore() } }), isError: true)
            }
        }
    }

    /// 出站路径可点击，直接进入主策略组换节点，省去「策略 → 分组」两步
    @ViewBuilder private var route: some View {
        if let group = state.primaryGroup {
            Button { state.openGroupRequest = group.name } label: {
                HStack(spacing: Theme.Space.s) {
                    RouteRibbon(compact: true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .hoverHighlight(cornerRadius: Theme.Radius.tile)
            }
            .buttonStyle(PressableStyle())
            .padding(.horizontal, -6)
            .help("在「策略」中打开「\(group.name)」切换节点")
            .accessibilityLabel("当前出站路径：\(state.routeChain.joined(separator: "、"))")
            .accessibilityHint("打开策略组切换节点")
        } else {
            RouteRibbon(compact: true)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SpeedReadout(label: "下载", icon: "arrow.down", value: state.downSpeed, tint: Theme.download, size: 17)
                Spacer()
                SpeedReadout(label: "上传", icon: "arrow.up", value: state.upSpeed, tint: Theme.upload, size: 17)
                    .frame(width: 130, alignment: .leading)
            }
            TrafficChart(points: state.trafficHistory).frame(minHeight: 36, idealHeight: 40, maxHeight: .infinity)
            HStack(spacing: 0) {
                fact("连接", "\(state.connections.count)")
                fact("内存", Format.bytes(state.memory))
                fact("累计", Format.bytes(state.downloadTotal + state.uploadTotal))
                fact("端口", state.runtime.map { $0.httpPort > 0 ? "\($0.httpPort)" : "—" } ?? "—")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(Theme.numeral(12, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 当前占用网速最大的四个进程：固定四行高度，避免流量在 0~4 个进程间波动时导致上方图表跳动
private struct TopProcessesPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maxVisibleCount = 4
    private let speedColumnWidth: CGFloat = 66
    private let rowHeight: CGFloat = 20
    private let rowSpacing: CGFloat = 2

    private var listHeight: CGFloat {
        rowHeight * CGFloat(maxVisibleCount) + rowSpacing * CGFloat(maxVisibleCount - 1)
    }

    var body: some View {
        let items = Array(state.topProcesses.prefix(maxVisibleCount))
        let maxSpeed = max(items.first?.totalSpeed ?? 1, 1)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("进程网速")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down").font(.system(size: 8.5, weight: .semibold))
                    Text("下载").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.download)
                .frame(width: speedColumnWidth, alignment: .trailing)
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up").font(.system(size: 8.5, weight: .semibold))
                    Text("上传").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.upload)
                .frame(width: speedColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, 2)

            Divider().opacity(0.6)

            if !state.isRunning {
                emptyPlaceholder("内核未运行", icon: "pause.circle")
            } else if items.isEmpty {
                emptyPlaceholder("暂无活跃流量", icon: "arrow.up.arrow.down")
            } else {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(items) { item in
                        row(item: item, share: CGFloat(item.totalSpeed) / CGFloat(maxSpeed))
                    }
                }
                .frame(height: listHeight, alignment: .top)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
        .opacity(state.isRunning ? 1 : 0.72)
    }

    private func emptyPlaceholder(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
            Text(text).font(.caption)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: listHeight, maxHeight: listHeight)
    }

    private func row(item: ProcessTrafficItem, share: CGFloat) -> some View {
        let clampedShare = max(0.06, min(1, share))
        let barTint = item.downloadSpeed >= item.uploadSpeed ? Theme.download : Theme.upload
        let barOpacity = colorScheme == .dark ? 0.14 : 0.085
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)

        return HStack(spacing: 6) {
            ProcessRowIcon(name: item.name, path: item.processPath)
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            speedText(item.downloadSpeed)
            speedText(item.uploadSpeed)
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background {
            GeometryReader { geo in
                shape
                    .fill(barTint.opacity(barOpacity))
                    .frame(width: geo.size.width * clampedShare)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: clampedShare)
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .hoverHighlight(cornerRadius: Theme.Radius.chip)
        .padding(.horizontal, -4)
        .help(tooltip(for: item))
        .contextMenu {
            Button("复制进程名") { state.copy(item.name, message: "已复制进程名") }
            if let path = item.processPath {
                Button("复制进程路径") { state.copy(path, message: "已复制进程路径") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，下载 \(Format.speed(item.downloadSpeed))，上传 \(Format.speed(item.uploadSpeed))")
    }

    private func speedText(_ value: Int64) -> some View {
        Text(value > 0 ? Format.speed(value) : "—")
            .font(Theme.numeral(10.5, weight: value > 0 ? .medium : .regular))
            .foregroundStyle(value > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .contentTransition(.numericText())
            .frame(width: speedColumnWidth, alignment: .trailing)
    }

    private func tooltip(for item: ProcessTrafficItem) -> String {
        var lines = [item.name]
        if let path = item.processPath { lines.append(path) }
        lines.append("下载 \(Format.speed(item.downloadSpeed)) · 上传 \(Format.speed(item.uploadSpeed)) · \(item.connectionCount) 个连接")
        return lines.joined(separator: "\n")
    }
}

private struct ProcessRowIcon: View {
    let name: String
    let path: String?

    var body: some View {
        if let image = ProcessIconCache.shared.icon(forName: name, path: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Theme.inset)
                Image(systemName: ProcessIconCache.fallbackSymbol(forName: name, path: path))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 14, height: 14)
        }
    }
}

private struct ModePicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
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
                        .matchedGeometryEffect(id: mode, in: namespace)
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile - 2, style: .continuous))
                        .hoverHighlight(cornerRadius: Theme.Radius.tile - 2)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.tile - 2, style: .continuous)
                .fill(Theme.selectedSurface)
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                .selectionStretch(on: selection, reduceMotion: reduceMotion, amplitude: 0.28)
                .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
                .allowsHitTesting(false)
        }
        .padding(3)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
        .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.16), value: selection)
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
