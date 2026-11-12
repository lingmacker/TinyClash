import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @Environment(AppState.self) private var state
    @State private var showAdd = false
    @State private var editing: Profile?
    @State private var importing = false

    var body: some View {
        Group {
            if state.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("还没有配置").font(.title3)
                    Text("添加订阅链接，或导入 mihomo 官方格式的 YAML 配置文件").foregroundStyle(.secondary)
                    HStack {
                        Button("添加订阅") { showAdd = true }.buttonStyle(.borderedProminent)
                        Button("导入文件") { importing = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.profiles) { p in
                        ProfileRow(profile: p, onEdit: { editing = p })
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showAdd = true } label: { Label("添加订阅", systemImage: "plus") }
                Button { importing = true } label: { Label("导入文件", systemImage: "square.and.arrow.down") }
                Button {
                    let p = state.createBlankProfile()
                    NSWorkspace.shared.open(p.fileURL)
                } label: { Label("新建配置", systemImage: "doc.badge.plus") }
                Button { Task { await state.updateAllProfiles() } } label: { Label("更新全部", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .sheet(isPresented: $showAdd) { AddSubscriptionSheet() }
        .sheet(item: $editing) { p in EditProfileSheet(profile: p) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.yaml, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try await state.importLocalProfile(from: url) } catch { state.errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct ProfileRow: View {
    @Environment(AppState.self) private var state
    let profile: Profile
    var onEdit: () -> Void

    var body: some View {
        let selected = state.selectedProfileID == profile.id
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.name).font(.headline)
                    Text(profile.kind == .remote ? "订阅" : "本地")
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                HStack(spacing: 10) {
                    Text("更新于 \(Format.relative(profile.updatedAt))")
                    if profile.kind == .remote && profile.updateInterval > 0 {
                        Text("每 \(profile.updateInterval) 小时自动更新")
                    }
                    if let exp = profile.subscription?.expire {
                        Text("到期 \(exp.formatted(date: .numeric, time: .omitted))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let sub = profile.subscription, sub.total > 0 {
                    HStack {
                        ProgressView(value: Double(min(sub.used, sub.total)), total: Double(sub.total))
                            .frame(maxWidth: 220)
                        Text("\(Format.bytes(sub.used)) / \(Format.bytes(sub.total))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Spacer()
            if state.updatingProfiles.contains(profile.id) {
                ProgressView().controlSize(.small)
            } else if profile.kind == .remote {
                Button { Task { await state.updateProfile(profile.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("更新订阅")
            }
            Button { NSWorkspace.shared.open(profile.fileURL) } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("在编辑器中打开 YAML")
            Menu {
                Button("使用此配置") { Task { await state.selectProfile(profile.id) } }
                Button("编辑信息…", action: onEdit)
                if selected { Button("重新加载（编辑 YAML 后）") { Task { await state.reloadCurrentProfile() } } }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([profile.fileURL]) }
                if let url = profile.url {
                    Button("复制订阅链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                if let home = profile.homepage, let u = URL(string: home) {
                    Button("打开订阅主页") { NSWorkspace.shared.open(u) }
                }
                Divider()
                Button("删除", role: .destructive) { Task { await state.deleteProfile(profile.id) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await state.selectProfile(profile.id) } }
    }
}

private struct AddSubscriptionSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加订阅").font(.title3.bold())
            TextField("订阅链接（返回 mihomo / Clash YAML）", text: $url)
            TextField("名称（可选）", text: $name)
            if let error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 120)
            }
            HStack {
                if loading { ProgressView().controlSize(.small); Text("下载并校验中…").font(.caption) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") {
                    loading = true
                    error = nil
                    Task {
                        do {
                            try await state.addRemoteProfile(url: url, name: name)
                            dismiss()
                        } catch let e {
                            error = e.localizedDescription
                        }
                        loading = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || loading)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 480)
    }
}

private struct EditProfileSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile

    var body: some View {
        Form {
            TextField("名称", text: $profile.name)
            if profile.kind == .remote {
                TextField("订阅链接", text: Binding(get: { profile.url ?? "" }, set: { profile.url = $0 }))
                Stepper("自动更新：\(profile.updateInterval == 0 ? "关闭" : "每 \(profile.updateInterval) 小时")",
                        value: $profile.updateInterval, in: 0...168)
            }
            LabeledContent("文件", value: profile.fileName)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    state.saveProfile(profile)
                    dismiss()
                }
            }
        }
    }
}
