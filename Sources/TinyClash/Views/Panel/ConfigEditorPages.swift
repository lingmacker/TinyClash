import SwiftUI

// MARK: - 添加规则

struct RuleEditorPage: View {
    struct RuleType: Hashable {
        var name: String
        var example: String
        var noResolve = false
    }

    static let types: [RuleType] = [
        .init(name: "DOMAIN-SUFFIX", example: "google.com"),
        .init(name: "DOMAIN", example: "www.google.com"),
        .init(name: "DOMAIN-KEYWORD", example: "google"),
        .init(name: "DOMAIN-WILDCARD", example: "*.google.com"),
        .init(name: "DOMAIN-REGEX", example: "^.*\\.google\\.com$"),
        .init(name: "GEOSITE", example: "google"),
        .init(name: "IP-CIDR", example: "8.8.8.0/24", noResolve: true),
        .init(name: "IP-CIDR6", example: "2001:4860::/32", noResolve: true),
        .init(name: "IP-SUFFIX", example: "8.8.8.8/24", noResolve: true),
        .init(name: "IP-ASN", example: "15169", noResolve: true),
        .init(name: "GEOIP", example: "CN", noResolve: true),
        .init(name: "SRC-IP-CIDR", example: "192.168.1.100/32"),
        .init(name: "SRC-PORT", example: "7777"),
        .init(name: "DST-PORT", example: "443"),
        .init(name: "PROCESS-NAME", example: "Telegram"),
        .init(name: "PROCESS-PATH", example: "/Applications/Telegram.app/Contents/MacOS/Telegram"),
        .init(name: "NETWORK", example: "udp"),
        .init(name: "RULE-SET", example: "rule-providers 中的名称", noResolve: true),
    ]

    /// 编辑已有规则：运行时规则定位 + 配置文件中的原始文本
    struct Editing {
        var target: ConfigOverlay.RuleTarget
        var original: String
    }

    @Environment(AppState.self) private var state
    var editing: Editing?
    var canEdit = true
    var back: () -> Void
    @State private var type: RuleType
    @State private var payload: String
    @State private var policy: String
    @State private var noResolve: Bool
    /// 表单未覆盖的附加参数（如 src），原样保留
    @State private var extras: [String]
    @State private var saving = false
    @State private var error: String?

    init(editing: Editing? = nil, canEdit: Bool = true, back: @escaping () -> Void) {
        self.editing = editing
        self.canEdit = canEdit
        self.back = back
        var type = Self.types[0], payload = "", policy = "DIRECT", noResolve = false, extras: [String] = []
        if let original = editing?.original {
            var fields = ConfigOverlay.splitTopLevelCommas(original).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = fields.removeFirst().uppercased()
            if !Self.isMatch(name), !fields.isEmpty { payload = fields.removeFirst() }
            if !fields.isEmpty { policy = fields.removeFirst() }
            noResolve = fields.contains { $0.lowercased() == "no-resolve" }
            extras = fields.filter { $0.lowercased() != "no-resolve" }
            type = Self.types.first { $0.name == name } ?? RuleType(name: name, example: "", noResolve: noResolve)
        }
        _type = State(initialValue: type)
        _payload = State(initialValue: payload)
        _policy = State(initialValue: policy)
        _noResolve = State(initialValue: noResolve)
        _extras = State(initialValue: extras)
    }

    private static func isMatch(_ name: String) -> Bool { name == "MATCH" || name == "FINAL" }

    /// 编辑时若原规则类型不在常用列表中（如 AND、MATCH），把它加进选项
    private var typeOptions: [RuleType] {
        Self.types.contains(type) ? Self.types : Self.types + [type]
    }

    private var policyOptions: [String] {
        state.policyNames.contains(policy) ? state.policyNames : state.policyNames + [policy]
    }

    private var hasPayload: Bool { !Self.isMatch(type.name) }

    private var rule: String {
        var parts = [type.name]
        if hasPayload { parts.append(payload.trimmingCharacters(in: .whitespaces)) }
        parts.append(policy.trimmingCharacters(in: .whitespaces))
        if type.noResolve && noResolve { parts.append("no-resolve") }
        return (parts + extras).joined(separator: ",")
    }

