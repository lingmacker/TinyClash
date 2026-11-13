import Charts
import SwiftUI

struct HomeTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if state.profiles.isEmpty {
                        emptyState
                    } else {
                        controls
                        if state.isRunning { traffic }
                        actions
                    }
                }
                .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
    }

    private var footer: some View {
        HStack {
            Link("配置文档", destination: URL(string: "https://wiki.metacubex.one/config/")!)
                .font(.caption)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .semibold))
                    Text("退出 TinyClash")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - 主开关

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                ToggleTile(title: "系统代理", icon: "network", isOn: state.systemProxyEnabled, enabled: state.isRunning) {
                    await state.setSystemProxy($0)
                }
                ToggleTile(title: "TUN", icon: "shield.lefthalf.filled", isOn: state.tunEnabled, enabled: state.isRunning) {
                    await state.setTun($0)
                }
            }
            Picker("出站模式", selection: Binding(
                get: { state.currentMode },
                set: { m in Task { await state.setMode(m) } }
            )) {
                ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!state.isRunning)

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

    // MARK: - 流量

    private var traffic: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            HStack(alignment: .firstTextBaseline) {
                SpeedReadout(label: "下载", icon: "arrow.down", value: state.downSpeed, tint: Theme.download, size: 20)
                Spacer()
                SpeedReadout(label: "上传", icon: "arrow.up", value: state.upSpeed, tint: Theme.upload, size: 20)
                    .frame(width: 130, alignment: .leading)
            }
            TrafficChart(points: state.trafficHistory).frame(height: 72)
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
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: Theme.Radius.tile)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "paperplane.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("添加一个配置开始使用").font(.headline)
            Text("在「配置」中添加订阅链接，或导入 mihomo 官方格式的 YAML 文件")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("导入配置文件…") { Task { await state.importProfileFromFile() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
