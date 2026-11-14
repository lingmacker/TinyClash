import SwiftUI

struct RuleProvidersPage: View {
    @Environment(AppState.self) private var state
    var back: () -> Void
    @State private var route = Route.list
    @State private var definitions: [RuleProviderDefinition] = []
    @State private var providers: [String: ProviderItem] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var runtimeError: String?
    @State private var requestID = UUID()

    private enum Route { case list, add, edit(RuleProviderDefinition) }

    private struct LoadKey: Equatable {
        var profileID: UUID?
        var revision: Int
        var running: Bool
        var port: Int?
        var needsRestart: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(profileID: state.selectedProfileID, revision: state.profileRevision,
                running: state.isRunning, port: state.api?.port, needsRestart: state.needsCoreRestart)
    }

    private var canUpdate: Bool {
        state.canEditSelectedProfile && state.isRunning && !state.needsCoreRestart && !loading
    }

    var body: some View {
        Group {
            switch route {
            case .list:
                providerList.task(id: loadKey) { await load() }
            case .add:
                if let id = state.selectedProfileID {
                    RuleProviderEditorPage(profileID: id) { route = .list }
                }
            case .edit(let provider):
                if let id = state.selectedProfileID {
                    RuleProviderEditorPage(original: provider, profileID: id) { route = .list }
                }
            }
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: "规则集", back: back) {
                Button { route = .add } label: { Label("添加", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(!state.canEditSelectedProfile)
            }
            HStack(spacing: 10) {
                Text("\(definitions.count) 个规则集").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新规则集")
                    .help("重新读取配置与规则集状态，不下载远程内容")
                    .disabled(loading || state.busy || state.isEditingSelectedProfile)
                Button { update() } label: {
                    if !state.updatingRuleProviders.isEmpty {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("更新全部", systemImage: "arrow.down.circle")
                    }
                }
                .help("下载已加载的 HTTP 规则集，不改写 YAML 或重启内核")
                .disabled(!canUpdate || !providers.values.contains(where: \.isRemoteRuleProvider))
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            if state.selectedProfile == nil {
                EmptyHint(text: "请先在「配置」页添加并选择配置")
            } else if loading && definitions.isEmpty {
                ProgressView("读取规则集中…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 10) {
                    Text("读取规则集失败").font(.callout.weight(.semibold))
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                    Button("重试") { Task { await load() } }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        statusNotice
                        if definitions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("当前配置没有规则集").font(.callout.weight(.semibold))
                                Text("添加远程、本地或内联规则集，再通过 RULE-SET 规则指定目标策略。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("添加规则集") { route = .add }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!state.canEditSelectedProfile)
                                    .padding(.top, 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Space.m)
                        }
                        ForEach(definitions) { definition in
                            providerRow(definition)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    @ViewBuilder private var statusNotice: some View {
        if state.needsCoreRestart {
            notice("配置已修改；重启内核后显示条目数并可更新远程内容。", color: Theme.warning)
        } else if !state.isRunning {
            notice("内核未运行；仍可管理配置，启动后可更新远程内容。")
        }
        if let runtimeError {
            VStack(alignment: .leading, spacing: 4) {
                notice("读取运行状态失败：\(runtimeError)", color: Theme.failure)
                Button("重试读取状态") { Task { await load() } }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
    }

    private func notice(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func providerRow(_ definition: RuleProviderDefinition) -> some View {
        let runtime = providers[definition.name]
        return Button { route = .edit(definition) } label: {
            RuleProviderCard(definition: definition, runtime: runtime)
                .hoverHighlight(cornerRadius: Theme.Radius.tile)
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("编辑规则集") { route = .edit(definition) }
            Button("更新规则集") { update(definition.name) }
                .disabled(!canUpdate || runtime?.isRemoteRuleProvider != true)
            if !definition.url.isEmpty {
                Button("复制链接") {
                    Pasteboard.copy(definition.url)
                }
            }
        }
    }

    private func update(_ name: String? = nil) {
        Task {
            await state.updateRuleProviders(named: name)
            await load()
        }
    }

    private func load() async {
        let id = UUID()
        let key = loadKey
        requestID = id
        loading = true
        error = nil
        runtimeError = nil
        providers = [:]
        defer { if requestID == id { loading = false } }
        guard state.selectedProfile != nil else {
            definitions = []
            return
        }
        do {
            definitions = try state.ruleProviderDefinitions()
        } catch {
            definitions = []
            self.error = error.localizedDescription
            return
        }
        guard state.isRunning, !state.needsCoreRestart, let api = state.api else { return }
        do {
            let loaded = try await api.ruleProviders()
            guard requestID == id, loadKey == key, state.api === api, !Task.isCancelled else { return }
            providers = Dictionary(loaded.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            guard requestID == id, loadKey == key, !Task.isCancelled else { return }
            runtimeError = error.localizedDescription
        }
    }
}

struct RuleProviderCard: View {
    var definition: RuleProviderDefinition
    var runtime: ProviderItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(definition.name).font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle).help(definition.name)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Tag(text: RuleProviderEditorPage.typeTitle(definition.type))
                Text("\(definition.behavior) · \(definition.format)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if let count = runtime?.ruleCount {
                    Text("\(count) 条").font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if definition.type == "http", let date = updatedDate {
                TimelineView(.periodic(from: date, by: 60)) { context in
                    Text("上次更新 \(Format.updateAge(date, now: context.date))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }

    private var updatedDate: Date? {
        guard let raw = runtime?.updatedAt else { return nil }
        let date = ISO8601DateFormatter.mihomo.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

struct RuleProviderEditorPage: View {
    @Environment(AppState.self) private var state
    var original: RuleProviderDefinition?
    let profileID: UUID
    var back: () -> Void
    @State private var provider: RuleProviderDefinition
    @State private var payload: String
    @State private var interval: String
    @State private var policy = "DIRECT"
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(original: RuleProviderDefinition? = nil, profileID: UUID, back: @escaping () -> Void) {
        self.original = original
        self.profileID = profileID
        self.back = back
        let provider = original ?? RuleProviderDefinition()
        _provider = State(initialValue: provider)
        _payload = State(initialValue: provider.payload.joined(separator: "\n"))
        _interval = State(initialValue: String(provider.interval))
    }

    static func typeTitle(_ type: String) -> String {
        switch type {
        case "http": return "远程"
        case "file": return "本地"
        case "inline": return "内联"
        default: return type
        }
    }

    private var definition: RuleProviderDefinition {
        var result = provider
        if original == nil { result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        result.url = result.url.trimmingCharacters(in: .whitespacesAndNewlines)
        result.path = result.type == "http" && original?.type != "http"
            ? "" : result.path.trimmingCharacters(in: .whitespacesAndNewlines)
        result.interval = Int(interval) ?? -1
        result.payload = payload.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return result
    }

    private var validationMessage: String? {
        if provider.type == "http", Int(interval) == nil { return "更新间隔须为非负整数（秒）" }
        return definition.validationMessage
    }

    private var policyOptions: [String] {
        let names = state.policyNames
        return names.contains(policy) ? names : names + [policy]
    }

    private var canEdit: Bool {
        state.selectedProfileID == profileID && state.canEditSelectedProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: original == nil ? "添加规则集" : "编辑规则集", back: back) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        if original != nil {
                            Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                                .help("删除规则集").accessibilityLabel("删除规则集")
                                .disabled(!canEdit)
                        }
                        Button(original == nil ? "添加" : "保存", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canEdit || validationMessage != nil || definition == original)
                    }
                    .buttonStyle(.borderless)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    PanelSection {
                        PanelRow(title: "名称") {
                            if original == nil {
                                TextField("例如 reject", text: $provider.name)
                                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                                    .accessibilityLabel("规则集名称")
                            } else {
                                Text(provider.name).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        PanelRow(title: "来源") {
                            Picker("来源", selection: $provider.type) {
                                ForEach(RuleProviderDefinition.types, id: \.self) { Text(Self.typeTitle($0)).tag($0) }
                            }
                            .panelPicker()
                        }
                        PanelRow(title: "匹配类型", divider: provider.type != "inline" || original == nil) {
                            Picker("匹配类型", selection: $provider.behavior) {
                                ForEach(RuleProviderDefinition.behaviors, id: \.self) { Text($0).tag($0) }
                            }
                            .panelPicker()
                        }
                        if provider.type != "inline" {
                            PanelRow(title: "文件格式", divider: original == nil) {
                                Picker("文件格式", selection: $provider.format) {
                                    ForEach(RuleProviderDefinition.formats, id: \.self) { Text($0).tag($0) }
                                }
                                .panelPicker()
                            }
                        }
                        if original == nil {
                            PanelRow(title: "策略", divider: false) {
                                Picker("目标策略", selection: $policy) {
                                    ForEach(policyOptions, id: \.self) { Text($0).tag($0) }
                                }
                                .panelPicker()
                            }
                        }
                    }
                    sourceFields
                    if let message = error ?? validationMessage {
                        Text(message).font(.caption).foregroundStyle(error != nil ? Theme.failure : .secondary)
                            .textSelection(.enabled).padding(.horizontal, 4)
                    }
                    ConfigWriteNotice(placement: original == nil
                                      ? "规则集和对应的 RULE-SET 规则一并保存；规则插入 rules 最前面，优先按所选策略匹配。"
                                      : "规则集名称保持不变，未在表单中显示的字段原样保留。")
                }
                .padding(14)
            }
        }
        .disabled(saving)
        .onChange(of: provider.type) {
            if provider.type == "inline" { provider.format = "yaml" }
        }
        .alert("删除规则集「\(provider.name)」？", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive, action: delete)
        } message: {
            Text("只删除当前 YAML 中的规则集定义，不删除本地文件。若仍被 RULE-SET 引用，需先修改引用规则。")
        }
    }

    @ViewBuilder private var sourceFields: some View {
        if provider.type == "inline" {
            PanelSection(title: "规则内容", footer: "每行一条匹配内容，不带目标策略。classical 类型需包含规则类型，例如 DOMAIN-SUFFIX,example.com。") {
                TextEditor(text: $payload)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                    .padding(8)
                    .accessibilityLabel("内联规则内容，每行一条")
            }
        } else {
            PanelSection(footer: provider.type == "http"
                         ? "更新间隔单位为秒，0 表示不自动更新。"
                         : "相对路径基于内核工作目录；不会复制或改写规则集文件。") {
                if provider.type == "http" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("订阅链接").font(.callout)
                        TextField("https://example.com/rules.yaml", text: $provider.url)
                            .textFieldStyle(.plain).font(.caption)
                            .accessibilityLabel("规则集订阅链接")
                    }
                    .padding(12)
                    Divider().padding(.leading, 12)
                }
                if provider.type == "file" {
                    PanelRow(title: "文件路径", divider: false) {
                        TextField("rules/local.yaml", text: $provider.path)
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .accessibilityLabel("规则集文件路径")
                    }
                }
                if provider.type == "http" {
                    PanelRow(title: "更新间隔（秒）", divider: false) {
                        TextField("86400", text: $interval).textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .accessibilityLabel("规则集更新间隔（秒）")
                    }
                }
            }
        }
    }

    private func save() {
        let definition = definition
        saving = true
        error = nil
        Task {
            do {
                try await state.saveRuleProvider(definition, replacing: original?.name, profileID: profileID,
                                                 policy: original == nil ? policy : nil)
                back()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func delete() {
        guard let original else { return }
        saving = true
        error = nil
        Task {
            do {
                try await state.deleteRuleProvider(named: original.name, profileID: profileID)
                back()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