    private var isValid: Bool {
        (!hasPayload || !payload.trimmingCharacters(in: .whitespaces).isEmpty) &&
            !policy.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: editing == nil ? "添加规则" : "编辑规则", back: back) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        if let editing {
                            Button(role: .destructive) { delete(editing.target) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("从配置中删除规则")
                                .accessibilityLabel("删除规则")
                                .disabled(!canEdit)
                        }
                        Button(editing == nil ? "添加" : "保存") { save() }
                            .buttonStyle(.borderless)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!isValid || !canEdit || rule == editing?.original)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    PanelSection {
                        PanelRow(title: "类型") {
                            Picker("", selection: $type) {
                                ForEach(typeOptions, id: \.self) { Text($0.name).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        if hasPayload {
                            PanelRow(title: "内容") {
                                TextField(type.example, text: $payload).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            }
                        }
                        PanelRow(title: "策略", divider: type.noResolve) {
                            if state.policyNames.count > AppState.builtinPolicies.count {
                                Picker("", selection: $policy) {
                                    ForEach(policyOptions, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden().frame(maxWidth: 170)
                            } else {
                                TextField("DIRECT / 分组名", text: $policy).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            }
                        }
                        if type.noResolve {
                            PanelRow(title: "no-resolve", divider: false) {
                                Toggle("", isOn: $noResolve).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("预览").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(rule).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    }
                    .padding(.horizontal, 4)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Theme.failure).textSelection(.enabled).padding(.horizontal, 4)
                    }
                    ConfigWriteNotice(placement: editing == nil ? "规则插入 rules 最前面，优先匹配。" : "保存后原位替换该规则，匹配顺序不变。")
                }
                .padding(14)
            }
        }
        .disabled(saving)
        .onChange(of: type) { if !type.noResolve { noResolve = false } }
    }

    private func save() {
        let newRule = rule
        saving = true
        error = nil
        Task {
            do {
                if let editing {
                    try await state.updateRule(editing.target, to: newRule)
                } else {
                    try await state.addRule(newRule)
                }
                back()
            } catch let e {
                error = e.localizedDescription
            }
            saving = false
        }
    }

    private func delete(_ target: ConfigOverlay.RuleTarget) {
        saving = true
        error = nil
        Task {
            if await state.deleteRule(target) {
                back()
            } else {
                error = state.errorMessage
                state.errorMessage = nil
            }
            saving = false
        }
    }
}

// MARK: - 添加策略组

struct GroupEditorPage: View {
    static let typeTitles = [
        "select": "手动选择",
        "url-test": "自动选择（延迟最低）",
        "fallback": "故障转移",
        "load-balance": "负载均衡",
    ]

    @Environment(AppState.self) private var state
    /// 编辑模式下为配置文件中的原始定义；名称不可修改，避免规则与其他分组的引用失效
    var original: CustomGroup?
    var canEdit = true
    var onDeleted: () -> Void = {}
    var back: () -> Void
    @State private var group: CustomGroup
    @State private var search = ""
    @State private var saving = false
    @State private var error: String?

    init(original: CustomGroup? = nil, canEdit: Bool = true, onDeleted: @escaping () -> Void = {}, back: @escaping () -> Void) {
        self.original = original
        self.canEdit = canEdit
        self.onDeleted = onDeleted
        self.back = back
        _group = State(initialValue: original ?? CustomGroup())
    }

    private var typeOptions: [String] {
        CustomGroup.types.contains(group.type) ? CustomGroup.types : CustomGroup.types + [group.type]
    }

