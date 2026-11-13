import AppKit
import Foundation
import Observation
import ServiceManagement

enum CoreState: Equatable {
    case stopped, starting, running, failed(String)

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }
}

struct TrafficPoint: Identifiable {
    var id: Int
    var up: Int64
    var down: Int64
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case rule, global, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: Runtime state

    var coreState: CoreState = .stopped
    var coreVersion = ""
    var runtime: RuntimeConfig?
    var isPrivileged = false
    var errorMessage: String?
    var busy = false

    var upSpeed: Int64 = 0
    var downSpeed: Int64 = 0
    var trafficHistory: [TrafficPoint] = []
    var uploadTotal: Int64 = 0
    var downloadTotal: Int64 = 0
    var memory: Int64 = 0
    var connections: [Connection] = []

    var proxies: [String: ProxyItem] = [:]
    var groupNames: [String] = []
    var testingGroups: Set<String> = []
    var testingProxies: Set<String> = []

    var profiles: [Profile] = []
    var updatingProfiles: Set<UUID> = []
    private var editingProfiles: Set<UUID> = []
    private(set) var profileRevision = 0
    var needsCoreRestart = false
    var pendingNewGroupNames: Set<String> = []
    var isEditingSelectedProfile: Bool { selectedProfileID.map { editingProfiles.contains($0) } ?? false }

    // MARK: Persisted settings

    private let defaults = UserDefaults.standard

    var selectedProfileID: UUID? {
        didSet { defaults.set(selectedProfileID?.uuidString, forKey: "selectedProfileID") }
    }
    var systemProxyEnabled: Bool { didSet { defaults.set(systemProxyEnabled, forKey: "systemProxy") } }
    var tunEnabled: Bool { didSet { defaults.set(tunEnabled, forKey: "tun") } }
    /// 用户在 App 中切换过的模式，nil 表示沿用配置文件
    var modeOverride: String? { didSet { defaults.set(modeOverride, forKey: "modeOverride") } }
    var allowLanOverride: Bool? { didSet { defaults.set(allowLanOverride, forKey: "allowLanOverride") } }
    /// 空字符串表示沿用配置文件中的 tun.stack
    var tunStack: String { didSet { defaults.set(tunStack, forKey: "tunStack") } }
    var tunSetDNS: Bool { didSet { defaults.set(tunSetDNS, forKey: "tunSetDNS") } }
    var tunDNSServer: String { didSet { defaults.set(tunDNSServer, forKey: "tunDNSServer") } }
    var bypassText: String { didSet { defaults.set(bypassText, forKey: "bypass") } }
    var fallbackPort: Int { didSet { defaults.set(fallbackPort, forKey: "fallbackPort") } }
    var delayTestURL: String { didSet { defaults.set(delayTestURL, forKey: "delayTestURL") } }
    var delayTimeout: Int { didSet { defaults.set(delayTimeout, forKey: "delayTimeout") } }
    var showSpeedInMenuBar: Bool { didSet { defaults.set(showSpeedInMenuBar, forKey: "showSpeed") } }
    var closeConnectionsOnSwitch: Bool { didSet { defaults.set(closeConnectionsOnSwitch, forKey: "closeConnOnSwitch") } }
    var subscriptionViaProxy: Bool { didSet { defaults.set(subscriptionViaProxy, forKey: "subViaProxy") } }

    // MARK: Internals

    let core = CoreManager()
    private let store = ProfileStore()
    private var streams: [StreamClient] = []
    private var trafficCounter = 0
    private var autoUpdateTimer: Timer?
    private var proxyRefreshTask: Task<Void, Never>?

