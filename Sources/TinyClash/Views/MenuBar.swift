import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = state.isRunning && (state.systemProxyEnabled || state.tunEnabled)
        HStack(spacing: 4) {
            Image(systemName: active ? "paperplane.circle.fill" : "paperplane.circle")
            if state.showSpeedInMenuBar && state.isRunning {
                Text("↓\(Format.compactSpeed(state.downSpeed)) ↑\(Format.compactSpeed(state.upSpeed))")
                    .monospacedDigit()
            }
        }
        .onAppear { WindowOpener.openAction = openWindow }
    }
}

struct MenuContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        Toggle("系统代理", isOn: Binding(
            get: { state.systemProxyEnabled },
            set: { v in Task { await state.setSystemProxy(v) } }
        ))
        .keyboardShortcut("s")
        .disabled(!state.isRunning)

        Toggle("TUN 模式", isOn: Binding(
            get: { state.tunEnabled },
            set: { v in Task { await state.setTun(v) } }
        ))
        .keyboardShortcut("t")
        .disabled(!state.isRunning)

        Divider()

        Picker("出站模式", selection: Binding(
            get: { state.currentMode },
            set: { m in Task { await state.setMode(m) } }
        )) {
            ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .disabled(!state.isRunning)

        if !state.visibleGroups.isEmpty {
            Divider()
            ForEach(state.visibleGroups) { group in
                GroupMenu(group: group)
            }
        }

        Divider()

        Menu("配置") {
            Picker("配置", selection: Binding(
                get: { state.selectedProfileID },
                set: { id in if let id { Task { await state.selectProfile(id) } } }
            )) {
                ForEach(state.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("更新全部订阅") { Task { await state.updateAllProfiles() } }
            Button("管理配置…") { openMain() }
        }

        Button("复制终端代理命令") { state.copyTerminalCommand() }
            .keyboardShortcut("c")
            .disabled(!state.isRunning)
        Button("打开 Web 面板") {
            if let url = state.dashboardURL { NSWorkspace.shared.open(url) }
        }
        .disabled(!state.isRunning)
        Button(state.isRunning ? "重启内核" : "启动内核") { Task { await state.restartCore() } }
            .keyboardShortcut("r")

        Divider()

        Button("打开主界面") { openMain() }
            .keyboardShortcut(",")
        Button("退出 TinyClash") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        var s = "mihomo \(state.coreVersion) · \(state.coreState.label)"
        if state.isRunning { s += " · ↓\(Format.speed(state.downSpeed)) ↑\(Format.speed(state.upSpeed))" }
        return s
    }

    private func openMain() {
        WindowOpener.openAction = openWindow
        WindowOpener.open()
    }
}

private struct GroupMenu: View {
    @Environment(AppState.self) private var state
    let group: ProxyItem

    var body: some View {
        Menu("\(group.name)    \(group.now ?? "")") {
            let members = group.all ?? []
            if group.isSelectable {
                Picker(group.name, selection: Binding(
                    get: { group.now ?? "" },
                    set: { name in Task { await state.select(group: group.name, proxy: name) } }
                )) {
                    ForEach(members, id: \.self) { name in
                        Text(title(for: name)).tag(name)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                Text("\(group.type)：自动选择").font(.caption)
                ForEach(members, id: \.self) { name in
                    Text((name == group.now ? "✓ " : "   ") + title(for: name))
                }
            }
            Divider()
            Button(state.testingGroups.contains(group.name) ? "测速中…" : "延迟测速") {
                Task { await state.testGroup(group.name) }
            }
        }
    }

    private func title(for name: String) -> String {
        guard let d = state.delay(of: name) else { return name }
        return d > 0 ? "\(name)    \(d) ms" : "\(name)    超时"
    }
}
