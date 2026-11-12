import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, proxies, profiles, connections, rules, providers, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .proxies: return "代理"
        case .profiles: return "配置"
        case .connections: return "连接"
        case .rules: return "规则"
        case .providers: return "资源"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .proxies: return "globe.asia.australia"
        case .profiles: return "doc.text"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .rules: return "list.bullet.rectangle"
        case .providers: return "shippingbox"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var page: Page = .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            Group {
                switch page {
                case .overview: OverviewView()
                case .proxies: ProxiesView()
                case .profiles: ProfilesView()
                case .connections: ConnectionsView()
                case .rules: RulesView()
                case .providers: ProvidersView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle(page.title)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            WindowOpener.openAction = openWindow
            NSApp.setActivationPolicy(.regular)
            if state.profiles.isEmpty { page = .profiles }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .alert("提示", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好") { state.errorMessage = nil }
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.errorMessage ?? "", forType: .string)
                state.errorMessage = nil
            }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(state.coreState.label).font(.caption)
            }
            if state.isRunning {
                Text("↓ \(Format.speed(state.downSpeed))").font(.caption2).monospacedDigit()
                Text("↑ \(Format.speed(state.upSpeed))").font(.caption2).monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var statusColor: Color {
        switch state.coreState {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .gray
        case .failed: return .red
        }
    }
}

/// 通用卡片容器
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyHint: View {
    var text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
