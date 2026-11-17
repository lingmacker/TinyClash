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
    @State private var offlineGroups: [ProxyItem] = []

    private enum Route { case list, add, edit(CustomGroup), requests }

    private struct OfflineKey: Equatable {
        var running: Bool
        var profileID: UUID?
        var revision: Int
    }

    private var offlineKey: OfflineKey {
        OfflineKey(running: state.isRunning, profileID: state.selectedProfileID, revision: state.profileRevision)
    }

    private var canEditGroups: Bool { state.canEditSelectedProfile }

    private var displayedGroups: [ProxyItem] {
        state.isRunning ? state.visibleGroups : offlineGroups
    }

    private func resolvedGroup(_ name: String) -> ProxyItem? {
        state.isRunning ? state.proxies[name] : offlineGroups.first { $0.name == name }
    }

    private func syncOfflineGroups() {
        offlineGroups = state.isRunning ? [] : state.yamlGroupItems()
        if let name = openGroup, resolvedGroup(name) == nil {
            openGroup = nil
        }
    }

    var body: some View {
        content
            .onAppear {
                syncOfflineGroups()
                takeOpenGroupRequest()
            }
            .onChange(of: offlineKey) { syncOfflineGroups() }
            .onChange(of: state.openGroupRequest) { takeOpenGroupRequest() }
            .onChange(of: state.selectedProfileID) {
                if state.openGroupRequest == nil {
                    openGroup = nil
                    route = .list
                }
            }
            .onChange(of: state.profileRevision) {
                if case .edit = route, !state.isEditingSelectedProfile {
                    route = .list
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .requests:
            RequestLogsPage { route = .list }
        case .add:
            GroupEditorPage { route = .list }
        case .edit(let group):
            GroupEditorPage(original: group, canEdit: canEditGroups, onDeleted: { openGroup = nil }) {
                route = .list
            }
        case .list:
            Group {
                if let name = openGroup, let group = resolvedGroup(name) {
                    GroupDetail(group: group, canEdit: canEditGroups, edit: { edit(name) }) { openGroup = nil }
                } else {
                    overview
                }
            }
            .onChange(of: state.groupNames) {
                if let name = openGroup, resolvedGroup(name) == nil {
                    openGroup = nil
                }
            }
        }
    }

    /// 首页点击出站路径后直接进入对应分组
    private func takeOpenGroupRequest() {
        guard let name = state.openGroupRequest else { return }
        state.openGroupRequest = nil
        route = .list
        openGroup = name
    }

    private var overview: some View {
        let groups = displayedGroups
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(groups.count) 个策略组").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    Task { await state.testGroups(state.visibleGroups.map(\.name)) }
                } label: { TestingLabel(testing: !state.testingGroups.isEmpty) }
                    .toolbarAction()
                    .help("测试全部策略组的延迟")
                    .disabled(!state.isRunning || state.visibleGroups.allSatisfy { state.pendingNewGroupNames.contains($0.name) } || !state.testingGroups.isEmpty)
                Button { route = .requests } label: {
                    Label("请求日志", systemImage: "list.bullet.rectangle")
                }
                .toolbarAction()
                Button { route = .add } label: {
                    Label("添加策略组", systemImage: "plus")
                }
                .toolbarAction(prominent: true)
                .disabled(!canEditGroups)
                if state.isEditingSelectedProfile || state.coreState == .starting {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(Theme.toolbarFont)
            .buttonStyle(.borderless)
            .padding(14)
            Divider()
            if state.coreState == .starting {
                if state.currentMode != .direct && !groups.isEmpty {
                    groupList(groups)
                } else {
                    LoadingHint(text: "内核启动中…")
                }
            } else if state.selectedProfile == nil {
                EmptyHint(text: "请先在「配置」页添加并选择配置")
                    .multilineTextAlignment(.center)
            } else if state.isRunning && state.currentMode == .direct {
                EmptyHint(text: "直连模式下所有流量不经过代理\n仍可添加策略组并写入当前配置")
                    .multilineTextAlignment(.center)
            } else if groups.isEmpty {
                EmptyHint(text: "当前没有策略组\n点击「添加策略组」创建一个")
                    .multilineTextAlignment(.center)
            } else {
                groupList(groups)
            }
        }
    }

    private func groupList(_ groups: [ProxyItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(groups) { group in
                    Button { openGroup = group.name } label: {
                        GroupCard(group: group).hoverHighlight()
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        if group.name != "GLOBAL" {
                            Button("编辑策略组") { edit(group.name) }
                                .disabled(!canEditGroups)
                            Button("删除策略组…", role: .destructive) { state.confirmDeleteGroup(group.name) }
                                .disabled(!canEditGroups)
                        }
                    }
                    .accessibilityAction(named: "编辑策略组") {
                        if group.name != "GLOBAL" && canEditGroups { edit(group.name) }
                    }
                    .accessibilityAction(named: "删除策略组") {
                        if group.name != "GLOBAL" && canEditGroups { state.confirmDeleteGroup(group.name) }
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
                Text(group.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Tag(text: typeTitle(group.type), tint: Theme.groupTypeTint(group.type))
                Spacer(minLength: 4)
                if state.testingGroups.contains(group.name) { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                let isOffline = !state.isRunning
                let isPending = state.pendingNewGroupNames.contains(group.name)
                // 当前选择是子分组时一路解析到最终节点，与首页出站路径一致
                let chain = Array(state.resolvedChain(from: group).dropFirst())
                let routeText = isOffline ? "内核未运行" : (isPending ? "待重启生效" : (chain.isEmpty ? "—" : chain.joined(separator: " › ")))
                Text(routeText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .help(chain.joined(separator: " › "))
                Spacer(minLength: 4)
                if !isOffline && !isPending, let last = chain.last { LatencyLabel(ms: state.delay(of: last)) }
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
    @AppStorage("sortNodesByDelay") private var sortByDelay = false

    /// 组内节点协议都相同时，每行重复协议名没有信息量，只在混用时显示
    private var showsProtocol: Bool {
        let builtin: Set = ["Direct", "Reject", "RejectDrop", "Pass", "Compatible"]
        return Set((group.all ?? []).compactMap { state.proxies[$0] }
            .filter { !$0.isGroup && !builtin.contains($0.type) }.map(\.type)).count > 1
    }

    private var members: [String] {
        let all = group.all ?? []
        let filtered = search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
        guard sortByDelay else { return filtered }
        // 未测速和超时（0）的排在后面，其余按延迟升序；稳定排序保留原顺序
        func key(_ name: String) -> Int {
            guard let d = state.delay(of: name), d > 0 else { return .max }
            return d
        }
        return filtered.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }

    private func nodeDetail(_ item: ProxyItem?, showsProtocol: Bool) -> String? {
        guard let item else { return nil }
        if item.isGroup { return "分组 › \(item.now ?? "—")" }
        return showsProtocol ? (item.udp == true ? "\(item.type) · UDP" : item.type) : nil
    }

    var body: some View {
        let isOffline = !state.isRunning
        let isPending = isOffline || state.pendingNewGroupNames.contains(group.name)
        let canSelect = state.isRunning && group.isSelectable && !isPending
        let showProto = showsProtocol
        return VStack(spacing: 0) {
            SubpageHeader(title: group.name, back: back) {
                // 只保留两个常用操作；编辑、删除这类低频操作收进 ⋯ 菜单，删除不再紧挨着其他按钮
                HStack(spacing: 10) {
                    let testing = state.testingGroups.contains(group.name)
                    Button { Task { await state.testGroup(group.name) } } label: { TestingLabel(testing: testing) }
                        .buttonStyle(.borderless)
                        .toolbarAction(prominent: true)
                        .help("测试本组全部节点的延迟")
                        .disabled(!state.isRunning || testing || state.pendingNewGroupNames.contains(group.name))
                    Menu {
                        Toggle("按延迟排序", isOn: $sortByDelay)
                        if group.name != "GLOBAL" {
                            Divider()
                            Button("编辑策略组…", action: edit).disabled(!canEdit)
                            Button("删除策略组…", role: .destructive) { state.confirmDeleteGroup(group.name, onDeleted: back) }
                                .disabled(!canEdit)
                        }
                    } label: {
                        if state.isEditingSelectedProfile {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("排序与编辑")
                    .accessibilityLabel("「\(group.name)」的更多操作")
                }
            }
            if (group.all?.count ?? 0) > 10 {
                TextField("搜索节点", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if isOffline {
                Text("内核未运行，启动后可切换节点与测速；仍可编辑或删除此策略组")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            } else if state.pendingNewGroupNames.contains(group.name) {
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
                // 两列节点卡片：一屏能看到的节点数约为单列的两倍
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s),
                                    GridItem(.flexible(), spacing: Theme.Space.s)],
                          spacing: Theme.Space.s) {
                    ForEach(members, id: \.self) { name in
                        NodeCell(
                            name: name,
                            groupName: group.name,
                            selected: !isPending && group.now == name,
                            canSelect: canSelect,
                            canTest: state.isRunning,
                            detail: nodeDetail(state.proxies[name], showsProtocol: showProto),
                            delay: state.delay(of: name),
                            isTesting: state.testingProxies.contains(name),
                            onSelect: {
                                guard canSelect, group.now != name else { return }
                                Task { await state.select(group: group.name, proxy: name) }
                            },
                            onTest: {
                                guard state.isRunning else { return }
                                Task { await state.testProxy(name) }
                            },
                            onCopy: { state.copy(name) }
                        )
                        .equatable()
                    }
                }
                .padding(14)
            }
        }
    }
}

/// 节点卡片：整张卡片是选择按钮；右下角的延迟读数是独立的测速按钮。
/// 仅接收纯值参数并实现 Equatable，避免单节点测速完成时全表重绘。
private struct NodeCell: View, Equatable {
    let name: String
    /// 参与比较：闭包捕获了所属策略组，换组时必须重建，否则会对旧组执行选择
    let groupName: String
    let selected: Bool
    let canSelect: Bool
    let canTest: Bool
    let detail: String?
    let delay: Int?
    let isTesting: Bool
    var onSelect: () -> Void
    var onTest: () -> Void
    var onCopy: () -> Void

    static func == (lhs: NodeCell, rhs: NodeCell) -> Bool {
        lhs.name == rhs.name
            && lhs.groupName == rhs.groupName
            && lhs.selected == rhs.selected
            && lhs.canSelect == rhs.canSelect
            && lhs.canTest == rhs.canTest
            && lhs.detail == rhs.detail
            && lhs.delay == rhs.delay
            && lhs.isTesting == rhs.isTesting
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: onSelect) {
                card(selected: selected, detail: detail)
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSelect)
            .accessibilityLabel(name)
            .accessibilityValue(Theme.latencyText(delay))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: "测试延迟", onTest)
            latency
                .padding(.trailing, 10)
                .padding(.bottom, 8)
        }
        .help(name)
        .contextMenu {
            Button("测试延迟", action: onTest).disabled(!canTest)
            Button("复制节点名", action: onCopy)
        }
    }

    private func card(selected: Bool, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.primary))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentForeground)
                }
            }
            Text(detail ?? " ")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.trailing, 56)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.controlFill : Theme.panel,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            .strokeBorder(selected ? Theme.accent.opacity(0.45) : Theme.panelBorder, lineWidth: selected ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .hoverHighlight(cornerRadius: Theme.Radius.tile)
    }

    @ViewBuilder private var latency: some View {
        if isTesting {
            ProgressView().controlSize(.mini)
        } else {
            Button(action: onTest) {
                LatencyLabel(ms: delay, placeholder: "测速")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTest)
            .help("测试延迟")
            .accessibilityLabel("测试「\(name)」的延迟")
        }
    }
}

/// 测速按钮：测速中按钮置灰，进度显示在各策略组和节点上
private struct TestingLabel: View {
    var testing: Bool

    var body: some View {
        Label("测速", systemImage: "bolt.fill")
            .accessibilityLabel(testing ? "正在测速" : "测速")
    }
}

struct EmptyHint: View {
    var text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
