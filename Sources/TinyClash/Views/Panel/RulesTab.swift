import SwiftUI

struct RulesTab: View {
    @Environment(AppState.self) private var state
    @State private var route = Route.list
    @State private var rules: [RuleItem] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    private enum Route { case list, add, edit(RuleEditorPage.Editing) }

    private var canEditRules: Bool {
        guard let id = state.selectedProfileID, state.selectedProfile != nil else { return false }
        return !state.busy && state.coreState != .starting &&
            !state.isEditingSelectedProfile && !state.updatingProfiles.contains(id)
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

    private var filteredRules: [(offset: Int, element: RuleItem)] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.enumerated().filter { entry in
            query.isEmpty || [entry.element.type, entry.element.payload, entry.element.proxy]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        switch route {
        case .list:
            ruleList
                .task(id: loadKey) { await loadRules() }
        case .add:
            RuleEditorPage { route = .list }
        case .edit(let editing):
            RuleEditorPage(editing: editing, canEdit: canEditRules) { route = .list }
        }
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            let showSearch = state.isRunning && !rules.isEmpty
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(search.isEmpty ? "\(rules.count) 条规则" : "\(filteredRules.count) / \(rules.count) 条规则")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("按内核匹配顺序显示；RuleSet 显示集合引用，不展开集合内的条目")
                    Spacer(minLength: 4)
                    Button { Task { await loadRules() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("从内核刷新规则")
                    .accessibilityLabel("刷新规则")
                    .disabled(!state.isRunning || loading)
                    Button { route = .add } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    .disabled(!canEditRules)
                    if state.isEditingSelectedProfile {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, showSearch ? 8 : 14)
                if showSearch {
                    TextField("搜索类型、内容或目标策略", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
            Divider()
            if !state.isRunning {
                EmptyHint(text: state.selectedProfile == nil ? "请先在「配置」页添加并选择配置" : "内核未运行\n启动后可查看规则，仍可添加规则并写入当前配置")
                    .multilineTextAlignment(.center)
            } else if loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("读取规则中…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                EmptyHint(text: "当前内核没有加载规则\n点击「添加规则」创建一个")
                    .multilineTextAlignment(.center)
            } else if filteredRules.isEmpty {
                EmptyHint(text: "没有匹配的规则")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if state.currentMode != .rule {
                            Text("当前为\(state.currentMode.title)模式；切换到规则模式后，以下规则才参与匹配。")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        }
                        ForEach(filteredRules, id: \.offset) { entry in
                            Button { open(entry.element, at: entry.offset) } label: {
                                RuleCard(rule: entry.element)
                                    .hoverHighlight(cornerRadius: Theme.Radius.tile)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu {
                                Button("编辑规则") { open(entry.element, at: entry.offset) }
                                Button("复制匹配内容") { copy(entry.element.payload) }.disabled(entry.element.payload.isEmpty)
                                Button("复制目标策略") { copy(entry.element.proxy) }
                                Divider()
                                Button("删除规则", role: .destructive) {
                                    Task { await state.deleteRule(entry.element, at: entry.offset) }
                                }
                                .disabled(!canEditRules)
                            }
                            .accessibilityAction(named: "编辑规则") {
                                open(entry.element, at: entry.offset)
                            }
                            .accessibilityAction(named: "删除规则") {
                                if canEditRules { Task { await state.deleteRule(entry.element, at: entry.offset) } }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        rules = []
        error = nil
        loading = state.isRunning
        defer { if requestID == id { loading = false } }
        guard state.isRunning else { return }
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

private struct RuleCard: View {
    var rule: RuleItem

    var body: some View {
        HStack(spacing: 8) {
            Tag(text: rule.type)
                .fixedSize()
            Text(rule.payload.isEmpty ? (rule.type.lowercased() == "match" ? "其他所有流量" : "—") : rule.payload)
                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                .help(rule.payload)
            Text(rule.proxy).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                .lineLimit(1).truncationMode(.middle).help(rule.proxy)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(Rectangle())
    }
}