    var api: MihomoAPI? { core.api }
    var isRunning: Bool { coreState == .running }
    var selectedProfile: Profile? { profiles.first { $0.id == selectedProfileID } }
    var currentMode: ProxyMode { ProxyMode(rawValue: runtime?.mode.lowercased() ?? "rule") ?? .rule }
    var bypassList: [String] {
        bypassText.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private init() {
        let d = UserDefaults.standard
        selectedProfileID = d.string(forKey: "selectedProfileID").flatMap(UUID.init)
        systemProxyEnabled = d.bool(forKey: "systemProxy")
        tunEnabled = d.bool(forKey: "tun")
        modeOverride = d.string(forKey: "modeOverride")
        allowLanOverride = d.object(forKey: "allowLanOverride") as? Bool
        tunStack = d.string(forKey: "tunStack") ?? ""
        tunSetDNS = d.object(forKey: "tunSetDNS") as? Bool ?? true
        tunDNSServer = d.string(forKey: "tunDNSServer") ?? "223.5.5.5"
        bypassText = d.string(forKey: "bypass") ?? SystemProxy.defaultBypass.joined(separator: "\n")
        fallbackPort = d.object(forKey: "fallbackPort") as? Int ?? 7890
        delayTestURL = d.string(forKey: "delayTestURL") ?? "https://www.gstatic.com/generate_204"
        delayTimeout = d.object(forKey: "delayTimeout") as? Int ?? 5000
        showSpeedInMenuBar = d.object(forKey: "showSpeed") as? Bool ?? true
        closeConnectionsOnSwitch = d.object(forKey: "closeConnOnSwitch") as? Bool ?? true
        subscriptionViaProxy = d.bool(forKey: "subViaProxy")

        core.onUnexpectedExit = { [weak self] status, tail in
            Task { @MainActor in await self?.handleCoreCrash(status: status, log: tail) }
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        AppPaths.ensure()
        do {
            try core.installBundledCoreIfNeeded()
        } catch {
            errorMessage = "安装内核失败：\(error.localizedDescription)"
        }
        core.installBundledGeoIfNeeded()
        isPrivileged = core.isPrivileged
        coreVersion = CoreManager.version(of: AppPaths.coreBinary) ?? ""
        await recoverFromPreviousCrash()

        profiles = store.load()
        if selectedProfile == nil { selectedProfileID = profiles.first?.id }
        if selectedProfile != nil { await startCore() }

        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoUpdateProfiles() }
        }
        Task { await autoUpdateProfiles() }
    }

    /// 上次异常退出时可能遗留了系统代理 / DNS 设置
    private func recoverFromPreviousCrash() async {
        let port = defaults.integer(forKey: "appliedProxyPort")
        if port > 0, SystemProxy.isPointing(toPort: port) {
            try? await SystemProxy.disable()
        }
        defaults.removeObject(forKey: "appliedProxyPort")
        await restoreDNS()
    }

    func shutdown() async {
        stopStreams()
        await clearSystemProxy()
        await restoreDNS()
        core.stop()
        coreState = .stopped
    }

    // MARK: - Core

    func startCore() async {
        guard let profile = selectedProfile else {
            coreState = .stopped
            errorMessage = "请先添加配置"
            return
        }
        guard core.coreInstalled else {
            coreState = .failed("未找到 mihomo 内核")
            errorMessage = "未找到 mihomo 内核，请在设置中选择内核文件"
            return
        }
        stopStreams()
        needsCoreRestart = false
        pendingNewGroupNames = []
        coreState = .starting
        isPrivileged = core.isPrivileged
        do {
            _ = try await core.start(configPath: try effectiveConfigPath(for: profile))
            coreVersion = (try? await api?.version()) ?? coreVersion
            await applyRuntimeOverrides()
            await refreshProxies()
            coreState = .running
            startStreams()
            if systemProxyEnabled { await applySystemProxy() }
        } catch {
            coreState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            await clearSystemProxy()
            await restoreDNS()
        }
    }

    func restartCore() async {
        await clearSystemProxy()
        await restoreDNS()
        core.stop()
        await startCore()
    }

    func stopCore() async {
        stopStreams()
        await clearSystemProxy()
        await restoreDNS()
        core.stop()
        coreState = .stopped
        needsCoreRestart = false
        pendingNewGroupNames = []
        runtime = nil
        proxies = [:]
        groupNames = []
        connections = []
        upSpeed = 0
        downSpeed = 0
    }

