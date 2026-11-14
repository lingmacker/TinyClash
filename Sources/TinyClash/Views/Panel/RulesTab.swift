import SwiftUI

struct RulesTab: View {
    @Environment(AppState.self) private var state
    @State private var route = Route.list
    @State private var rules: [RuleItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var deleting: (rule: RuleItem, index: Int)?

    private enum Route {
        case list, add, edit(RuleEditorPage.Editing), providers
        var isList: Bool { if case .list = self { return true } else { return false } }
    }

    private var canEditRules: Bool { state.canEditSelectedProfile }

    private struct LoadKey: Equatable {
        var running: Bool
        var profileID: UUID?
        var port: Int?
        var profileRevision: Int
        var needsCoreRestart: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(running: state.isRunning,
                profileID: state.selectedProfileID,
                port: state.api?.port,
                profileRevision: state.profileRevision,
                needsCoreRestart: state.needsCoreRestart)
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
            case .edit(let editing):
                RuleEditorPage(editing: editing, canEdit: canEditRules) { route = .list }.background(Theme.canvas)
            case .providers:
                RuleProvidersPage { route = .list }
                    .id(state.selectedProfileID)
                    .background(Theme.canvas)
            }
        }
        .alert("删除这条规则？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let target = deleting else { return }
                Task { await state.deleteRule(target.rule, at: target.index) }
            }
        } message: {
            Text(deleting.map { "\($0.rule.type),\($0.rule.payload),\($0.rule.proxy)\n会从当前配置的 YAML 中删除。" } ?? "")
        }
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(rules.count) 条规则")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(state.needsCoreRestart
                          ? "配置已修改，当前按配置文件规则顺序显示（重启内核后生效）"
                          : "按内核匹配顺序显示；RuleSet 显示集合引用，不展开集合内的条目")
                Spacer(minLength: 4)
                Button { Task { await loadRules() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(state.needsCoreRestart ? "从配置文件刷新规则（需重启内核后生效）" : "从内核刷新规则")
                .accessibilityLabel("刷新规则")
                .disabled(!state.isRunning || loading)
                Button { route = .providers } label: {
                    Label("规则集", systemImage: "square.stack.3d.up")
                }
                .help("管理当前配置的 rule-providers")
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
            .padding(14)
            Divider()
            if state.coreState == .starting {
                LoadingHint(text: "内核启动中…")
            } else if !state.isRunning {
                EmptyHint(text: state.selectedProfile == nil ? "请先在「配置」页添加并选择配置" : "内核未运行\n启动后可查看规则，仍可添加规则并写入当前配置")
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
                EmptyHint(text: "当前内核没有加载规则\n点击「添加规则」创建一个")
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        if state.currentMode != .rule {
                            Text("当前为\(state.currentMode.title)模式；切换到规则模式后，以下规则才参与匹配。")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        }
                        ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                            Button { open(rule, at: index) } label: {
                                RuleCard(rule: rule)
                                    .hoverHighlight(cornerRadius: Theme.Radius.tile)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu {
                                Button("编辑规则") { open(rule, at: index) }
                                Button("复制匹配内容") { copy(rule.payload) }.disabled(rule.payload.isEmpty)
                                Button("复制目标策略") { copy(rule.proxy) }
                                Divider()
                                Button("删除规则…", role: .destructive) { deleting = (rule, index) }
                                    .disabled(!canEditRules)
                            }
                            .accessibilityAction(named: "编辑规则") {
                                open(rule, at: index)
                            }
                            .accessibilityAction(named: "删除规则") {
                                if canEditRules { deleting = (rule, index) }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func copy(_ text: String) {
        Pasteboard.copy(text)
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
        guard state.isRunning else {
            rules = []
            error = nil
            loading = false
            return
        }
        if state.needsCoreRestart {
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
            guard requestID == id, !Task.isCancelled, state.isRunning, !state.needsCoreRestart, state.api === api else { return }
            rules = loaded
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct RuleCard: View {
    var rule: RuleItem

    private var payloadText: String {
        if !rule.payload.isEmpty { return rule.payload }
        return rule.type.lowercased() == "match" ? "其他所有流量" : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(payloadText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.payload)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Tag(text: rule.type, cornerRadius: 4)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }
}
