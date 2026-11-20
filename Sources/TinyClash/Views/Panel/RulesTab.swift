import SwiftUI

struct RulesTab: View {
    @Environment(AppState.self) private var state
    @State private var route = Route.list
    @State private var rules: [RuleItem] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    private enum Route {
        case list, add, addProvider, edit(RuleEditorPage.Editing), providers
        var isList: Bool { if case .list = self { return true } else { return false } }
    }

    private var canEditRules: Bool { state.canEditSelectedProfile }

    private struct IndexedRule: Identifiable {
        var index: Int
        var rule: RuleItem
        var id: Int { index }
    }

    private func filteredRules() -> [IndexedRule] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = rules.enumerated().map { IndexedRule(index: $0.offset, rule: $0.element) }
        guard !query.isEmpty else { return all }
        return all.filter { item in
            let typeText = ConfigOverlay.yamlRuleType(item.rule.type)
            let payloadText = item.rule.payload.isEmpty && typeText == "MATCH" ? "Default" : item.rule.payload
            return payloadText.localizedCaseInsensitiveContains(query)
                || typeText.localizedCaseInsensitiveContains(query)
                || item.rule.proxy.localizedCaseInsensitiveContains(query)
        }
    }

    private struct LoadKey: Equatable {
        var running: Bool
        var profileID: UUID?
        var port: Int?
        var profileRevision: Int
    }

    private var loadKey: LoadKey {
        LoadKey(running: state.isRunning,
                profileID: state.selectedProfileID,
                port: state.api?.port,
                profileRevision: state.profileRevision)
    }

    var body: some View {
        // 列表常驻，进入编辑页后返回时保留滚动位置，不重新加载
        ZStack(alignment: .top) {
            ruleList
                .task(id: loadKey) { await loadRules() }
                .opacity(route.isList ? 1 : 0)
                .disabled(!route.isList)
                .accessibilityHidden(!route.isList)
            switch route {
            case .list:
                EmptyView()
            case .add:
                RuleEditorPage { route = .list }.background(Theme.canvas)
            case .addProvider:
                if let id = state.selectedProfileID {
                    RuleProviderEditorPage(profileID: id) { route = .list }.background(Theme.canvas)
                }
            case .edit(let editing):
                RuleEditorPage(editing: editing, canEdit: canEditRules) { route = .list }.background(Theme.canvas)
            case .providers:
                RuleProvidersPage { route = .list }
                    .id(state.selectedProfileID)
                    .background(Theme.canvas)
            }
        }
        .onChange(of: state.isPanelOpen) {
            if state.isPanelOpen && state.activeTab == .rules && route.isList {
                Task { await loadRules() }
            }
        }
        .onChange(of: state.activeTab) {
            if state.activeTab == .rules && state.isPanelOpen && route.isList {
                Task { await loadRules() }
            }
        }
        .onChange(of: state.selectedProfileID) {
            route = .list
            search = ""
        }
        .onChange(of: state.profileRevision) {
            if state.selectedProfile != nil {
                rules = state.yamlRuleItems()
            }
            if case .edit = route, !state.isEditingSelectedProfile {
                route = .list
            }
        }
    }

    private func confirmDelete(_ rule: RuleItem, at index: Int) {
        let text = [ConfigOverlay.yamlRuleType(rule.type), rule.payload, rule.proxy].filter { !$0.isEmpty }.joined(separator: ",")
        state.confirm("删除这条规则？", message: "\(text)\n会从当前配置的 YAML 中删除。") {
            Task { await state.deleteRule(rule, at: index) }
        }
    }

    private var ruleList: some View {
        let filtered = filteredRules()
        let hasQuery = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(hasQuery ? "\(filtered.count) / \(rules.count) 条规则" : "\(rules.count) 条规则")
                    .foregroundStyle(.secondary)
                    .help(!state.isRunning
                          ? "按当前配置文件中的规则顺序显示"
                          : "按内核匹配顺序显示；点击 RuleSet 规则可在编辑页下方查看规则集包含的条目")
                Spacer(minLength: 4)
                Button { route = .providers } label: {
                    Label("规则集", systemImage: "square.stack.3d.up")
                }
                .toolbarAction()
                .help("管理当前配置的 rule-providers")
                Menu {
                    Button("添加规则…") { route = .add }
                    Button("添加规则集…") { route = .addProvider }
                } label: {
                    Label("添加", systemImage: "plus")
                }
                // borderless 按钮样式下菜单标签会被 AppKit 按系统字号重绘；plain 样式才沿用
                // 这里的 toolbarFont 字号，与旁边的工具栏按钮一样大
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .toolbarAction(prominent: true)
                .disabled(!canEditRules)
                .help("添加规则或规则集")
                if state.isEditingSelectedProfile {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(Theme.toolbarFont)
            .buttonStyle(.borderless)
            .padding(14)
            if rules.count > 10 || !search.isEmpty {
                TextField("搜索规则内容、类型或策略", text: $search)
                    .panelField(alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .accessibilityLabel("搜索规则")
            }
            Divider()
            if state.coreState == .starting && rules.isEmpty {
                LoadingHint(text: "内核启动中…")
            } else if state.selectedProfile == nil {
                EmptyHint(text: "请先在「配置」页添加并选择配置")
                    .multilineTextAlignment(.center)
            } else if loading && rules.isEmpty {
                LoadingHint(text: "读取规则中…")
            } else if let error {
                VStack(spacing: 10) {
                    Text("读取规则失败").font(.callout.weight(.semibold))
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(4).textSelection(.enabled)
                    Button("重试") { Task { await loadRules() } }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rules.isEmpty {
                EmptyHint(text: state.isRunning ? "当前内核没有加载规则\n点击「添加」创建一个" : "当前配置没有规则\n点击「添加」创建一个")
                    .multilineTextAlignment(.center)
            } else if filtered.isEmpty {
                EmptyHint(text: "没有匹配的规则")
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if state.isRunning && state.currentMode != .rule {
                            Text("当前为\(state.currentMode.title)模式；切换到规则模式后，以下规则才参与匹配。")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        }
                        // 规则按顺序匹配：放在同一个分组里紧凑排列，并显示原始匹配序号
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { offset, item in
                                let index = item.index
                                let rule = item.rule
                                Button { open(rule, at: index) } label: {
                                    RuleRow(rule: rule, ordinal: index + 1, digits: String(rules.count).count,
                                            divider: offset < filtered.count - 1)
                                }
                                .buttonStyle(PressableStyle())
                                .contextMenu {
                                    Button("编辑规则") { open(rule, at: index) }
                                    Button("复制匹配内容") { copy(rule.payload) }.disabled(rule.payload.isEmpty)
                                    Button("复制目标策略") { copy(rule.proxy) }
                                    Divider()
                                    Button("删除规则…", role: .destructive) { confirmDelete(rule, at: index) }
                                        .disabled(!canEditRules)
                                }
                                .accessibilityAction(named: "编辑规则") {
                                    open(rule, at: index)
                                }
                                .accessibilityAction(named: "删除规则") {
                                    if canEditRules { confirmDelete(rule, at: index) }
                                }
                            }
                        }
                        .card(cornerRadius: Theme.Radius.section)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
                    }
                    .padding(14)
                }
            }
        }
    }

    private func copy(_ text: String) {
        state.copy(text)
    }

    private func open(_ rule: RuleItem, at index: Int) {
        let target = state.ruleTarget(rule, at: index)
        guard let original = state.ruleText(target) else {
            state.errorMessage = "未在当前配置文件中找到该规则（可能来自规则集或文件已在外部修改），请刷新后重试"
            return
        }
        route = .edit(.init(target: target, original: original))
    }

    private func loadRules() async {
        let id = UUID()
        requestID = id
        guard state.selectedProfile != nil else {
            rules = []
            error = nil
            loading = false
            return
        }
        if !state.isRunning {
            rules = state.yamlRuleItems()
            error = nil
            loading = false
            return
        }
        // 刷新时保留旧列表，避免闪回加载状态
        error = nil
        loading = true
        defer { if requestID == id { loading = false } }
        guard let api = state.api else {
            error = "内核控制接口尚未就绪，请稍后重试。"
            return
        }
        do {
            let loaded = try await api.rules()
            guard requestID == id, !Task.isCancelled, state.isRunning, state.api === api else { return }
            rules = loaded
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// 规则行：序号 + 匹配内容在上，类型与目标策略在下；类型放在第二行，长短不一也不会错开匹配内容
private struct RuleRow: View {
    var rule: RuleItem
    var ordinal: Int
    var digits: Int
    var divider: Bool

    private var typeText: String { ConfigOverlay.yamlRuleType(rule.type) }

    private var payloadText: String {
        // 内核把 GeoIP 国家代码转成小写，按惯例显示为大写
        if !rule.payload.isEmpty { return typeText == "GEOIP" ? rule.payload.uppercased() : rule.payload }
        return typeText == "MATCH" ? "Default" : "—"
    }

    /// 序号列按总条数的位数定宽，保证各行内容对齐
    private var ordinalWidth: CGFloat { CGFloat(max(digits, 2)) * 7 + 2 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(ordinal)")
                .font(Theme.numeral(10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: ordinalWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(payloadText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.payload)
                HStack(spacing: 8) {
                    Text(typeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.ruleTypeTint(typeText))
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text(rule.proxy)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.policyTint(rule.proxy))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.proxy)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0)
        .overlay(alignment: .bottom) {
            if divider { Divider().padding(.leading, ordinalWidth + 14) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(ordinal) 条，\(typeText) \(payloadText)，\(rule.proxy)")
    }
}