    private func handleCoreCrash(status: Int32, log: String) async {
        guard coreState == .running || coreState == .starting else { return }
        stopStreams()
        needsCoreRestart = false
        pendingNewGroupNames = []
        // 内核退出后若保留系统代理会导致断网
        await clearSystemProxy()
        await restoreDNS()
        coreState = .failed("内核意外退出（\(status)）")
        errorMessage = "内核意外退出（状态码 \(status)）\n\(log)"
    }

    /// 应用 App 层面的覆盖项：端口兜底、模式、局域网、TUN、系统代理
    private func applyRuntimeOverrides() async {
        guard let api else { return }
        runtime = try? await api.configs()
        var patch: [String: Any] = [:]
        if let rt = runtime, rt.httpPort == 0 { patch["mixed-port"] = fallbackPort }
        if let m = modeOverride { patch["mode"] = m }
        if let lan = allowLanOverride { patch["allow-lan"] = lan }
        if !patch.isEmpty {
            do { try await api.patchConfigs(patch) } catch { errorMessage = "应用设置失败：\(error.localizedDescription)" }
        }

        if tunEnabled {
            if core.isPrivileged {
                await applyTun(true)
            } else {
                tunEnabled = false
                errorMessage = "TUN 模式需要先授权内核（设置 → 内核 → 授权）"
            }
        }
        runtime = try? await api.configs()
    }

    // MARK: - System proxy

    func setSystemProxy(_ on: Bool) async {
        systemProxyEnabled = on
        if on { await applySystemProxy() } else { await clearSystemProxy() }
    }

    private func applySystemProxy() async {
        guard isRunning, let rt = runtime, rt.httpPort > 0 else { return }
        do {
            try await SystemProxy.enable(httpPort: rt.httpPort, socksPort: rt.socksProxyPort, bypass: bypassList)
            defaults.set(rt.httpPort, forKey: "appliedProxyPort")
        } catch {
            systemProxyEnabled = false
            errorMessage = error.localizedDescription
        }
    }

    /// 仅在系统代理仍指向我们的端口时才关闭，避免误关其他软件的设置
    private func clearSystemProxy() async {
        let port = defaults.integer(forKey: "appliedProxyPort")
        guard port > 0 else { return }
        if SystemProxy.isPointing(toPort: port) {
            try? await SystemProxy.disable()
        }
        defaults.removeObject(forKey: "appliedProxyPort")
    }

    // MARK: - TUN

    func setTun(_ on: Bool) async {
        if on && !core.isPrivileged {
            let ok = await grantPrivilege()
            guard ok else { tunEnabled = false; return }
            tunEnabled = true
            // 已运行的内核仍是普通权限，需要以新权限重启
            await restartCore()
            return
        }
        tunEnabled = on
        guard isRunning else { return }
        await applyTun(on)
        runtime = try? await api?.configs()
    }

    private func applyTun(_ on: Bool) async {
        guard let api else { return }
        var tun: [String: Any] = ["enable": on]
        if on && !tunStack.isEmpty { tun["stack"] = tunStack }
        do {
            try await api.patchConfigs(["tun": tun])
        } catch {
            errorMessage = "切换 TUN 失败：\(error.localizedDescription)"
            tunEnabled = false
            return
        }
        if on {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let enabled = (try? await api.configs())?.tun?.enable ?? false
            if !enabled {
                tunEnabled = false
                errorMessage = "TUN 启动失败，请查看日志\n\(CoreManager.tailLog(lines: 5))"
                return
            }
            if tunSetDNS { await overrideDNS() }
        } else {
            await restoreDNS()
        }
    }

    private func overrideDNS() async {
        let servers = tunDNSServer.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !servers.isEmpty else { return }
        if defaults.data(forKey: "savedDNS") == nil {
            let current = SystemProxy.currentDNS()
            defaults.set(try? JSONEncoder().encode(current), forKey: "savedDNS")
        }
        do { try await SystemProxy.setDNSAll(servers) } catch { errorMessage = error.localizedDescription }
    }

    private func restoreDNS() async {
        guard let data = defaults.data(forKey: "savedDNS"),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        let existing = Set(SystemProxy.services())
        try? await SystemProxy.setDNS(saved.filter { existing.contains($0.key) })
        defaults.removeObject(forKey: "savedDNS")
    }

