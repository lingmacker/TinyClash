import ServiceManagement
import SwiftUI

struct SettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var editingBypass = false
    /// 正在进行的数据操作，进度显示在对应按钮的位置
    @State private var runningAction: String?
    @FocusState private var dnsFieldFocused: Bool
    @State private var appliedTunDNSServer = ""

    var body: some View {
        if editingBypass {
            BypassPage(back: { editingBypass = false })
        } else {
            root
        }
    }

    private func applyDNSIfNeeded() {
        guard state.tunDNSServer != appliedTunDNSServer else { return }
        appliedTunDNSServer = state.tunDNSServer
        Task { await state.tunSettingsChanged() }
    }

    private var root: some View {
        @Bindable var state = state
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PanelSection(title: "通用") {
                    PanelRow(title: "颜色模式") {
                        AppearancePicker(selection: $state.appearanceMode)
                    }
                    PanelRow(title: "登录时启动") {
                        if state.launchAtLoginNeedsApproval {
                            Button("去允许…") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.settingsAction)
                                .help("已注册登录项，需在「系统设置 → 通用 → 登录项」中允许")
                        }
                        Toggle("登录时启动", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                            .labelsHidden().toggleStyle(.settingsSwitch)
                    }
                    PanelRow(title: "菜单栏显示网速") {
                        Toggle("菜单栏显示网速", isOn: $state.showSpeedInMenuBar).labelsHidden().toggleStyle(.settingsSwitch)
                    }
                    PanelRow(title: "切换节点时断开旧连接") {
                        Toggle("切换节点时断开旧连接", isOn: $state.closeConnectionsOnSwitch).labelsHidden().toggleStyle(.settingsSwitch)
                    }
                    PanelRow(title: "全局快捷键") {
                        Toggle("全局快捷键", isOn: $state.globalHotKeysEnabled).labelsHidden().toggleStyle(.settingsSwitch)
                            .help("⌃⌥⌘S 切换系统代理，⌃⌥⌘T 切换 TUN，⌃⌥⌘M 切换代理模式")
                    }
                    PanelRow(title: "允许局域网连接") {
                        Toggle("允许局域网连接", isOn: Binding(get: { state.runtime?.allowLan ?? false },
                                                 set: { v in Task { await state.setAllowLan(v) } }))
                            .labelsHidden().toggleStyle(.settingsSwitch)
                            .disabled(!state.isRunning)
                    }
                    PanelRow(title: "通过代理更新订阅") {
                        Toggle("通过代理更新订阅", isOn: $state.subscriptionViaProxy).labelsHidden().toggleStyle(.settingsSwitch)
                    }
                    PanelRow(title: "版本更新", divider: false) {
                        Text(state.appVersionText)
                            .font(Theme.numeral(12, weight: .regular)).foregroundStyle(.secondary)
                        if let update = state.availableUpdate {
                            Button("下载 v\(update.version)") { NSWorkspace.shared.open(update.htmlURL) }
                                .buttonStyle(.settingsAction)
                                .help("在 GitHub 打开 v\(update.version) 的发布页")
                        }
                        dataAction("检查更新", id: "update", disabled: false) {
                            await state.checkForUpdates()
                        }
                    }
                }

                PanelSection(title: "TUN") {
                    PanelRow(title: "内核授权") {
                        if state.isPrivileged {
                            Text("已授权").font(.callout).foregroundStyle(Theme.active)
                            Button("撤销") { Task { await state.revokePrivilege() } }.buttonStyle(.settingsAction)
                        } else {
                            Button("授权…") {
                                Task { if await state.grantPrivilege(), state.isRunning { await state.restartCore() } }
                            }
                            .buttonStyle(.settingsAction)
                        }
                    }
                    PanelRow(title: "协议栈") {
                        Picker("协议栈", selection: $state.tunStack) {
                            Text("跟随配置").tag("")
                            Text("Mixed").tag("mixed")
                            Text("gVisor").tag("gvisor")
                            Text("System").tag("system")
                        }
                        .panelPicker(width: 120)
                    }
                    PanelRow(title: "接管系统 DNS", divider: state.tunSetDNS) {
                        Toggle("接管系统 DNS", isOn: $state.tunSetDNS).labelsHidden().toggleStyle(.settingsSwitch)
                    }
                    if state.tunSetDNS {
                        PanelRow(title: "DNS 服务器", divider: false) {
                            TextField("223.5.5.5", text: $state.tunDNSServer)
                                .panelField()
                                .frame(width: 120)
                                .focused($dnsFieldFocused)
                                // 输入完成（回车或失焦）后再应用，避免每个字符都改一次系统 DNS
                                .onSubmit { applyDNSIfNeeded() }
                        }
                    }
                }
                .onAppear { appliedTunDNSServer = state.tunDNSServer }
                .onDisappear { applyDNSIfNeeded() }
                .onChange(of: dnsFieldFocused) { if !dnsFieldFocused { applyDNSIfNeeded() } }
                .onChange(of: state.tunStack) { Task { await state.tunSettingsChanged() } }
                .onChange(of: state.tunSetDNS) { Task { await state.tunSettingsChanged() } }

                PanelSection(title: "系统代理与测速") {
                    NavRow(title: "绕过代理的地址", icon: "arrow.uturn.right", value: "\(state.bypassList.count) 项") { editingBypass = true }
                    PanelRow(title: "备用混合端口", icon: "number") {
                        TextField("7890", value: $state.fallbackPort, format: .number.grouping(.never))
                            .panelField().frame(width: 70)
                    }
                    PanelRow(title: "测速地址", icon: "bolt") {
                        TextField("URL", text: $state.delayTestURL).panelField()
                    }
                    PanelRow(title: "测速超时（毫秒）", icon: "timer", divider: false) {
                        TextField("5000", value: $state.delayTimeout, format: .number.grouping(.never))
                            .panelField().frame(width: 70)
                    }
                }

                PanelSection(title: "内核与数据") {
                    PanelRow(title: "mihomo", icon: "cpu") {
                        Text(state.coreVersion.isEmpty ? "未安装" : state.coreVersion)
                            .font(Theme.numeral(12, weight: .regular)).foregroundStyle(.secondary)
                        Menu {
                            Button("重启内核") { Task { await state.restartCore() } }
                            Button("选择内核文件…") { Task { await state.installCoreFromFile() } }
                            Divider()
                            Button("打开工作目录") {
                                AppPaths.ensure()
                                NSWorkspace.shared.open(AppPaths.base)
                            }
                            Button("打开内核日志") { NSWorkspace.shared.open(AppPaths.coreLog) }
                            Button("mihomo 配置文档") { NSWorkspace.shared.open(URL(string: "https://wiki.metacubex.one/config/")!) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .tint(.secondary).foregroundStyle(.secondary).fixedSize()
                            .help("内核操作").accessibilityLabel("内核操作")
                    }
                    PanelRow(title: "远程规则集与代理集合", icon: "shippingbox") {
                        dataAction("全部更新", id: "providers", disabled: !state.isRunning || state.busy) {
                            await state.updateAllProviders()
                        }
                    }
                    PanelRow(title: "Geo 数据库", icon: "map") {
                        dataAction("更新", id: "geo", disabled: !state.isRunning || state.busy) {
                            await state.updateGeo()
                        }
                    }
                    PanelRow(title: "DNS 缓存", icon: "arrow.counterclockwise", divider: false) {
                        dataAction("清空", id: "dns", disabled: !state.isRunning) {
                            await state.flushDNSCache()
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

extension SettingsTab {
    /// 数据操作按钮：执行中在原位置显示进度圈，按钮宽度不变；完成后由面板底部提示反馈结果
    private func dataAction(_ title: String, id: String, disabled: Bool,
                            perform: @escaping () async -> Void) -> some View {
        let running = runningAction == id
        return Button {
            runningAction = id
            Task {
                await perform()
                if runningAction == id { runningAction = nil }
            }
        } label: {
            Text(title)
                .opacity(running ? 0 : 1)
                .overlay { if running { ProgressView().controlSize(.mini) } }
        }
        .buttonStyle(.settingsAction)
        .disabled(disabled || runningAction != nil)
        .accessibilityLabel(running ? "\(title)，进行中" : title)
    }
}

/// 颜色模式切换：与首页模式切换及标签栏统一的凸起选中块
private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases) { mode in
                let selected = mode == selection
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip - 1, style: .continuous)
                Button { selection = mode } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.secondary))
                        .frame(width: 28, height: 20)
                        .background {
                            if selected {
                                shape.fill(Theme.selectedSurface)
                                    .overlay(shape.strokeBorder(Theme.panelBorder, lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(shape)
                        .hoverHighlight(cornerRadius: Theme.Radius.chip - 1, enabled: !selected)
                }
                .buttonStyle(PressableStyle())
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("颜色模式")
    }
}

// MARK: - 绕过地址

private struct BypassPage: View {
    @Environment(AppState.self) private var state
    var back: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: "绕过代理的地址", back: back) {
                Button("应用") {
                    state.bypassText = draft
                    Task {
                        if state.systemProxyEnabled { await state.setSystemProxy(true) }
                        back()
                    }
                }
                .buttonStyle(.borderless)
                .toolbarAction(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(draft == state.bypassText)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextEditor(text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .card()
                HStack {
                    Text("每行一个，支持通配符与 CIDR").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { draft = SystemProxy.defaultBypass.joined(separator: "\n") }
                        .buttonStyle(.settingsAction)
                }
            }
            .padding(14)
        }
        .onAppear { draft = state.bypassText }
    }
}
