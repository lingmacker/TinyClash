import SwiftUI

struct RequestLogsPage: View {
    @Environment(AppState.self) private var state
    var back: () -> Void
    @State private var search = ""
    @State private var selectedID: String?

    private func filteredEntries() -> [RequestLogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? state.requestLog.entries : state.requestLog.entries.filter { $0.matches(query) }
    }

    private var isLive: Bool {
        state.isRunning && state.hasConnectionSnapshot && state.connectionStreamError == nil
    }

    var body: some View {
        if let selectedID {
            if let entry = state.requestLog.entries.first(where: { $0.id == selectedID }) {
                RequestLogDetailPage(entry: entry, isLive: isLive) { self.selectedID = nil }
            } else {
                VStack(spacing: 0) {
                    SubpageHeader(title: "请求详情", back: { self.selectedID = nil })
                    EmptyHint(text: "这条记录已被清空或超出保留数量")
                }
            }
        } else {
            logList
        }
    }

    private var logList: some View {
        // 连接数据每秒更新，过滤结果在一次 body 里只算一遍
        let entries = filteredEntries()
        return VStack(spacing: 0) {
            SubpageHeader(title: "请求日志", back: back) {
                Button("清空") { state.clearRequestLog() }
                    .buttonStyle(.borderless)
                    .disabled(state.requestLog.entries.isEmpty)
                    .help("只清空内存中的日志，不断开连接；已有活跃连接不会被重复加入")
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("搜索域名、进程或策略", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索请求日志")
                HStack {
                    Text("\(entries.count) 条记录")
                    Spacer()
                    Text("最近 \(state.requestLog.limit) 条 · 仅内存")
                }
                .font(.caption2).foregroundStyle(.secondary)
                if let error = state.connectionStreamError {
                    Text(error).font(.caption2).foregroundStyle(Theme.failure)
                        .lineLimit(3).textSelection(.enabled)
                } else if !state.isRunning && !state.requestLog.entries.isEmpty {
                    Text("内核未运行，以下为停止前的采样记录。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.s) {
                        ForEach(entries) { entry in
                            Button { selectedID = entry.id } label: {
                                RequestLogCard(entry: entry, isLive: isLive)
                                    .hoverHighlight(cornerRadius: Theme.Radius.tile)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu {
                                Button("复制目标地址") { copy(entry.connection.metadata.displayHost) }
                                Button("复制策略链") { copy(entry.route.joined(separator: " → ")) }
                                    .disabled(entry.route.isEmpty)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyHint(text: "没有匹配的请求记录")
        } else if state.coreState == .starting || (state.isRunning && !state.hasConnectionSnapshot && state.connectionStreamError == nil) {
            LoadingHint(text: "等待内核连接数据…")
        } else {
            EmptyHint(text: state.isRunning ? "暂无请求记录\n请通过 TinyClash 访问网站后查看" : "内核未运行\n启动后可记录请求经过的策略")
                .multilineTextAlignment(.center)
        }
    }

    private func copy(_ text: String) {
        Pasteboard.copy(text)
    }
}

private struct RequestLogCard: View {
    var entry: RequestLogEntry
    var isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.connection.metadata.displayHost)
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Tag(text: entry.connection.metadata.network.uppercased(), cornerRadius: 4)
                Text(entry.policy).foregroundStyle(Theme.policyTint(entry.policy))
                    .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let node = entry.node, node != entry.policy {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(node).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(entry.startedAt, format: .dateTime.hour().minute().second())
                Text(entry.isActive ? (isLive ? "活跃" : "状态待确认") : "已结束")
                Spacer(minLength: 4)
                Text(entry.matchedRule).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }

}

private struct RequestLogDetailPage: View {
    var entry: RequestLogEntry
    var isLive: Bool
    var back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: "请求详情", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    PanelSection(title: "目标") {
                        Text(entry.connection.metadata.displayHost)
                            .font(.callout.weight(.semibold)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    PanelSection(title: "实际策略链", footer: "来自该连接的内核记录，不根据当前选中的节点推测。") {
                        Text(entry.route.isEmpty ? "内核未提供策略链" : entry.route.joined(separator: " → "))
                            .font(.callout.weight(.medium)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    PanelSection(title: "命中规则") {
                        Text(entry.matchedRule).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    PanelSection(title: "连接信息") {
                        valueRow("协议", entry.connection.metadata.network.uppercased())
                        valueRow("来源", entry.connection.metadata.type)
                        valueRow("进程", entry.connection.metadata.process.flatMap { $0.isEmpty ? nil : $0 } ?? "内核未提供")
                        valueRow("源地址", entry.connection.metadata.sourceIP)
                        valueRow("目标 IP", entry.connection.metadata.destinationIP.isEmpty ? "内核未提供" : entry.connection.metadata.destinationIP)
                        valueRow("状态", entry.isActive ? (isLive ? "活跃" : "等待下一次采样确认") : "已结束", divider: false)
                    }
                    PanelSection(title: "采样信息", footer: "结束时间为首次采样发现连接不再活跃的时间，流量为最后一次观测值。") {
                        timeRow("开始时间", entry.startedAt)
                        timeRow("最近观测", entry.lastSeenAt)
                        if let endedAt = entry.endedAt { timeRow("结束采样", endedAt) }
                        valueRow("上传 / 下载", "\(Format.bytes(entry.connection.upload)) / \(Format.bytes(entry.connection.download))", divider: false)
                    }
                }
                .padding(14)
            }
        }
    }

    private func valueRow(_ title: String, _ value: String, divider: Bool = true) -> some View {
        PanelRow(title: title, divider: divider) {
            Text(value).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timeRow(_ title: String, _ date: Date) -> some View {
        valueRow(title, date.formatted(date: .numeric, time: .standard))
    }
}
