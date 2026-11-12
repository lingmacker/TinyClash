import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var pickingCore = false
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { state.launchAtLogin = $0; launchAtLogin = state.launchAtLogin }
                ))
                Toggle("在菜单栏显示网速", isOn: $state.showSpeedInMenuBar)
                Toggle("切换节点 / 模式时断开已有连接", isOn: $state.closeConnectionsOnSwitch)
                Toggle("通过代理更新订阅", isOn: $state.subscriptionViaProxy)
            }

            Section {
                TextField("备用混合端口", value: $state.fallbackPort, format: .number.grouping(.never))
                VStack(alignment: .leading) {
                    Text("绕过代理的地址（每行一个）")
                    TextEditor(text: $state.bypassText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("恢复默认") { state.bypassText = SystemProxy.defaultBypass.joined(separator: "\n") }
                    Spacer()
                    Button("应用") { Task { if state.systemProxyEnabled { await state.setSystemProxy(true) } } }
                }
            } header: {
                Text("系统代理")
            } footer: {
                Text("端口取自配置文件中的 mixed-port / port / socks-port；若配置未设置任何入站端口，将使用备用混合端口。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("内核授权") {
                    HStack {
                        Text(state.isPrivileged ? "已授权（root + setuid）" : "未授权")
                            .foregroundStyle(state.isPrivileged ? .green : .secondary)
                        if state.isPrivileged {
                            Button("撤销") { Task { await state.revokePrivilege() } }
                        } else {
                            Button("授权") { Task { if await state.grantPrivilege(), state.isRunning { await state.restartCore() } } }
                        }
                    }
                }
                Picker("协议栈", selection: $state.tunStack) {
                    Text("跟随配置文件").tag("")
                    Text("Mixed").tag("mixed")
                    Text("gVisor").tag("gvisor")
                    Text("System").tag("system")
                }
                Toggle("TUN 开启时接管系统 DNS", isOn: $state.tunSetDNS)
                TextField("系统 DNS 服务器", text: $state.tunDNSServer)
                    .disabled(!state.tunSetDNS)
            } header: {
                Text("TUN 模式")
            } footer: {
                Text("TUN 需要以 root 运行内核，授权会将内核设为 root 所有并加 setuid 位。其余 TUN 参数（auto-route、dns-hijack 等）沿用配置文件中的 tun 字段；建议配置中启用 dns 并使用 fake-ip。修改协议栈后需重新开启 TUN。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("延迟测试") {
                TextField("测试地址", text: $state.delayTestURL)
                TextField("超时（毫秒）", value: $state.delayTimeout, format: .number.grouping(.never))
            }

            Section("内核") {
                LabeledContent("版本", value: state.coreVersion.isEmpty ? "未安装" : state.coreVersion)
                LabeledContent("路径") {
                    Text(AppPaths.coreBinary.path).font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button("选择内核文件…") { pickingCore = true }
                    Button("打开工作目录") { NSWorkspace.shared.open(AppPaths.base) }
                    Button("内核日志") { NSWorkspace.shared.open(AppPaths.coreLog) }
                    Spacer()
                    Button("重启内核") { Task { await state.restartCore() } }
                }
            }

            Section("关于") {
                LabeledContent("TinyClash", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Link("mihomo 配置文档", destination: URL(string: "https://wiki.metacubex.one/config/")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = state.launchAtLogin }
        .fileImporter(isPresented: $pickingCore, allowedContentTypes: [.unixExecutable, .data]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await state.installCore(from: url)
            }
        }
    }
}
