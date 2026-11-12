import SwiftUI

struct ProxiesView: View {
    @Environment(AppState.self) private var state
    @State private var expanded: Set<String> = []
    @State private var search = ""

    var body: some View {
        Group {
            if !state.isRunning {
                EmptyHint(text: "内核未运行")
            } else if state.currentMode == .direct {
                EmptyHint(text: "直连模式下所有流量不经过代理")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.visibleGroups) { group in
                            GroupSection(group: group, search: search, expanded: Binding(
                                get: { expanded.contains(group.name) },
                                set: { if $0 { expanded.insert(group.name) } else { expanded.remove(group.name) } }
                            ))
                        }
                    }
                    .padding(18)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索节点")
        .toolbar {
            ToolbarItem {
                Picker("模式", selection: Binding(
                    get: { state.currentMode },
                    set: { m in Task { await state.setMode(m) } }
                )) {
                    ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!state.isRunning)
            }
            ToolbarItem {
                Button { Task { await state.refreshProxies() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
    }
}

private struct GroupSection: View {
    @Environment(AppState.self) private var state
    let group: ProxyItem
    let search: String
    @Binding var expanded: Bool

    private var members: [String] {
        let all = group.all ?? []
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded || !search.isEmpty ? 90 : 0))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(group.name).font(.headline)
                        Text(group.type).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        Text("\(group.all?.count ?? 0)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(group.now ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.testingGroups.contains(group.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await state.testGroup(group.name) } } label: { Image(systemName: "bolt.fill") }
                        .buttonStyle(.borderless)
                        .help("延迟测速")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded || !search.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                    ForEach(members, id: \.self) { name in
                        NodeCard(name: name, group: group)
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct NodeCard: View {
    @Environment(AppState.self) private var state
    let name: String
    let group: ProxyItem

    var body: some View {
        let selected = group.now == name
        let item = state.proxies[name]
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout).lineLimit(1)
                HStack(spacing: 4) {
                    Text(item?.type ?? "").font(.caption2).foregroundStyle(.secondary)
                    if item?.udp == true { Text("UDP").font(.caption2).foregroundStyle(.secondary) }
                    if item?.isGroup == true, let now = item?.now {
                        Text("→ \(now)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            delayView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            guard group.isSelectable, !selected else { return }
            Task { await state.select(group: group.name, proxy: name) }
        }
        .help(group.isSelectable ? "点击选择" : "该组为自动选择，不可手动切换")
    }

    @ViewBuilder private var delayView: some View {
        if state.testingProxies.contains(name) {
            ProgressView().controlSize(.mini)
        } else {
            Button { Task { await state.testProxy(name) } } label: {
                Text(delayText).font(.caption.monospacedDigit()).foregroundStyle(delayColor)
            }
            .buttonStyle(.borderless)
        }
    }

    private var delay: Int? { state.delay(of: name) }

    private var delayText: String {
        guard let d = delay else { return "测速" }
        return d > 0 ? "\(d) ms" : "超时"
    }

    private var delayColor: Color {
        guard let d = delay else { return .secondary }
        switch d {
        case 0: return .red
        case ..<300: return .green
        case ..<800: return .orange
        default: return .red
        }
    }
}