    private var candidates: [String] {
        let groups = state.groupNames.filter { $0 != "GLOBAL" && $0 != group.name }
        var all = ["DIRECT", "REJECT"] + groups + state.nodeNames
        // 保留配置中已有但当前未加载的成员，便于取消勾选
        all += (original?.proxies ?? []).filter { !all.contains($0) }
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private var validationMessage: String? {
        let name = group.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "请输入分组名称" }
        if original == nil, state.groupNames.contains(name) || AppState.builtinPolicies.contains(name) || state.nodeNames.contains(name) {
            return "名称「\(name)」已被分组或节点使用"
        }
        if group.proxies.isEmpty && !group.includeAll { return "请至少选择一个成员，或开启「包含全部节点」" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: original == nil ? "添加策略组" : "编辑策略组", back: back) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        if let original {
                            Button(role: .destructive) { delete(original.name) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("从配置中删除策略组")
                                .accessibilityLabel("删除策略组")
                                .disabled(!canEdit)
                        }
                        Button(original == nil ? "添加" : "保存") { save() }
                            .buttonStyle(.borderless)
                            .keyboardShortcut(.defaultAction)
                            .disabled(validationMessage != nil || !canEdit || group == original)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    PanelSection {
                        PanelRow(title: "名称") {
                            if original == nil {
                                TextField("例如 我的香港", text: $group.name).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            } else {
                                Text(group.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        PanelRow(title: "类型", divider: group.isAutoTest) {
                            Picker("", selection: $group.type) {
                                ForEach(typeOptions, id: \.self) { Text(Self.typeTitles[$0] ?? $0).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        if group.isAutoTest {
                            PanelRow(title: "测速地址") {
                                TextField(state.delayTestURL, text: $group.url).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            }
                            PanelRow(title: "间隔（秒）", divider: false) {
                                TextField("300", value: $group.interval, format: .number.grouping(.never))
                                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 70)
                            }
                        }
                    }
                    PanelSection(footer: "包含全部节点会引入所有节点（含订阅集合），配合正则筛选可按地区分组。") {
                        PanelRow(title: "包含全部节点") {
                            Toggle("", isOn: $group.includeAll).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        PanelRow(title: "筛选（正则）", divider: false) {
                            TextField("香港|HK", text: $group.filter).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        }
                    }
                    PanelSection(title: "成员（已选 \(group.proxies.count)）") {
                        TextField("搜索", text: $search).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 34)
                        Divider()
                        if state.proxies.isEmpty {
                            Text("内核未运行，无法列出节点").font(.caption).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(candidates, id: \.self) { name in
                            Toggle(isOn: Binding(
                                get: { group.proxies.contains(name) },
                                set: { on in
                                    if on { group.proxies.append(name) } else { group.proxies.removeAll { $0 == name } }
                                }
                            )) {
                                HStack {
                                    Text(name).font(.callout).lineLimit(1)
                                    Spacer()
                                    Text(state.proxies[name]?.type ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                        }
                    }
                    if let msg = error ?? validationMessage {
                        Text(msg).font(.caption).foregroundStyle(error != nil ? Theme.failure : .secondary)
                            .textSelection(.enabled).padding(.horizontal, 4)
                    }
                    ConfigWriteNotice(placement: original == nil ? "策略组追加到 proxy-groups 末尾。" : "保存后原位替换该策略组，未在此显示的字段（如 use、lazy）保持不变。")
                }
                .padding(14)
            }
        }
        .disabled(saving)
    }

    private func save() {
        saving = true
        error = nil
        var g = group
        g.name = g.name.trimmingCharacters(in: .whitespaces)
        if g.isAutoTest && g.url.isEmpty { g.url = state.delayTestURL }
        Task {
            do {
                if let original {
                    try await state.updateGroup(named: original.name, to: g)
                } else {
                    try await state.addGroup(g)
                }
                back()
            } catch let e {
                error = e.localizedDescription
            }
            saving = false
        }
    }

    private func delete(_ name: String) {
        saving = true
        error = nil
        Task {
            if await state.deleteGroup(named: name) {
                onDeleted()
                back()
            } else {
                error = state.errorMessage
                state.errorMessage = nil
            }
            saving = false
        }
    }
}

private struct ConfigWriteNotice: View {
    @Environment(AppState.self) private var state
    let placement: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("直接写入「\(state.selectedProfile?.name ?? "当前配置")」的 YAML 文件。\(placement)保存前用内核校验；内核运行时会重启以应用更改。")
            if state.selectedProfile?.kind == .remote {
                Text("订阅更新会覆盖本地修改。").foregroundStyle(Theme.warning)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
}
