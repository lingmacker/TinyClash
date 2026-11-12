import SwiftUI

struct GroupEditorSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var group: CustomGroup
    @State private var search = ""
    @State private var saving = false
    @State private var error: String?

    private let isNew: Bool

    init(group: CustomGroup? = nil) {
        _group = State(initialValue: group ?? CustomGroup())
        isNew = group == nil
    }

    private static let typeTitles = [
        "select": "手动选择（select）",
        "url-test": "自动选择延迟最低（url-test）",
        "fallback": "故障转移（fallback）",
        "load-balance": "负载均衡（load-balance）",
    ]

    /// 可加入分组的成员：内置策略、其他分组、节点
    private var candidates: [String] {
        let groups = state.groupNames.filter { $0 != "GLOBAL" && $0 != group.name }
        let all = ["DIRECT", "REJECT"] + groups + state.nodeNames
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private var validationMessage: String? {
        let name = group.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "请输入分组名称" }
        let taken = state.groupNames.contains(name) || AppState.builtinPolicies.contains(name) || state.nodeNames.contains(name)
        let renamedSelf = state.customGroups.first { $0.id == group.id }?.name == name
        if taken && !renamedSelf { return "名称「\(name)」已被分组或节点使用" }
        if group.proxies.isEmpty && !group.includeAll { return "请至少选择一个成员，或开启「包含全部节点」" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $group.name)
                    Picker("类型", selection: $group.type) {
                        ForEach(CustomGroup.types, id: \.self) { Text(Self.typeTitles[$0] ?? $0).tag($0) }
                    }
                    if group.isAutoTest {
                        TextField("测速地址", text: $group.url, prompt: Text(state.delayTestURL))
                        TextField("测速间隔（秒）", value: $group.interval, format: .number.grouping(.never))
                    }
                }
                Section {
                    Toggle("包含全部节点（include-all）", isOn: $group.includeAll)
                    TextField("筛选节点（正则，可选）", text: $group.filter, prompt: Text("例如 香港|HK"))
                } footer: {
                    Text("开启「包含全部节点」后会自动引入所有节点（含订阅集合），配合正则筛选可按地区分组。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("成员（已选 \(group.proxies.count)）") {
                    TextField("搜索", text: $search)
                    if state.proxies.isEmpty {
                        Text("内核未运行，无法列出节点").foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { group.proxies.contains(name) },
                            set: { on in
                                if on { group.proxies.append(name) } else { group.proxies.removeAll { $0 == name } }
                            }
                        )) {
                            HStack {
                                Text(name).lineLimit(1)
                                Spacer()
                                Text(state.proxies[name]?.type ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 90)
                    .padding(.horizontal, 20)
            }
            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text("校验并应用中…").font(.caption)
                } else if let msg = validationMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || validationMessage != nil)
            }
            .padding(20)
        }
        .frame(width: 540, height: 620)
    }

    private func save() {
        saving = true
        error = nil
        var g = group
        g.name = g.name.trimmingCharacters(in: .whitespaces)
        if g.isAutoTest && g.url.isEmpty { g.url = state.delayTestURL }
        Task {
            do {
                try await state.saveCustomGroup(g)
                dismiss()
            } catch let e {
                error = e.localizedDescription
            }
            saving = false
        }
    }
}