    @discardableResult
    func grantPrivilege() async -> Bool {
        let r = await core.grantPrivilege()
        isPrivileged = core.isPrivileged
        if !r.ok && !r.output.contains("-128") { errorMessage = "授权失败：\(r.output)" }
        return isPrivileged
    }

    func revokePrivilege() async {
        if tunEnabled { await setTun(false) }
        let wasRunning = isRunning
        if wasRunning { core.stop() }
        let r = await core.revokePrivilege()
        isPrivileged = core.isPrivileged
        if !r.ok && !r.output.contains("-128") { errorMessage = "撤销失败：\(r.output)" }
        if wasRunning { await startCore() }
    }

    // MARK: - Mode / LAN

    func setMode(_ mode: ProxyMode) async {
        modeOverride = mode.rawValue
        guard let api else { return }
        do {
            try await api.patchConfigs(["mode": mode.rawValue])
            if closeConnectionsOnSwitch { try? await api.closeAllConnections() }
        } catch { errorMessage = error.localizedDescription }
        runtime = try? await api.configs()
        await refreshProxies()
    }

    func setAllowLan(_ on: Bool) async {
        allowLanOverride = on
        guard let api else { return }
        try? await api.patchConfigs(["allow-lan": on])
        runtime = try? await api.configs()
    }

    // MARK: - Proxies

    func refreshProxies() async {
        guard let api, var all = try? await api.proxies() else { return }
        // proxy-providers 中的节点不会出现在 /proxies，需要从 /providers/proxies 合并
        for provider in (try? await api.proxyProviders()) ?? [] {
            for node in provider.proxies ?? [] where all[node.name] == nil { all[node.name] = node }
        }
        let order = all["GLOBAL"]?.all ?? []
        var names = order.filter { all[$0]?.isGroup == true && all[$0]?.hidden != true }
        // 补上 GLOBAL.all 中未列出的组
        names += all.values.filter { $0.isGroup && $0.hidden != true && $0.name != "GLOBAL" && !names.contains($0.name) }
            .map(\.name).sorted()
        names.append("GLOBAL")
        if needsCoreRestart {
            applyPendingGroupSummaries(into: &all, groupNames: &names)
        }
        proxies = all
        groupNames = names
    }

    /// 菜单 / 列表中实际展示的组：全局模式只显示 GLOBAL，直连模式不显示
    var visibleGroups: [ProxyItem] {
        switch currentMode {
        case .global: return proxies["GLOBAL"].map { [$0] } ?? []
        case .direct: return []
        case .rule: return groupNames.filter { $0 != "GLOBAL" }.compactMap { proxies[$0] }
        }
    }

    func select(group: String, proxy: String) async {
        guard let api, !pendingNewGroupNames.contains(group) else { return }
        do {
            try await api.select(group: group, proxy: proxy)
            if closeConnectionsOnSwitch { try? await api.closeAllConnections() }
        } catch { errorMessage = "切换节点失败：\(error.localizedDescription)" }
        await refreshProxies()
    }

    func delay(of name: String) -> Int? { proxies[name]?.lastDelay }

    static let builtinPolicies = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"]

    /// 当前配置中的节点（不含分组与内置策略），按 GLOBAL 中的顺序
    var nodeNames: [String] {
        let builtin: Set = ["Direct", "Reject", "RejectDrop", "Pass", "Compatible"]
        let order = proxies["GLOBAL"]?.all ?? []
        let isNode = { (n: String) in self.proxies[n].map { !$0.isGroup && !builtin.contains($0.type) } ?? false }
        let ordered = order.filter(isNode)
        let rest = proxies.keys.filter { isNode($0) && !ordered.contains($0) }.sorted()
        return ordered + rest
    }

    /// 规则可指向的策略：内置策略、分组、节点
    var policyNames: [String] {
        Self.builtinPolicies + groupNames.filter { $0 != "GLOBAL" } + nodeNames
    }

    /// 主策略组：全局模式为 GLOBAL，规则模式为配置中的第一个分组
    var primaryGroup: ProxyItem? {
        switch currentMode {
        case .direct: return nil
        case .global: return proxies["GLOBAL"]
        case .rule: return visibleGroups.first
        }
    }

