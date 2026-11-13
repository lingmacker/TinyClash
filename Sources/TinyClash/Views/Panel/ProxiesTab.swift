import SwiftUI

struct ProxiesTab: View {
    @Environment(AppState.self) private var state
    @State private var openGroup: String? = {
        #if TINYCLASH_PREVIEW
        return UserDefaults.standard.string(forKey: "uiOpenGroup")
        #else
        return nil
        #endif
    }()

    @State private var route = Route.list

    private enum Route { case list, add, edit(CustomGroup) }

    private var canEditGroups: Bool {
        guard let id = state.selectedProfileID, state.selectedProfile != nil else { return false }
        return !state.busy && state.coreState != .starting &&
            !state.isEditingSelectedProfile && !state.updatingProfiles.contains(id)
    }

    var body: some View {
        switch route {
        case .add:
            GroupEditorPage { route = .list }
        case .edit(let group):
            GroupEditorPage(original: group, canEdit: canEditGroups, onDeleted: { openGroup = nil }) {
                route = .list
            }
        case .list:
            Group {
                if let name = openGroup, let group = state.proxies[name] {
                    GroupDetail(group: group, canEdit: canEditGroups, edit: { edit(name) }) { openGroup = nil }
                } else {
                    overview
                }
            }
            .onChange(of: state.groupNames) {
                if let name = openGroup, state.proxies[name] == nil {
                    openGroup = nil
                }
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(state.visibleGroups.count) 个策略组").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    Task { for group in state.visibleGroups { await state.testGroup(group.name) } }
                } label: { Image(systemName: "bolt.fill") }
                    .help("全部测速")
                    .accessibilityLabel("全部测速")
                    .disabled(!state.isRunning || state.visibleGroups.allSatisfy { state.pendingNewGroupNames.contains($0.name) } || !state.testingGroups.isEmpty)
                Button { route = .add } label: {
                    Label("添加策略组", systemImage: "plus")
                }
                .disabled(!canEditGroups)
                if state.isEditingSelectedProfile || state.coreState == .starting {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(14)
            Divider()
            if state.coreState == .starting {
                if state.currentMode != .direct && !state.visibleGroups.isEmpty {
                    groupList
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("内核启动中…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if !state.isRunning {
                EmptyHint(text: state.selectedProfile == nil ? "请先在「配置」页添加并选择配置" : "内核未运行\n仍可添加策略组并写入当前配置")
                    .multilineTextAlignment(.center)
            } else if state.currentMode == .direct {
                EmptyHint(text: "直连模式下所有流量不经过代理\n仍可添加策略组并写入当前配置")
                    .multilineTextAlignment(.center)
            } else if state.visibleGroups.isEmpty {
                EmptyHint(text: "当前没有策略组\n点击「添加策略组」创建一个")
                    .multilineTextAlignment(.center)
            } else {
                groupList
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(state.visibleGroups) { group in
                    Button { openGroup = group.name } label: {
                        GroupCard(group: group).hoverHighlight()
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        if group.name != "GLOBAL" {
                            Button("编辑策略组") { edit(group.name) }
                                .disabled(!canEditGroups)
                            Button("删除策略组", role: .destructive) {
                                Task { await state.deleteGroup(named: group.name) }
                            }
                            .disabled(!canEditGroups)
                        }
                    }
                    .accessibilityAction(named: "编辑策略组") {
                        if group.name != "GLOBAL" && canEditGroups { edit(group.name) }
                    }
                    .accessibilityAction(named: "删除策略组") {
                        if group.name != "GLOBAL" && canEditGroups {
                            Task { await state.deleteGroup(named: group.name) }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

extension ProxiesTab {
    private func edit(_ name: String) {
        guard let definition = state.groupDefinition(named: name) else {
            state.errorMessage = "无法在当前配置文件中解析策略组「\(name)」（可能来自外部修改或使用了暂不支持的写法），请在编辑器中修改 YAML"
            return
        }
        route = .edit(definition)
    }
}

private struct GroupCard: View {
    @Environment(AppState.self) private var state
    let group: ProxyItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(group.name).font(.callout.weight(.semibold)).lineLimit(1)
                Tag(text: typeTitle(group.type))
                Spacer(minLength: 4)
                if state.testingGroups.contains(group.name) { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                let isPending = state.pendingNewGroupNames.contains(group.name)
                Text(isPending ? "待重启生效" : (group.now ?? "—")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !isPending, let now = group.now { LatencyLabel(ms: state.delay(of: now)) }
            }
            HealthStrip(members: group.all ?? [])
        }
        .panel(padding: 12)
        .contentShape(Rectangle())
    }
}

/// 每个成员一格，颜色即延迟（最多显示 28 格，以免超出卡片宽度）
private struct HealthStrip: View {
    @Environment(AppState.self) private var state
    let members: [String]
    private let limit = 28

    var body: some View {
        HStack(spacing: 3) {
            ForEach(members.prefix(limit), id: \.self) { name in
                let d = state.delay(of: name)
                Capsule()
                    .fill(d == nil ? Color.secondary.opacity(0.22) : Theme.latency(d))
                    .frame(width: 6, height: 6)
            }
            if members.count > limit {
                Text("+\(members.count - limit)").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

func typeTitle(_ type: String) -> String {
    switch type {
    case "Selector": return "手动"
    case "URLTest": return "自动"
    case "Fallback": return "故障转移"
    case "LoadBalance": return "负载均衡"
    default: return type
    }
}

private struct GroupDetail: View {
    @Environment(AppState.self) private var state
    let group: ProxyItem
    var canEdit: Bool
    var edit: () -> Void
    var back: () -> Void
    @State private var search = ""

    private var members: [String] {
        let all = group.all ?? []
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: group.name, back: back) {
                HStack(spacing: 10) {
                    if group.name != "GLOBAL" {
                        if state.isEditingSelectedProfile {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(action: edit) { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("编辑策略组")
                                .accessibilityLabel("编辑策略组")
                                .disabled(!canEdit)
                            Button(role: .destructive) {
                                Task {
                                    if await state.deleteGroup(named: group.name) {
                                        back()
                                    }
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("从配置中删除策略组")
                            .accessibilityLabel("删除策略组")
                            .disabled(!canEdit)
                        }
                    }
                    if state.testingGroups.contains(group.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await state.testGroup(group.name) } } label: { Label("测速", systemImage: "bolt.fill") }
                            .buttonStyle(.borderless)
                            .disabled(state.pendingNewGroupNames.contains(group.name))
                    }
                }
            }
            if (group.all?.count ?? 0) > 10 {
                TextField("搜索节点", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if state.pendingNewGroupNames.contains(group.name) {
                Text("新增策略组尚未加载到内核，点击顶部「需重启生效」重启后即可切换节点与测速")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            } else if !group.isSelectable {
                Text("\(typeTitle(group.type))分组由内核自动选择节点，无法手动切换")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(members, id: \.self) { NodeRow(name: $0, group: group) }
                }
                .padding(14)
            }
        }
    }
}

private struct NodeRow: View {
    @Environment(AppState.self) private var state
    let name: String
    let group: ProxyItem
    @State private var hovering = false

    var body: some View {
        let isPending = state.pendingNewGroupNames.contains(group.name)
        let canSelect = group.isSelectable && !isPending
        let selected = !isPending && group.now == name
        let item = state.proxies[name]
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .opacity(selected || canSelect ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(detail(item)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if state.testingProxies.contains(name) {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await state.testProxy(name) } } label: {
                    LatencyLabel(ms: state.delay(of: name), placeholder: "测速")
                }
                .buttonStyle(.plain)
                .help("测试延迟")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                               : AnyShapeStyle(hovering ? Theme.inset : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 && canSelect }
        .onTapGesture {
            guard canSelect, !selected else { return }
            Task { await state.select(group: group.name, proxy: name) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detail(_ item: ProxyItem?) -> String {
        guard let item else { return "" }
        if item.isGroup { return "分组 → \(item.now ?? "—")" }
        return item.udp == true ? "\(item.type) · UDP" : item.type
    }
}

struct EmptyHint: View {
    var text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
