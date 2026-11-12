import SwiftUI

struct RulesView: View {
    @Environment(AppState.self) private var state
    @State private var rules: [RuleItem] = []
    @State private var search = ""
    @State private var tab = Tab.all
    @State private var adding = false

    enum Tab { case all, custom }

    var body: some View {
        Group {
            switch tab {
            case .all: allRules
            case .custom: CustomRulesList()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索规则")
        .toolbar {
            ToolbarItem {
                Picker("", selection: $tab) {
                    Text("全部规则").tag(Tab.all)
                    Text("自定义规则（\(state.customRules.count)）").tag(Tab.custom)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { adding = true } label: { Label("添加规则", systemImage: "plus") }
                    .disabled(state.selectedProfile == nil)
            }
            ToolbarItem {
                Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $adding) { RuleEditorSheet() }
        .task(id: state.coreState) { await load() }
    }

    private var allRules: some View {
        let filtered = search.isEmpty ? rules : rules.filter {
            $0.payload.localizedCaseInsensitiveContains(search) || $0.proxy.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
        }
        // 自定义规则被插入在最前面
        let customCount = state.customRules.count
        return Table(filtered) {
            TableColumn("#") { r in Text("\((r.index ?? 0) + 1)").foregroundStyle(.secondary).monospacedDigit() }
                .width(50)
            TableColumn("类型") { r in
                HStack(spacing: 4) {
                    Text(r.type)
                    if (r.index ?? .max) < customCount {
                        Text("自定义").font(.caption2).padding(.horizontal, 4).background(.tint.opacity(0.2), in: Capsule())
                    }
                }
            }
            .width(min: 80, ideal: 150)
            TableColumn("内容") { Text($0.payload).textSelection(.enabled) }.width(min: 200, ideal: 340)
            TableColumn("策略") { Text($0.proxy) }.width(min: 80, ideal: 160)
        }
    }

    private func load() async {
        rules = (try? await state.api?.rules()) ?? []
    }
}

/// 自定义规则：可拖动排序、删除，越靠上优先级越高
private struct CustomRulesList: View {
    @Environment(AppState.self) private var state
    @State private var applying = false

    var body: some View {
        let rules = state.customRules
        if rules.isEmpty {
            EmptyHint(text: "还没有自定义规则。自定义规则会插入到当前配置的 rules 最前面，优先级最高。")
        } else {
            List {
                Section {
                    ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                        HStack {
                            Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 28, alignment: .trailing)
                            Text(rule).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button(role: .destructive) {
                                var r = rules
                                r.remove(at: i)
                                apply(r)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .onMove { from, to in
                        var r = rules
                        r.move(fromOffsets: from, toOffset: to)
                        apply(r)
                    }
                } footer: {
                    HStack {
                        if applying { ProgressView().controlSize(.small) }
                        Text("仅作用于配置「\(state.selectedProfile?.name ?? "")」。拖动调整顺序，修改后内核会自动重启。")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(applying)
        }
    }

    private func apply(_ rules: [String]) {
        applying = true
        Task {
            do { try await state.setCustomRules(rules) } catch { state.errorMessage = error.localizedDescription }
            applying = false
        }
    }
}

struct RuleEditorSheet: View {
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
        .init(name: "RULE-SET", example: "规则集合名称（rule-providers 中的 key）", noResolve: true),
    ]

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var type = types[0]
    @State private var payload = ""
    @State private var policy = "DIRECT"
    @State private var noResolve = false
    @State private var saving = false
    @State private var error: String?

    private var rule: String {
        var parts = [type.name, payload.trimmingCharacters(in: .whitespaces), policy.trimmingCharacters(in: .whitespaces)]
        if type.noResolve && noResolve { parts.append("no-resolve") }
        return parts.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("类型", selection: $type) {
                    ForEach(Self.types, id: \.self) { Text($0.name).tag($0) }
                }
                TextField("内容", text: $payload, prompt: Text(type.example))
                if state.policyNames.count > Self.builtinCount {
                    Picker("策略", selection: $policy) {
                        ForEach(state.policyNames, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("策略", text: $policy, prompt: Text("DIRECT / REJECT / 分组名"))
                }
                if type.noResolve {
                    Toggle("no-resolve（不为匹配而解析域名）", isOn: $noResolve)
                }
                LabeledContent("预览") {
                    Text(rule).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            if let error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 90)
                    .padding(.horizontal, 20)
            }
            HStack {
                if saving { ProgressView().controlSize(.small); Text("校验并应用中…").font(.caption) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || payload.trimmingCharacters(in: .whitespaces).isEmpty || policy.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onChange(of: type) { if !type.noResolve { noResolve = false } }
    }

    private static let builtinCount = AppState.builtinPolicies.count

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await state.addCustomRule(rule)
                dismiss()
            } catch let e {
                error = e.localizedDescription
            }
            saving = false
        }
    }
}
