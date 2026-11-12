import SwiftUI

struct ConnectionsView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var paused = false
    @State private var frozen: [Connection] = []
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\ConnectionRow.start, order: .reverse)]

    var body: some View {
        let rows = (paused ? frozen : state.connections)
            .filter { c in
                search.isEmpty || c.metadata.displayHost.localizedCaseInsensitiveContains(search)
                    || (c.metadata.process ?? "").localizedCaseInsensitiveContains(search)
                    || c.chains.joined().localizedCaseInsensitiveContains(search)
                    || c.rule.localizedCaseInsensitiveContains(search)
            }
            .map(ConnectionRow.init)
            .sorted(using: sortOrder)

        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("主机", value: \.host) { Text($0.host).lineLimit(1) }
                .width(min: 160, ideal: 240)
            TableColumn("进程", value: \.process) { Text($0.process).lineLimit(1) }
                .width(min: 60, ideal: 100)
            TableColumn("链路", value: \.chain) { Text($0.chain).lineLimit(1) }
                .width(min: 100, ideal: 180)
            TableColumn("规则", value: \.rule) { Text($0.rule).lineLimit(1) }
                .width(min: 80, ideal: 160)
            TableColumn("类型", value: \.network) { Text($0.network) }
                .width(min: 50, ideal: 80)
            TableColumn("下载", value: \.download) { Text(Format.bytes($0.download)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("上传", value: \.upload) { Text(Format.bytes($0.upload)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("时间", value: \.start) { Text(Format.relative($0.start)) }
                .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("断开连接") { close(ids) }
            Button("复制主机") {
                let hosts = rows.filter { ids.contains($0.id) }.map(\.host).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hosts, forType: .string)
            }
        }
        .onDeleteCommand { close(selection) }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索主机 / 进程 / 规则")
        .toolbar {
            ToolbarItemGroup {
                Text("\(rows.count) 个连接").foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { paused }, set: { paused = $0; frozen = state.connections })) {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                }
                Button { close(selection) } label: { Label("断开所选", systemImage: "xmark.circle") }
                    .disabled(selection.isEmpty)
                Button { Task { try? await state.api?.closeAllConnections() } } label: {
                    Label("全部断开", systemImage: "trash")
                }
            }
        }
    }

    private func close(_ ids: Set<String>) {
        Task { for id in ids { try? await state.api?.closeConnection(id) } }
    }
}

struct ConnectionRow: Identifiable {
    var id: String
    var host: String
    var process: String
    var chain: String
    var rule: String
    var network: String
    var download: Int64
    var upload: Int64
    var start: Date

    init(_ c: Connection) {
        id = c.id
        host = c.metadata.displayHost
        process = c.metadata.process ?? ""
        chain = c.chains.reversed().joined(separator: " → ")
        rule = c.rulePayload.isEmpty ? c.rule : "\(c.rule)(\(c.rulePayload))"
        network = "\(c.metadata.type)/\(c.metadata.network.uppercased())"
        download = c.download
        upload = c.upload
        start = c.startDate ?? .distantPast
    }
}

struct ProvidersView: View {
    @Environment(AppState.self) private var state
    @State private var proxyProviders: [ProviderItem] = []
    @State private var ruleProviders: [ProviderItem] = []
    @State private var working: Set<String> = []