    /// 从主策略组沿 now 一路解析到最终节点，例如 [Auto, 香港, 香港 ISP 6]
    var routeChain: [String] {
        guard var item = primaryGroup else { return [] }
        var chain = [item.name]
        while let next = item.now, !chain.contains(next), chain.count < 6 {
            chain.append(next)
            guard let n = proxies[next], n.isGroup else { break }
            item = n
        }
        return chain
    }

    /// 是否真的在接管流量（内核运行且开启了系统代理或 TUN）
    var isProxying: Bool { isRunning && (systemProxyEnabled || tunEnabled) }

    func testGroup(_ group: String) async {
        guard let api, !testingGroups.contains(group), !pendingNewGroupNames.contains(group) else { return }
        testingGroups.insert(group)
        let url = proxies[group]?.testUrl.flatMap { $0.isEmpty ? nil : $0 } ?? delayTestURL
        _ = try? await api.groupDelay(group: group, url: url, timeout: delayTimeout)
        testingGroups.remove(group)
        await refreshProxies()
    }

    func testProxy(_ name: String) async {
        guard let api, !testingProxies.contains(name) else { return }
        testingProxies.insert(name)
        _ = try? await api.proxyDelay(name: name, url: delayTestURL, timeout: delayTimeout)
        testingProxies.remove(name)
        await refreshProxies()
    }

    // MARK: - Streams

    private func startStreams() {
        guard let api else { return }
        stopStreams()
        trafficHistory = (0..<60).map { TrafficPoint(id: $0 - 60, up: 0, down: 0) }

        let traffic = StreamClient(url: api.webSocketURL("/traffic"), session: api.session) { data in
            guard let s = try? JSONDecoder().decode(TrafficSample.self, from: data) else { return }
            Task { @MainActor in AppState.shared.pushTraffic(s) }
        }
        let memory = StreamClient(url: api.webSocketURL("/memory"), session: api.session) { data in
            guard let m = try? JSONDecoder().decode(MemorySample.self, from: data) else { return }
            Task { @MainActor in AppState.shared.memory = m.inuse }
        }
        let conns = StreamClient(url: api.webSocketURL("/connections"), session: api.session) { data in
            guard let snap = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data) else { return }
            Task { @MainActor in
                let s = AppState.shared
                s.uploadTotal = snap.uploadTotal
                s.downloadTotal = snap.downloadTotal
                s.connections = (snap.connections ?? []).sorted { $0.start > $1.start }
            }
        }
        streams = [traffic, memory, conns]
        streams.forEach { $0.start() }

