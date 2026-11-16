import SwiftUI

/// 规则编辑页下方的规则集内容：列出 RULE-SET 引用的规则集包含的全部条目
struct RuleSetContentsSection: View {
    @Environment(AppState.self) private var state
    var name: String
    @State private var definition: RuleProviderDefinition?
    @State private var contents: RuleSetContents?
    @State private var error: String?
    @State private var search = ""

    private struct LoadKey: Equatable {
        var name: String
        var profileID: UUID?
        var revision: Int
    }

    private func filteredEntries(_ entries: [String]) -> [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("规则集内容").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let contents, let definition {
                    Text(summary(contents, definition: definition))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(contents.file?.path ?? "内联规则集")
                }
            }
            .padding(.horizontal, 4)
            if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(4).textSelection(.enabled)
                    Button("重试") { Task { await load() } }
                        .font(.caption).buttonStyle(.borderless)
                }
                .padding(.horizontal, 4)
            } else if let contents, let definition {
                entryList(contents, definition: definition)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
        .task(id: LoadKey(name: name, profileID: state.selectedProfileID, revision: state.profileRevision)) { await load() }
    }

    @ViewBuilder
    private func entryList(_ contents: RuleSetContents, definition: RuleProviderDefinition) -> some View {
        let entries = filteredEntries(contents.entries)
        let classical = definition.behavior == "classical"
        if contents.entries.count > 1 {
            TextField("搜索规则集", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索规则集条目")
        }
        if entries.isEmpty {
            Text(search.isEmpty ? "规则集为空" : "没有匹配的规则")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    RuleSetEntryRow(entry: entry, classical: classical, divider: index < entries.count - 1)
                        .contextMenu {
                            Button("复制规则") { state.copy(entry) }
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        }
    }

    private func summary(_ contents: RuleSetContents, definition: RuleProviderDefinition) -> String {
        let count = search.isEmpty ? "\(contents.entries.count) 条"
            : "\(filteredEntries(contents.entries).count) / \(contents.entries.count) 条"
        var parts = [count, definition.behavior]
        if definition.type != "inline" { parts.append(definition.format) }
        if let modified = contents.modified { parts.append("更新于 \(Format.updateAge(modified))") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        error = nil
        let found: RuleProviderDefinition?
        do {
            found = try state.ruleProviderDefinitions().first { $0.name == name }
        } catch {
            self.error = error.localizedDescription
            return
        }
        guard let found else {
            error = "当前配置中未找到规则集「\(name)」"
            return
        }
        // 大型规则集有数万行，放到后台读取
        let result = await Task.detached { Result { try RuleSetContents.load(found) } }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let loaded):
            definition = found
            contents = loaded
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}

private struct RuleSetEntryRow: View {
    var entry: String
    var classical: Bool
    var divider = true

    var body: some View {
        HStack(spacing: 8) {
            if classical, let comma = entry.firstIndex(of: ",") {
                let type = String(entry[..<comma])
                Tag(text: type, tint: Theme.ruleTypeTint(type.uppercased())).fixedSize()
                value(String(entry[entry.index(after: comma)...]))
            } else {
                value(entry)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { if divider { Divider().opacity(0.5) } }
        .contentShape(Rectangle())
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }
}