    var body: some View {
        Form {
            Section("代理集合（proxy-providers）") {
                if proxyProviders.isEmpty { Text("当前配置没有代理集合").foregroundStyle(.secondary) }
                ForEach(proxyProviders) { p in
                    row(p, detail: "\(p.proxies?.count ?? 0) 个节点 · \(p.vehicleType)") {
                        Button("健康检查") { run("hc-\(p.name)") { try await state.api?.healthcheckProvider(p.name); await state.refreshProxies() } }
                        Button("更新") { run(p.name) { try await state.api?.updateProxyProvider(p.name); await state.refreshProxies() } }
                    }
                }
            }
            Section("规则集合（rule-providers）") {
                if ruleProviders.isEmpty { Text("当前配置没有规则集合").foregroundStyle(.secondary) }
                ForEach(ruleProviders) { p in
                    row(p, detail: "\(p.ruleCount ?? 0) 条规则 · \(p.behavior ?? "") · \(p.vehicleType)") {
                        Button("更新") { run(p.name) { try await state.api?.updateRuleProvider(p.name) } }
                    }
                }
            }
            Section("数据库") {
                HStack {
                    Text("GeoIP / GeoSite / ASN 数据库")
                    Spacer()
                    if state.busy { ProgressView().controlSize(.small) }
                    Button("更新 Geo 数据库") { Task { await state.updateGeo() } }.disabled(state.busy)
                }
                HStack {
                    Text("DNS 缓存")
                    Spacer()
                    Button("清空 Fake-IP 缓存") { Task { try? await state.api?.flushFakeIP() } }
                    Button("清空 DNS 缓存") { Task { try? await state.api?.flushDNS() } }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!state.isRunning)
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button("全部更新") {
                    run("all") {
                        for p in proxyProviders { try? await state.api?.updateProxyProvider(p.name) }
                        for p in ruleProviders { try? await state.api?.updateRuleProvider(p.name) }
                        await state.refreshProxies()
                    }
                }
            }
        }
        .task(id: state.coreState) { await load() }
    }

    @ViewBuilder
    private func row(_ p: ProviderItem, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name)
                Text(detail + updatedText(p)).font(.caption).foregroundStyle(.secondary)
                if let s = p.subscriptionInfo, let total = s.Total, total > 0 {
                    Text("已用 \(Format.bytes((s.Upload ?? 0) + (s.Download ?? 0))) / \(Format.bytes(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if working.contains(p.name) || working.contains("hc-\(p.name)") || working.contains("all") {
                ProgressView().controlSize(.small)
            }
            actions()
        }
    }

    private func updatedText(_ p: ProviderItem) -> String {
        guard let s = p.updatedAt, let d = ISO8601DateFormatter.mihomo.date(from: s) ?? ISO8601DateFormatter().date(from: s),
              d.timeIntervalSince1970 > 0 else { return "" }
        return " · 更新于 \(Format.relative(d))"
    }

    private func run(_ key: String, _ op: @escaping () async throws -> Void) {
        working.insert(key)
        Task {
            do { try await op() } catch { state.errorMessage = error.localizedDescription }
            working.remove(key)
            await load()
        }
    }

    private func load() async {
        proxyProviders = (try? await state.api?.proxyProviders()) ?? []
        ruleProviders = (try? await state.api?.ruleProviders()) ?? []
    }
}

struct LogsView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var follow = true

    var body: some View {
        @Bindable var state = state
        let entries = search.isEmpty ? state.logs : state.logs.filter { $0.text.localizedCaseInsensitiveContains(search) }
        ScrollViewReader { proxy in
            List(entries) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.time.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                    Text(e.level.uppercased())
                        .foregroundStyle(color(e.level))
                        .frame(width: 60, alignment: .leading)
                    Text(e.text).textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
                .id(e.id)
            }
            .onChange(of: state.logs.last?.id) {
                if follow, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "过滤日志")
        .toolbar {
            ToolbarItemGroup {
                Picker("级别", selection: $state.logLevel) {
                    ForEach(["debug", "info", "warning", "error"], id: \.self) { Text($0).tag($0) }
                }
                Toggle(isOn: $follow) { Label("自动滚动", systemImage: "arrow.down.to.line") }
                Button { NSWorkspace.shared.open(AppPaths.coreLog) } label: { Label("内核日志文件", systemImage: "doc.text") }
                Button { state.clearLogs() } label: { Label("清空", systemImage: "trash") }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warning": return .orange
        case "debug": return .gray
        default: return .blue
        }
    }
}
