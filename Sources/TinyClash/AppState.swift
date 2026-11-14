import AppKit
import Foundation
import Network
import Observation
import ServiceManagement
import UserNotifications

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
    var requestLog = RequestLog()
    var hasConnectionSnapshot = false
    var connectionStreamError: String?

    var proxies: [String: ProxyItem] = [:]
    var groupNames: [String] = []
    var testingGroups: Set<String> = []
    var testingProxies: Set<String> = []

    var profiles: [Profile] = []
    var updatingProfiles: Set<UUID> = []
    var updatingProfileNodes: Set<UUID> = []
    var updatingRuleProviders: Set<String> = []
    /// 后台自动更新失败的原因，显示在配置卡片上，不占用全局错误横幅
    var profileUpdateErrors: [UUID: String] = [:]
    /// 订阅文件与最近一次下载内容不同（在 App 内或外部编辑过），暂停自动更新
    private(set) var locallyModifiedProfiles: Set<UUID> = []
    private(set) var launchAtLoginStatus = SMAppService.mainApp.status
    private var editingProfiles: Set<UUID> = []
    private(set) var profileRevision = 0
    var needsCoreRestart = false
    /// 正在应用修改或重启内核，顶部状态显示「重启中」
    private(set) var restarting = false
    /// 面板内的确认框（系统 alert 会让菜单栏面板失去焦点并收起，操作随之丢失）
    var confirmation: PanelConfirmation?
    /// 请求打开「添加订阅」页（来自首页空状态或 clash:// 链接），值为预填的订阅链接
    var addSubscriptionRequest: String?
    var pendingNewGroupNames: Set<String> = []
    var isEditingSelectedProfile: Bool { selectedProfileID.map { editingProfiles.contains($0) } ?? false }
    var canEditSelectedProfile: Bool {
        guard let profile = selectedProfile else { return false }
        return !busy && coreState != .starting && !isEditingSelectedProfile && !updatingProfiles.contains(profile.id)
    }

    // MARK: Persisted settings

    private let defaults = UserDefaults.standard

    var selectedProfileID: UUID? {
        didSet {
            defaults.set(selectedProfileID?.uuidString, forKey: "selectedProfileID")
            if oldValue != selectedProfileID {
                requestLog.reset()
                connections = []
                hasConnectionSnapshot = false
                connectionStreamError = nil
                connectionStreamID = UUID()
            }
        }
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
    var globalHotKeysEnabled: Bool {
        didSet {
            defaults.set(globalHotKeysEnabled, forKey: "globalHotKeys")
            updateGlobalHotKeys()
        }
    }

    // MARK: Internals

    let core = CoreManager()
    private let store = ProfileStore()
    private var streams: [StreamClient] = []
    private var connectionStreamID = UUID()
    private var trafficCounter = 0
    private var autoUpdateTimer: Timer?
    private var proxyRefreshTask: Task<Void, Never>?
    private var autoUpdateFailures: [UUID: (count: Int, at: Date)] = [:]
    private var crashRestarts = 0
    private var coreStartedAt: Date?
    private var crashRestartTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var networkChangeTask: Task<Void, Never>?

    var api: MihomoAPI? { core.api }
    var isRunning: Bool { coreState == .running }
    var selectedProfile: Profile? { profiles.first { $0.id == selectedProfileID } }
    /// TUN 开关显示内核的实际状态：配置文件自身开启 TUN 时也如实显示
    var tunActive: Bool { isRunning ? (runtime?.tun?.enable ?? tunEnabled) : tunEnabled }
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
        globalHotKeysEnabled = d.bool(forKey: "globalHotKeys")

        core.onUnexpectedExit = { [weak self] status, tail in
            Task { @MainActor in await self?.handleCoreCrash(status: status, log: tail) }
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        AppPaths.ensure()
        // 复制内核、读取版本都会启动子进程，放到后台避免启动时卡住菜单栏
        let core = core
        let (installError, version) = await Task.detached { () -> (String?, String) in
            var installError: String?
            do { try core.installBundledCoreIfNeeded() } catch { installError = error.localizedDescription }
            core.installBundledGeoIfNeeded()
            core.installBundledWebUIIfNeeded()
            return (installError, CoreManager.version(of: AppPaths.coreBinary) ?? "")
        }.value
        if let installError { errorMessage = "安装内核失败：\(installError)" }
        isPrivileged = core.isPrivileged
        coreVersion = version
        await recoverFromPreviousCrash()

        profiles = store.reconcileFileNames(store.load())
        refreshLocalModifications()
        if selectedProfile == nil { selectedProfileID = profiles.first?.id }
        if selectedProfile != nil { await startCore() }

        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoUpdateProfiles() }
        }
        observeSystemEvents()
        updateGlobalHotKeys()
        Task { await autoUpdateProfiles() }
    }

    private func updateGlobalHotKeys() {
        guard globalHotKeysEnabled else { return GlobalHotKeys.unregister() }
        GlobalHotKeys.register { action in
            Task { @MainActor in await AppState.shared.perform(action) }
        }
    }

    private func perform(_ action: GlobalHotKeys.Action) async {
        guard isRunning else { return }
        switch action {
        case .toggleSystemProxy: await setSystemProxy(!systemProxyEnabled)
        case .toggleTun: await setTun(!tunActive)
        case .cycleMode:
            let all = ProxyMode.allCases
            await setMode(all[(all.firstIndex(of: currentMode)! + 1) % all.count])
        }
    }

    /// 处理 `clash://install-config?url=...`（及 `mihomo://`）：预填「添加订阅」页，由用户确认后再下载
    func handleOpenURL(_ url: URL) {
        guard ["clash", "mihomo", "clash-meta"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "install-config",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let parsed = URL(string: target), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
            errorMessage = "无法识别的导入链接：\(url.absoluteString)"
            return
        }
        addSubscriptionRequest = target
        notify(title: "TinyClash 收到订阅链接", body: "点击菜单栏图标，确认后添加订阅。")
    }

    /// 睡眠唤醒、网络变化后重新应用系统代理与 DNS，并刷新节点
    private func observeSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.scheduleNetworkResync(after: 3) }
        }
        let monitor = NWPathMonitor()
        var first = true
        monitor.pathUpdateHandler = { _ in
            Task { @MainActor in
                // 启动时的首次回调不是网络变化
                if first { first = false; return }
                AppState.shared.scheduleNetworkResync(after: 2)
            }
        }
        monitor.start(queue: DispatchQueue(label: "TinyClash.network"))
        pathMonitor = monitor
    }

    /// 网络切换时会连续触发多次回调，合并成一次
    private func scheduleNetworkResync(after seconds: Double) {
        networkChangeTask?.cancel()
        networkChangeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await resyncNetwork()
        }
    }

    private func resyncNetwork() async {
        guard isRunning else { return }
        if systemProxyEnabled, let port = runtime?.httpPort, port > 0 {
            // 新接入的网卡（USB 网卡、热点）还没有代理设置，补上
            let status = await SystemProxy.pointingStatus(toPort: port)
            if !status.other.isEmpty && !status.pointing.isEmpty { await applySystemProxy() }
        }
        if tunActive && tunSetDNS { await overrideDNS() }
        await refreshProxies()
    }

    /// 面板打开时刷新依赖外部状态的显示：系统代理、本地修改、登录项
    func panelDidOpen() async {
        refreshLocalModifications()
        refreshLaunchAtLoginStatus()
        await verifySystemProxy()
    }

    /// 打开面板时核对系统代理：被其他程序或系统设置改掉时如实显示
    func verifySystemProxy() async {
        guard isRunning, systemProxyEnabled, let port = runtime?.httpPort, port > 0 else { return }
        let status = await SystemProxy.pointingStatus(toPort: port)
        guard isRunning, systemProxyEnabled else { return }
        if status.pointing.isEmpty {
            systemProxyEnabled = false
            defaults.removeObject(forKey: "appliedProxyPort")
            errorMessage = "系统代理已被系统设置或其他程序修改，已关闭「系统代理」开关"
        } else if !status.other.isEmpty {
            await applySystemProxy()
        }
    }

    /// 上次异常退出时可能遗留了系统代理 / DNS 设置
    private func recoverFromPreviousCrash() async {
        let port = defaults.integer(forKey: "appliedProxyPort")
        if port > 0, await SystemProxy.isPointing(toPort: port) {
            try? await SystemProxy.disable()
        }
        defaults.removeObject(forKey: "appliedProxyPort")
        await restoreDNS()
    }

    func shutdown() async {
        crashRestartTask?.cancel()
        stopStreams()
        await clearSystemProxy()
        await restoreDNS()
        await core.stop()
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
        requestLog.reset()
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
            coreStartedAt = Date()
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
        restarting = true
        defer { restarting = false }
        crashRestartTask?.cancel()
        await clearSystemProxy()
        await restoreDNS()
        await core.stop()
        await startCore()
    }

    /// 让「需重启生效」的修改生效：优先热重载配置，保留连接与系统代理；失败时再整进程重启
    func applyPendingChanges() async {
        guard !restarting else { return }
        guard isRunning, let api, let profile = selectedProfile else { return await restartCore() }
        restarting = true
        defer { restarting = false }
        let oldPort = runtime?.httpPort
        do {
            try await api.reloadConfig(path: try effectiveConfigPath(for: profile))
        } catch {
            return await restartCore()
        }
        guard self.api === api, isRunning else { return }
        needsCoreRestart = false
        pendingNewGroupNames = []
        await applyRuntimeOverrides()
        await refreshProxies()
        if systemProxyEnabled, runtime?.httpPort != oldPort { await applySystemProxy() }
    }

    func stopCore() async {
        crashRestartTask?.cancel()
        stopStreams()
        await clearSystemProxy()
        await restoreDNS()
        await core.stop()
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

    private static let crashRestartDelays: [UInt64] = [1, 5, 30]

    private func handleCoreCrash(status: Int32, log: String) async {
        guard coreState == .running || coreState == .starting else { return }
        let wasRunning = coreState == .running
        stopStreams()
        needsCoreRestart = false
        pendingNewGroupNames = []
        // 内核退出后若保留系统代理会导致断网
        await clearSystemProxy()
        await restoreDNS()
        coreState = .failed("内核意外退出（\(status)）")
        errorMessage = "内核意外退出（状态码 \(status)）\n\(log)"

        // 启动阶段就退出多半是配置问题，重试无意义；稳定运行一分钟以上再崩溃，重新计数
        guard wasRunning else { return }
        if let started = coreStartedAt, Date().timeIntervalSince(started) > 60 { crashRestarts = 0 }
        guard crashRestarts < Self.crashRestartDelays.count else {
            notify(title: "TinyClash 内核已停止", body: "内核多次意外退出，已停止自动重启，流量当前不经过代理。")
            return
        }
        let delay = Self.crashRestartDelays[crashRestarts]
        crashRestarts += 1
        notify(title: "TinyClash 内核意外退出", body: "已暂时关闭系统代理，\(delay) 秒后自动重启内核。")
        crashRestartTask = Task {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, case .failed = coreState else { return }
            await startCore()
            if isRunning { errorMessage = nil }
        }
    }

    /// 系统通知；未打包运行（swift run）时没有 bundle id，直接跳过
    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
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
        // 配置文件自身开启了 TUN：开关如实显示，并按设置接管系统 DNS
        if !tunEnabled, runtime?.tun?.enable == true, tunSetDNS { await overrideDNS() }
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
        if await SystemProxy.isPointing(toPort: port) {
            try? await SystemProxy.disable()
        }
        defaults.removeObject(forKey: "appliedProxyPort")
    }

    // MARK: - TUN

    /// 协议栈、DNS 设置变化后，TUN 已开启时立即重新下发
    func tunSettingsChanged() async {
        guard isRunning, tunActive else { return }
        if tunEnabled {
            await applyTun(false)
            await applyTun(true)
            runtime = try? await api?.configs()
        } else if tunSetDNS {
            await overrideDNS()
        } else {
            await restoreDNS()
        }
    }

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
            let current = await SystemProxy.currentDNS()
            defaults.set(try? JSONEncoder().encode(current), forKey: "savedDNS")
        }
        do { try await SystemProxy.setDNSAll(servers) } catch { errorMessage = error.localizedDescription }
    }

    private func restoreDNS() async {
        guard let data = defaults.data(forKey: "savedDNS"),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        let existing = Set(await SystemProxy.services())
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
        if wasRunning { await stopCore() }
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
        let orderedSet = Set(ordered)
        let rest = proxies.keys.filter { isNode($0) && !orderedSet.contains($0) }.sorted()
        return ordered + rest
    }

    /// 规则可指向的策略：内置策略、分组、节点
    var policyNames: [String] {
        let groups = isRunning && !needsCoreRestart
            ? groupNames : selectedProfile.map { store.groupSummaries(in: $0).map(\.name) } ?? []
        return Self.builtinPolicies + groups.filter { $0 != "GLOBAL" } + nodeNames
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
        guard let group = primaryGroup else { return [] }
        return resolvedChain(from: group)
    }

    /// 从任意策略组沿 now 解析到最终节点（含起点），用于卡片显示实际出站
    func resolvedChain(from group: ProxyItem) -> [String] {
        var item = group
        var chain = [item.name]
        while let next = item.now, !chain.contains(next), chain.count < 6 {
            chain.append(next)
            guard let n = proxies[next], n.isGroup else { break }
            item = n
        }
        return chain
    }

    /// 是否真的在接管流量（内核运行且开启了系统代理或 TUN）
    var isProxying: Bool { isRunning && (systemProxyEnabled || tunActive) }

    func testGroup(_ group: String) async {
        guard let api, !testingGroups.contains(group), !pendingNewGroupNames.contains(group) else { return }
        testingGroups.insert(group)
        let url = proxies[group]?.testUrl.flatMap { $0.isEmpty ? nil : $0 } ?? delayTestURL
        _ = try? await api.groupDelay(group: group, url: url, timeout: delayTimeout)
        testingGroups.remove(group)
        await refreshProxies()
    }

    /// 多个策略组同时测速；限制并发数，避免几百个节点探测同时发出
    func testGroups(_ names: [String], maxConcurrent: Int = 4) async {
        let names = names.filter { !pendingNewGroupNames.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            var pending = names.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let name = pending.next() else { break }
                group.addTask { await self.testGroup(name) }
            }
            while await group.next() != nil {
                if let name = pending.next() { group.addTask { await self.testGroup(name) } }
            }
        }
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
        let streamID = connectionStreamID
        let conns = StreamClient(url: api.webSocketURL("/connections", query: "interval=1000"), session: api.session, onFailure: { message in
            Task { @MainActor in
                let s = AppState.shared
                guard s.connectionStreamID == streamID, s.api === api, s.isRunning else { return }
                s.connectionStreamError = "连接数据流中断，正在重连：\(message)"
            }
        }) { data in
            let snapshot = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
            Task { @MainActor in
                let s = AppState.shared
                guard s.connectionStreamID == streamID, s.api === api, s.isRunning else { return }
                guard let snap = snapshot else {
                    s.connectionStreamError = "无法解析内核连接数据，请检查内核版本。"
                    return
                }
                s.connectionStreamError = nil
                s.hasConnectionSnapshot = true
                s.uploadTotal = snap.uploadTotal
                s.downloadTotal = snap.downloadTotal
                s.connections = (snap.connections ?? []).sorted { $0.start > $1.start }
                s.requestLog.ingest(s.connections)
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

    func clearRequestLog() {
        requestLog.clear()
    }

    private func stopStreams() {
        connectionStreamID = UUID()
        hasConnectionSnapshot = false
        connectionStreamError = nil
        requestLog.finish()
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = (dl.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? URL(string: url)?.host ?? "订阅")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = !trimmedName.isEmpty ? trimmedName : (fallbackName.isEmpty ? "订阅" : fallbackName)
        var profile = Profile(name: resolvedName, kind: .remote, url: url.trimmingCharacters(in: .whitespaces),
                              fileName: store.uniqueFileName(for: resolvedName, in: profiles), updatedAt: Date())
        profile.subscription = dl.subscription
        profile.homepage = dl.homepage
        profile.downloadedHash = ProfileStore.hash(dl.data)
        if let h = dl.updateInterval, h > 0 { profile.updateInterval = h }
        try await store.writeValidated(dl.data, to: profile.fileURL) {
            if self.profiles.contains(where: { $0.fileName.lowercased() == profile.fileName.lowercased() }) {
                throw ProfileError.profileChanged
            }
        }
        profiles.append(profile)
        store.save(profiles)
        if selectedProfileID == nil || !isRunning { await selectProfile(profile.id) }
    }

    func importLocalProfile(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let rawName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? "配置" : rawName
        let profile = Profile(name: name, kind: .local,
                              fileName: store.uniqueFileName(for: name, in: profiles), updatedAt: Date(), updateInterval: 0)
        try await store.writeValidated(data, to: profile.fileURL) {
            if self.profiles.contains(where: { $0.fileName.lowercased() == profile.fileName.lowercased() }) {
                throw ProfileError.profileChanged
            }
        }
        profiles.append(profile)
        store.save(profiles)
        if selectedProfileID == nil || !isRunning { await selectProfile(profile.id) }
    }

    func createBlankProfile() -> Profile? {
        let name = "新配置"
        let profile = Profile(name: name, kind: .local,
                              fileName: store.uniqueFileName(for: name, in: profiles), updatedAt: Date(), updateInterval: 0)
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
        do {
            try template.write(to: profile.fileURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "新建配置失败：\(error.localizedDescription)"
            return nil
        }
        profiles.append(profile)
        store.save(profiles)
        // 还没有选中任何配置时直接选中，首页「启动内核」即可使用
        if selectedProfile == nil { selectedProfileID = profile.id }
        return profile
    }

    func canUpdateProfileNodes(_ id: UUID) -> Bool {
        isRunning && selectedProfile?.id == id && !busy
            && !updatingProfiles.contains(id) && !editingProfiles.contains(id)
    }

    func updateProfileNodes(_ id: UUID) async {
        guard canUpdateProfileNodes(id), let api else { return }
        busy = true
        updatingProfileNodes.insert(id)
        defer {
            updatingProfileNodes.remove(id)
            busy = false
        }
        do {
            let failed = try await api.updateSubscriptionNodes()
            guard self.api === api, selectedProfileID == id, isRunning else { return }
            await refreshProxies()
            guard self.api === api, selectedProfileID == id, isRunning else { return }
            if !failed.isEmpty { errorMessage = "以下节点订阅更新失败：\(failed.joined(separator: "、"))" }
        } catch is CancellationError {
            return
        } catch {
            guard self.api === api, selectedProfileID == id, isRunning else { return }
            errorMessage = "更新订阅节点失败：\(error.localizedDescription)"
        }
    }

    func isLocallyModified(_ id: UUID) -> Bool { locallyModifiedProfiles.contains(id) }

    /// 读取文件计算哈希，只在配置变化的时机调用，不放进视图 body
    func refreshLocalModifications() {
        locallyModifiedProfiles = Set(profiles.filter { store.isLocallyModified($0) }.map(\.id))
    }

    /// 下载订阅并覆盖本地文件；覆盖前把当前文件备份到 backups/。
    /// `background` 为后台自动更新：失败只记在配置卡片上，不弹全局横幅。
    @discardableResult
    func updateProfile(_ id: UUID, background: Bool = false) async -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }), let url = profile.url,
              !updatingProfiles.contains(id), !updatingProfileNodes.contains(id),
              !editingProfiles.contains(id) else { return false }
        updatingProfiles.insert(id)
        defer { updatingProfiles.remove(id) }
        do {
            let dl = try await store.download(url, viaProxyPort: proxyPortForDownload)
            guard profiles.first(where: { $0.id == id }) == profile else { throw ProfileError.profileChanged }
            try await store.writeValidated(dl.data, to: profile.fileURL) {
                guard self.profiles.first(where: { $0.id == id }) == profile else { throw ProfileError.profileChanged }
                self.store.backup(profile)
            }
            guard let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
            profiles[i].updatedAt = Date()
            profiles[i].downloadedHash = ProfileStore.hash(dl.data)
            if let sub = dl.subscription { profiles[i].subscription = sub }
            if let h = dl.updateInterval, h > 0 { profiles[i].updateInterval = h }
            store.save(profiles)
            profileRevision &+= 1
            profileUpdateErrors[id] = nil
            autoUpdateFailures[id] = nil
            locallyModifiedProfiles.remove(id)
            if id == selectedProfileID && isRunning {
                // 订阅覆盖了文件，之前未生效的本地修改也随之作废
                await applyPendingChanges()
            }
            return true
        } catch {
            let message = "更新「\(profile.name)」失败：\(error.localizedDescription)"
            if background {
                profileUpdateErrors[id] = error.localizedDescription
                let failures = (autoUpdateFailures[id]?.count ?? 0) + 1
                autoUpdateFailures[id] = (failures, Date())
            } else {
                errorMessage = message
            }
            return false
        }
    }

    /// 「更新全部订阅」跳过本地修改过的配置，避免一次覆盖多份修改
    func updateAllProfiles() async {
        for p in profiles where p.kind == .remote && !isLocallyModified(p.id) { await updateProfile(p.id) }
    }

    /// 自动更新跳过本地修改过、有未生效修改的配置；失败后按 1、2、4…小时退避（最长 6 小时）
    private func autoUpdateProfiles() async {
        refreshLocalModifications()
        for p in profiles where p.needsUpdate {
            if isLocallyModified(p.id) { continue }
            if p.id == selectedProfileID && needsCoreRestart { continue }
            if let failure = autoUpdateFailures[p.id] {
                let backoff = min(3600 * pow(2, Double(failure.count - 1)), 6 * 3600)
                if Date().timeIntervalSince(failure.at) < backoff { continue }
            }
            await updateProfile(p.id, background: true)
        }
    }

    @discardableResult
    func saveProfile(_ profile: Profile) -> Bool {
        guard profiles.contains(where: { $0.id == profile.id }) else { return false }
        guard !updatingProfiles.contains(profile.id), !editingProfiles.contains(profile.id) else {
            errorMessage = ProfileError.profileBusy.localizedDescription
            return false
        }
        do {
            profiles = try store.saveProfile(profile, in: profiles)
            profileRevision &+= 1
            return true
        } catch {
            errorMessage = "保存配置信息失败：\(error.localizedDescription)"
            return false
        }
    }

    func deleteProfile(_ id: UUID) async {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        guard !updatingProfiles.contains(id), !editingProfiles.contains(id), !updatingProfileNodes.contains(id) else {
            errorMessage = ProfileError.profileBusy.localizedDescription
            return
        }
        profiles.removeAll { $0.id == id }
        profileUpdateErrors[id] = nil
        locallyModifiedProfiles.remove(id)
        store.backup(p)
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
        refreshLocalModifications()
        if isRunning { await applyPendingChanges() } else { await startCore() }
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

    func ruleProviderDefinitions() throws -> [RuleProviderDefinition] {
        guard let profile = selectedProfile else { throw ProfileError.missingProfile }
        return try store.ruleProviders(in: profile)
    }

    func saveRuleProvider(_ provider: RuleProviderDefinition, replacing name: String?, profileID: UUID, policy: String? = nil) async throws {
        guard selectedProfileID == profileID else { throw ProfileError.profileChanged }
        guard !busy, coreState != .starting else { throw ProfileError.profileBusy }
        if let name {
            try await applyProfileEdit(.updateRuleProvider(name, provider))
        } else {
            try await applyProfileEdit(.addRuleProvider(provider, policy: policy))
        }
    }

    func deleteRuleProvider(named name: String, profileID: UUID) async throws {
        guard selectedProfileID == profileID else { throw ProfileError.profileChanged }
        guard !busy, coreState != .starting else { throw ProfileError.profileBusy }
        try await applyProfileEdit(.deleteRuleProvider(name))
    }

    /// 更新运行中的 HTTP 规则集；不改写 YAML，也不重启内核。
    func updateRuleProviders(named name: String? = nil) async {
        guard isRunning, !busy, !needsCoreRestart, !isEditingSelectedProfile,
              let profile = selectedProfile, !updatingProfiles.contains(profile.id), let api else { return }
        busy = true
        defer {
            updatingRuleProviders = []
            busy = false
        }
        do {
            let providers = try await api.ruleProviders().filter {
                $0.isRemoteRuleProvider && (name == nil || $0.name == name)
            }
            guard self.api === api, selectedProfileID == profile.id, isRunning else { return }
            guard !providers.isEmpty else { throw APIError.noRemoteRuleProviders }
            updatingRuleProviders = Set(providers.map(\.name))
            var failed: [String] = []
            for provider in providers {
                try Task.checkCancellation()
                guard self.api === api, selectedProfileID == profile.id, isRunning else { return }
                do {
                    try await api.updateRuleProvider(provider.name)
                } catch {
                    try Task.checkCancellation()
                    failed.append("\(provider.name)：\(error.localizedDescription)")
                }
            }
            guard self.api === api, selectedProfileID == profile.id, isRunning else { return }
            if !failed.isEmpty { errorMessage = "以下规则集更新失败：\(failed.joined(separator: "；"))" }
        } catch is CancellationError {
            return
        } catch {
            guard self.api === api, selectedProfileID == profile.id, isRunning else { return }
            errorMessage = "更新规则集失败：\(error.localizedDescription)"
        }
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
        if profile.kind == .remote, profile.downloadedHash != nil { locallyModifiedProfiles.insert(profile.id) }
        // 修改策略组或规则时不立即重启内核，改由顶部状态提示「需重启生效」，方便连续修改后一次性重启
        if wasRunning && isRunning && profile.id == selectedProfileID {
            needsCoreRestart = true
            switch edit {
            case .addGroup(let group):
                pendingNewGroupNames.insert(group.name)
            case .deleteGroup(let name):
                pendingNewGroupNames.remove(name)
            case .updateGroup, .addRule, .deleteRule, .updateRule,
                 .addRuleProvider, .updateRuleProvider, .deleteRuleProvider:
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

    func confirm(_ title: String, message: String, confirmTitle: String = "删除",
                 action: @escaping @MainActor () -> Void) {
        confirmation = PanelConfirmation(title: title, message: message, confirmTitle: confirmTitle, action: action)
    }

    /// 删除策略组前确认；删除会直接改写当前配置的 YAML
    func confirmDeleteGroup(_ name: String, onDeleted: @escaping @MainActor () -> Void = {}) {
        confirm("删除策略组「\(name)」？", message: "会从当前配置的 YAML 中删除该策略组；仍被规则或其他策略组引用时不会删除。") {
            Task { if await self.deleteGroup(named: name) { onDeleted() } }
        }
    }

    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { errorMessage = "设置开机启动失败：\(error.localizedDescription)" }
            refreshLaunchAtLoginStatus()
            if launchAtLoginStatus == .requiresApproval {
                errorMessage = "请在「系统设置 → 通用 → 登录项」中允许 TinyClash 登录时启动"
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    var launchAtLoginNeedsApproval: Bool { launchAtLoginStatus == .requiresApproval }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func updateGeo() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        do { try await api.updateGeo() } catch { errorMessage = "更新 Geo 数据库失败：\(error.localizedDescription)" }
    }

    /// 更新所有远程（HTTP）代理集合与规则集合；有未生效的配置修改时内核里的集合已过期，不更新
    func updateAllProviders() async {
        guard let api, !busy else { return }
        guard !needsCoreRestart else {
            errorMessage = "配置有未生效的修改，请先点击顶部「需重启生效」"
            return
        }
        busy = true
        defer { busy = false }
        var failed: [String] = []
        for p in (try? await api.proxyProviders()) ?? [] where p.vehicleType.caseInsensitiveCompare("HTTP") == .orderedSame {
            do { try await api.updateProxyProvider(p.name) } catch { failed.append(p.name) }
        }
        for p in (try? await api.ruleProviders()) ?? [] where p.isRemoteRuleProvider {
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
        Pasteboard.copy(terminalProxyCommand)
    }

    /// 官方 Web 面板 metacubexd，优先由本地内核同源提供，避免浏览器混合内容拦截
    var dashboardURL: URL? {
        guard let api else { return nil }
        return Self.dashboardURL(port: api.port, secret: api.secret, useLocalUI: core.hasWebUI)
    }

    static func dashboardURL(port: Int, secret: String, useLocalUI: Bool) -> URL? {
        var components = URLComponents()
        if useLocalUI {
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = port
            components.path = "/ui/"
        } else {
            components.scheme = "https"
            components.host = "metacubex.github.io"
            components.path = "/metacubexd/"
        }
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "hostname", value: "127.0.0.1"),
            URLQueryItem(name: "port", value: "\(port)"),
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "http", value: "1"),
        ]
        components.fragment = "/setup?\(query.percentEncodedQuery ?? "")"
        return components.url
    }
}
