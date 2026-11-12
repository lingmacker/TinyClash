import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    statusCard
                    switchesCard
                }
                HStack(spacing: 14) {
                    StatTile(title: "下载速度", value: Format.speed(state.downSpeed), icon: "arrow.down", tint: .blue)
                    StatTile(title: "上传速度", value: Format.speed(state.upSpeed), icon: "arrow.up", tint: .purple)
                    StatTile(title: "下载总量", value: Format.bytes(state.downloadTotal), icon: "tray.and.arrow.down", tint: .teal)
                    StatTile(title: "上传总量", value: Format.bytes(state.uploadTotal), icon: "tray.and.arrow.up", tint: .indigo)
                }
                Card(title: "实时流量") { TrafficChart(points: state.trafficHistory).frame(height: 180) }
                HStack(alignment: .top, spacing: 14) {
                    StatTile(title: "活动连接", value: "\(state.connections.count)", icon: "link", tint: .orange)
                    StatTile(title: "内核内存", value: Format.bytes(state.memory), icon: "memorychip", tint: .pink)
                }
                infoCard
            }
            .padding(18)
        }
    }

    private var statusCard: some View {
        Card(title: "内核") {
            LabeledContent("状态", value: state.coreState.label)
            LabeledContent("版本", value: state.coreVersion.isEmpty ? "-" : state.coreVersion)
            LabeledContent("当前配置", value: state.selectedProfile?.name ?? "未选择")
            LabeledContent("管理员授权", value: state.isPrivileged ? "已授权" : "未授权")
            if case .failed(let msg) = state.coreState {
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }
            HStack {
                Button(state.isRunning ? "重启内核" : "启动内核") { Task { await state.restartCore() } }
                if state.isRunning {
                    Button("停止") { Task { await state.stopCore() } }
                }
            }
        }
    }

    private var switchesCard: some View {
        Card(title: "代理") {
            Toggle("系统代理", isOn: Binding(
                get: { state.systemProxyEnabled },
                set: { v in Task { await state.setSystemProxy(v) } }
            ))
            Toggle("TUN 模式（虚拟网卡）", isOn: Binding(
                get: { state.tunEnabled },
                set: { v in Task { await state.setTun(v) } }
            ))
            Toggle("允许局域网连接", isOn: Binding(
                get: { state.runtime?.allowLan ?? false },
                set: { v in Task { await state.setAllowLan(v) } }
            ))
            Picker("出站模式", selection: Binding(
                get: { state.currentMode },
                set: { m in Task { await state.setMode(m) } }
            )) {
                ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .toggleStyle(.switch)
        .disabled(!state.isRunning)
    }

    private var infoCard: some View {
        Card(title: "端口与控制") {
            let rt = state.runtime
            LabeledContent("混合端口", value: portText(rt?.mixedPort))
            LabeledContent("HTTP 端口", value: portText(rt?.port))
            LabeledContent("SOCKS 端口", value: portText(rt?.socksPort))
            LabeledContent("外部控制", value: state.api.map { "\($0.host):\($0.port)" } ?? "-")
            LabeledContent("TUN 协议栈", value: rt?.tun?.stack ?? "-")
            HStack {
                Button("复制终端代理命令") { state.copyTerminalCommand() }
                Button("打开 Web 面板") { if let u = state.dashboardURL { NSWorkspace.shared.open(u) } }
                Button("打开工作目录") { NSWorkspace.shared.open(AppPaths.base) }
            }
            .disabled(!state.isRunning)
        }
    }

    private func portText(_ p: Int?) -> String {
        guard let p, p > 0 else { return "-" }
        return "\(p)"
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var icon: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TrafficChart: View {
    var points: [TrafficPoint]

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("t", p.id), y: .value("速度", p.down), series: .value("方向", "下载"))
                    .foregroundStyle(by: .value("方向", "下载"))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.id), y: .value("速度", p.up), series: .value("方向", "上传"))
                    .foregroundStyle(by: .value("方向", "上传"))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["下载": Color.blue, "上传": Color.purple])
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let n = v.as(Int64.self) { Text(Format.speed(n)) } }
            }
        }
        .animation(nil, value: points.count)
    }
}