        // 定期刷新节点（延迟历史、provider 更新后的节点）
        proxyRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.refreshProxies()
            }
        }
    }

    private func stopStreams() {
        streams.forEach { $0.stop() }
        streams = []
        proxyRefreshTask?.cancel()
        proxyRefreshTask = nil
    }

    private func pushTraffic(_ s: TrafficSample) {
        upSpeed = s.up
        downSpeed = s.down
        trafficCounter += 1
        trafficHistory.append(TrafficPoint(id: trafficCounter, up: s.up, down: s.down))
        if trafficHistory.count > 60 { trafficHistory.removeFirst(trafficHistory.count - 60) }
    }

    // MARK: - Profiles

    func selectProfile(_ id: UUID) async {
        guard id != selectedProfileID || !isRunning else { return }
        selectedProfileID = id
        needsCoreRestart = false
        pendingNewGroupNames = []
        runtime = nil
        proxies = [:]
        groupNames = []
        await restartCore()
    }

    private var proxyPortForDownload: Int? {
        subscriptionViaProxy && isRunning ? runtime?.httpPort : nil
    }

    func addRemoteProfile(url: String, name: String) async throws {
        let dl = try await store.download(url, viaProxyPort: proxyPortForDownload)
        var profile = Profile(name: "", kind: .remote, url: url.trimmingCharacters(in: .whitespaces),
                              fileName: "", updatedAt: Date())
        profile.fileName = "\(profile.id.uuidString).yaml"
        profile.name = !name.isEmpty ? name : (dl.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? URL(string: url)?.host ?? "订阅")
        profile.subscription = dl.subscription
        profile.homepage = dl.homepage
        if let h = dl.updateInterval, h > 0 { profile.updateInterval = h }
        try await store.writeValidated(dl.data, to: profile.fileURL)
        profiles.append(profile)
        store.save(profiles)
        if selectedProfileID == nil || !isRunning { await selectProfile(profile.id) }
    }

    func importLocalProfile(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        var profile = Profile(name: url.deletingPathExtension().lastPathComponent, kind: .local,
                              fileName: "", updatedAt: Date(), updateInterval: 0)
        profile.fileName = "\(profile.id.uuidString).yaml"
        try await store.writeValidated(data, to: profile.fileURL)
        profiles.append(profile)
        store.save(profiles)
        if selectedProfileID == nil || !isRunning { await selectProfile(profile.id) }
    }

    func createBlankProfile() -> Profile {
        var profile = Profile(name: "新配置", kind: .local, fileName: "", updatedAt: Date(), updateInterval: 0)
        profile.fileName = "\(profile.id.uuidString).yaml"
        let template = """
        # mihomo 配置文档: https://wiki.metacubex.one/config/
        mixed-port: \(fallbackPort)
        allow-lan: false
        mode: rule
        log-level: info
        ipv6: true

        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          nameserver:
            - https://doh.pub/dns-query
            - https://dns.alidns.com/dns-query

        proxies: []

        proxy-groups:
          - name: PROXY
            type: select
            proxies: [DIRECT]

        rules:
          - GEOIP,LAN,DIRECT,no-resolve
          - GEOIP,CN,DIRECT
          - MATCH,PROXY

        """
        try? template.write(to: profile.fileURL, atomically: true, encoding: .utf8)
        profiles.append(profile)
        store.save(profiles)
        return profile
    }

    func updateProfile(_ id: UUID) async {
        guard let profile = profiles.first(where: { $0.id == id }), let url = profile.url,
              !updatingProfiles.contains(id), !editingProfiles.contains(id) else { return }
        updatingProfiles.insert(id)
        defer { updatingProfiles.remove(id) }
        do {
            let dl = try await store.download(url, viaProxyPort: proxyPortForDownload)
            guard profiles.first(where: { $0.id == id }) == profile else { throw ProfileError.profileChanged }
            try await store.writeValidated(dl.data, to: profile.fileURL) {
                guard self.profiles.first(where: { $0.id == id }) == profile else { throw ProfileError.profileChanged }
            }
            guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[i].updatedAt = Date()
            if let sub = dl.subscription { profiles[i].subscription = sub }
            store.save(profiles)
            profileRevision &+= 1
            if id == selectedProfileID && isRunning { await restartCore() }
        } catch {
            errorMessage = "更新「\(profile.name)」失败：\(error.localizedDescription)"
        }
    }

    func updateAllProfiles() async {
        for p in profiles where p.kind == .remote { await updateProfile(p.id) }
    }

    private func autoUpdateProfiles() async {
        for p in profiles where p.needsUpdate { await updateProfile(p.id) }
    }

    func saveProfile(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        store.save(profiles)
    }

    func deleteProfile(_ id: UUID) async {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: p.fileURL)
        try? FileManager.default.removeItem(at: p.runtimeURL)
        store.save(profiles)
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
            needsCoreRestart = false
            pendingNewGroupNames = []
            if selectedProfileID != nil {
                runtime = nil
                proxies = [:]
                groupNames = []
                await restartCore()
            } else {
                await stopCore()
            }
        }
    }

    /// 在外部编辑器修改后，校验并重载当前配置
    func reloadCurrentProfile() async {
        guard let p = selectedProfile else { return }
        do {
            let r = await CoreManager.testConfig(try effectiveConfigPath(for: p))
            if !r.ok { throw ProfileError.invalidConfig(r.output) }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        profileRevision &+= 1
        await restartCore()
    }

    // MARK: - Official YAML additions / legacy compatibility

    /// Only pre-existing profiles.json overlays use runtime YAML. No bootstrap
    /// migration is performed; a successful explicit addition migrates that profile.
    private func effectiveConfigPath(for profile: Profile) throws -> String {
        guard profile.hasCustomization else { return profile.fileURL.path }
        let yaml = try String(contentsOf: profile.fileURL, encoding: .utf8)
        try ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
            .write(to: profile.runtimeURL, atomically: true, encoding: .utf8)
        return profile.runtimeURL.path
    }

    /// Add or delete directly on the selected official YAML, never via an overlay.
    func addRule(_ rule: String) async throws {
        try await applyProfileEdit(.addRule(rule))
    }

    func addGroup(_ group: CustomGroup) async throws {
        try await applyProfileEdit(.addGroup(group))
    }

    func ruleTarget(_ rule: RuleItem, at fallbackIndex: Int?) -> ConfigOverlay.RuleTarget {
        ConfigOverlay.RuleTarget(index: rule.index ?? fallbackIndex, type: rule.type,
                                 payload: rule.payload, proxy: rule.proxy)
    }

    func ruleText(_ target: ConfigOverlay.RuleTarget) -> String? {
        selectedProfile.flatMap { store.ruleText(target, in: $0) }
    }

    func updateRule(_ target: ConfigOverlay.RuleTarget, to rule: String) async throws {
        try await applyProfileEdit(.updateRule(target, rule))
    }

    @discardableResult
    func deleteRule(_ rule: RuleItem, at fallbackIndex: Int?) async -> Bool {
        await deleteRule(ruleTarget(rule, at: fallbackIndex))
    }

    @discardableResult
    func deleteRule(_ target: ConfigOverlay.RuleTarget) async -> Bool {
        errorMessage = nil
        do {
            try await applyProfileEdit(.deleteRule(target))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func groupDefinition(named name: String) -> CustomGroup? {
        selectedProfile.flatMap { store.group(named: name, in: $0) }
    }

    func updateGroup(named name: String, to group: CustomGroup) async throws {
        try await applyProfileEdit(.updateGroup(name, group))
    }

    @discardableResult
    func deleteGroup(named name: String) async -> Bool {
        errorMessage = nil
        do {
            try await applyProfileEdit(.deleteGroup(name))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func yamlRuleItems() -> [RuleItem] {
        selectedProfile.map { store.ruleItems(in: $0) } ?? []
    }

    private func applyProfileEdit(_ edit: ProfileStore.ProfileEdit) async throws {
        guard let profile = selectedProfile else { throw ProfileError.missingProfile }
        guard !updatingProfiles.contains(profile.id), !editingProfiles.contains(profile.id) else {
            throw ProfileError.profileBusy
        }
        editingProfiles.insert(profile.id)
        defer { editingProfiles.remove(profile.id) }
        let wasRunning = isRunning
        let validated = try await store.prepareEdit(edit, to: profile)
        profiles = try store.commit(validated, profiles: profiles)
        profileRevision &+= 1
        // 修改策略组或规则时不立即重启内核，改由顶部状态提示「需重启生效」，方便连续修改后一次性重启
        if wasRunning && isRunning && profile.id == selectedProfileID {
            needsCoreRestart = true
            switch edit {
            case .addGroup(let group):
                pendingNewGroupNames.insert(group.name)
            case .deleteGroup(let name):
                pendingNewGroupNames.remove(name)
            case .updateGroup, .addRule, .deleteRule, .updateRule:
                break
            }
            syncPendingGroupsFromYAML()
        }
    }

    private func syncPendingGroupsFromYAML() {
        var updated = proxies
        var names = groupNames
        applyPendingGroupSummaries(into: &updated, groupNames: &names)
        proxies = updated
        groupNames = names
    }

    private func applyPendingGroupSummaries(into all: inout [String: ProxyItem], groupNames: inout [String]) {
        guard needsCoreRestart, let profile = selectedProfile else { return }
        let summaries = store.groupSummaries(in: profile)
        let summaryByName = Dictionary(summaries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let existingGroupNames = Set(all.values.filter(\.isGroup).map(\.name))

        for name in existingGroupNames where name != "GLOBAL" && summaryByName[name] == nil {
            all.removeValue(forKey: name)
        }

        for summary in summaries {
            if var existing = all[summary.name], !pendingNewGroupNames.contains(summary.name) {
                existing.type = summary.apiType
                if !summary.proxies.isEmpty {
                    if summary.includeAll {
                        let existingAll = existing.all ?? []
                        existing.all = summary.proxies + existingAll.filter { !summary.proxies.contains($0) }
                    } else {
                        existing.all = summary.proxies
                        if let now = existing.now, !summary.proxies.contains(now) {
                            existing.now = summary.proxies.first
                        }
                    }
                }
                all[summary.name] = existing
            } else {
                all[summary.name] = ProxyItem(
                    name: summary.name,
                    type: summary.apiType,
                    now: nil,
                    all: summary.proxies
                )
            }
        }

        let hiddenNames = Set(all.values.filter { $0.hidden == true }.map(\.name))
        var rebuilt = summaries.map(\.name).filter { !hiddenNames.contains($0) }
        if all["GLOBAL"] != nil, !rebuilt.contains("GLOBAL") {
            rebuilt.append("GLOBAL")
        }
        groupNames = rebuilt
        if var global = all["GLOBAL"], let globalAll = global.all {
            let nonGroups = globalAll.filter { !existingGroupNames.contains($0) && summaryByName[$0] == nil }
            global.all = rebuilt.filter { $0 != "GLOBAL" } + nonGroups
            all["GLOBAL"] = global
        }
    }

    // MARK: - Misc

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { errorMessage = "设置开机启动失败：\(error.localizedDescription)" }
        }
    }

    func updateGeo() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        do { try await api.updateGeo() } catch { errorMessage = "更新 Geo 数据库失败：\(error.localizedDescription)" }
    }

    /// 更新所有代理集合与规则集合
    func updateAllProviders() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        var failed: [String] = []
        for p in (try? await api.proxyProviders()) ?? [] {
            do { try await api.updateProxyProvider(p.name) } catch { failed.append(p.name) }
        }
        for p in (try? await api.ruleProviders()) ?? [] {
            do { try await api.updateRuleProvider(p.name) } catch { failed.append(p.name) }
        }
        await refreshProxies()
        if !failed.isEmpty { errorMessage = "以下资源更新失败：\(failed.joined(separator: "、"))" }
    }

    /// 菜单栏面板没有宿主窗口，直接用 NSOpenPanel 选择文件
    func chooseFile(message: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func importProfileFromFile() async {
        guard let url = chooseFile(message: "选择 mihomo 配置文件（YAML）") else { return }
        do { try await importLocalProfile(from: url) } catch { errorMessage = error.localizedDescription }
    }

    func installCoreFromFile() async {
        guard let url = chooseFile(message: "选择 mihomo 内核可执行文件") else { return }
        await installCore(from: url)
    }

    func installCore(from url: URL) async {
        guard CoreManager.version(of: url) != nil else {
            errorMessage = "所选文件不是可执行的 mihomo 内核"
            return
        }
        let wasRunning = isRunning
        if wasRunning { await stopCore() }
        do { try core.replaceCore(with: url) } catch { errorMessage = "替换内核失败：\(error.localizedDescription)" }
        isPrivileged = core.isPrivileged
        coreVersion = CoreManager.version(of: AppPaths.coreBinary) ?? ""
        if tunEnabled && !isPrivileged { tunEnabled = false }
        if wasRunning { await startCore() }
    }

    var terminalProxyCommand: String {
        let port = runtime?.httpPort ?? fallbackPort
        let socks = runtime?.socksProxyPort ?? port
        return "export https_proxy=http://127.0.0.1:\(port) http_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(socks)"
    }

    func copyTerminalCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(terminalProxyCommand, forType: .string)
    }

    /// 官方 Web 面板 metacubexd，自动填好控制地址
    var dashboardURL: URL? {
        guard let api else { return nil }
        return URL(string: "https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=\(api.port)&secret=\(api.secret)")
    }
}
