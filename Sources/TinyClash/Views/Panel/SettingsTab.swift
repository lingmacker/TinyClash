import SwiftUI

struct SettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var editingBypass = false

    var body: some View {
        if editingBypass {
            BypassPage(back: { editingBypass = false })
        } else {
            root
        }
    }

    private var root: some View {
        @Bindable var state = state
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PanelSection(title: "通用") {
                    PanelRow(title: "登录时启动") {
                        Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    PanelRow(title: "菜单栏显示网速") {
                        Toggle("", isOn: $state.showSpeedInMenuBar).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    PanelRow(title: "切换节点时断开旧连接") {
                        Toggle("", isOn: $state.closeConnectionsOnSwitch).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    PanelRow(title: "允许局域网连接") {
                        Toggle("", isOn: Binding(get: { state.runtime?.allowLan ?? false },
                                                 set: { v in Task { await state.setAllowLan(v) } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!state.isRunning)
                    }
                    PanelRow(title: "通过代理更新订阅", divider: false) {
                        Toggle("", isOn: $state.subscriptionViaProxy).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }

                PanelSection(title: "TUN", footer: "TUN 需以 root 运行内核：授权会把内核设为 root 所有并加 setuid 位。其余参数沿用配置文件的 tun 字段。") {
                    PanelRow(title: "内核授权") {
                        if state.isPrivileged {
                            Text("已授权").font(.callout).foregroundStyle(Theme.active)
                            Button("撤销") { Task { await state.revokePrivilege() } }.controlSize(.small)
                        } else {
                            Button("授权…") {
                                Task { if await state.grantPrivilege(), state.isRunning { await state.restartCore() } }
                            }
                            .controlSize(.small)
                        }
                    }
                    PanelRow(title: "协议栈") {
                        Picker("", selection: $state.tunStack) {
                            Text("跟随配置").tag("")
                            Text("Mixed").tag("mixed")
                            Text("gVisor").tag("gvisor")
                            Text("System").tag("system")
                        }
                        .labelsHidden().fixedSize()
                    }
                    PanelRow(title: "接管系统 DNS", divider: state.tunSetDNS) {
                        Toggle("", isOn: $state.tunSetDNS).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if state.tunSetDNS {
                        PanelRow(title: "DNS 服务器", divider: false) {
                            TextField("223.5.5.5", text: $state.tunDNSServer)
                                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        }
                    }
                }

                PanelSection(title: "系统代理与测速") {
                    NavRow(title: "绕过代理的地址", icon: "arrow.uturn.right", value: "\(state.bypassList.count) 项") { editingBypass = true }
                    PanelRow(title: "备用混合端口", icon: "number") {
                        TextField("7890", value: $state.fallbackPort, format: .number.grouping(.never))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 70)
                    }
                    PanelRow(title: "测速地址", icon: "bolt") {
                        TextField("URL", text: $state.delayTestURL).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    }
                    PanelRow(title: "测速超时（毫秒）", icon: "timer", divider: false) {
                        TextField("5000", value: $state.delayTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 70)
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
                            Button("打开工作目录") { NSWorkspace.shared.open(AppPaths.base) }
                            Button("打开内核日志") { NSWorkspace.shared.open(AppPaths.coreLog) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    PanelRow(title: "规则集与代理集合", icon: "shippingbox") {
                        Button("全部更新") { Task { await state.updateAllProviders() } }.controlSize(.small)
                            .disabled(!state.isRunning || state.busy)
                    }
                    PanelRow(title: "Geo 数据库", icon: "map") {
                        Button("更新") { Task { await state.updateGeo() } }.controlSize(.small)
                            .disabled(!state.isRunning || state.busy)
                    }
                    PanelRow(title: "DNS 缓存", icon: "arrow.counterclockwise", divider: false) {
                        Button("清空") {
                            Task {
                                try? await state.api?.flushFakeIP()
                                try? await state.api?.flushDNS()
                            }
                        }
                        .controlSize(.small)
                        .disabled(!state.isRunning)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if state.busy { ProgressView().controlSize(.mini).padding(.top, 2) }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - 绕过地址

private struct BypassPage: View {
    @Environment(AppState.self) private var state
    var back: () -> Void

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            SubpageHeader(title: "绕过代理的地址", back: back) {
                Button("应用") {
                    Task {
                        if state.systemProxyEnabled { await state.setSystemProxy(true) }
                        back()
                    }
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextEditor(text: $state.bypassText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                HStack {
                    Text("每行一个，支持通配符与 CIDR").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { state.bypassText = SystemProxy.defaultBypass.joined(separator: "\n") }
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
    }
}
