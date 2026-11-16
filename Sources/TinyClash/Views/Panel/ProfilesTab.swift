import SwiftUI

struct ProfilesTab: View {
    @Environment(AppState.self) private var state
    @State private var adding = false
    @State private var editing: Profile?

    var body: some View {
        Group {
            if let p = editing {
                EditProfilePage(profile: p) { editing = nil }
            } else if adding {
                AddSubscriptionPage(initialURL: state.addSubscriptionRequest ?? "") {
                    adding = false
                    state.addSubscriptionRequest = nil
                }
            } else {
                list
            }
        }
        .onAppear(perform: takeAddRequest)
        .onChange(of: state.addSubscriptionRequest) { takeAddRequest() }
    }

    private func takeAddRequest() {
        guard state.addSubscriptionRequest != nil else { return }
        editing = nil
        adding = true
    }

    private var hasSubscriptions: Bool { state.profiles.contains { $0.kind == .remote } }

    private var list: some View {
        VStack(spacing: 0) {
            // 与「策略」「规则」一致：操作放在顶部工具栏
            HStack(spacing: 10) {
                Text("\(state.profiles.count) 个配置").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { Task { await state.updateAllProfiles() } } label: {
                    Label("全部更新", systemImage: "arrow.clockwise")
                }
                .toolbarAction()
                .disabled(!hasSubscriptions)
                .help("更新全部订阅；本地修改过的订阅不会被覆盖，需在卡片上单独更新")
                Menu {
                    Button("导入 YAML 文件…") { Task { await state.importProfileFromFile() } }
                    Button("新建空白配置") {
                        if let p = state.createBlankProfile() { NSWorkspace.shared.open(p.fileURL) }
                    }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                // borderless 按钮样式下菜单标签会被 AppKit 按系统字号重绘；plain 样式才沿用
                // 这里的 caption 字号，与旁边的工具栏按钮一样大
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .toolbarAction(prominent: true)
                .help("导入本地 YAML 或新建空白配置")
                Button { adding = true } label: {
                    Label("添加订阅", systemImage: "plus")
                }
                .toolbarAction(prominent: true)
            }
            .font(Theme.toolbarFont)
            .buttonStyle(.borderless)
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    if state.profiles.isEmpty {
                        Text("还没有配置。添加订阅链接，或导入 mihomo 官方格式的 YAML 文件。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.vertical, 40)
                    }
                    ForEach(state.profiles) { p in
                        ProfileCard(profile: p, onEdit: { editing = p })
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct ProfileCard: View {
    @Environment(AppState.self) private var state
    let profile: Profile
    var onEdit: () -> Void

    private var locallyModified: Bool { state.isLocallyModified(profile.id) }

    var body: some View {
        let selected = state.selectedProfileID == profile.id
        HStack(alignment: .top, spacing: 8) {
            Button {
                guard !selected else { return }
                Task { await state.selectProfile(profile.id) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        Text(profile.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Tag(text: profile.kind == .remote ? "订阅" : "本地")
                        if locallyModified {
                            Tag(text: "本地已修改", tint: Theme.warningText, icon: "pencil")
                                .help("此订阅在本地改过，已暂停自动更新；手动更新会覆盖修改（覆盖前自动备份）")
                        }
                    }
                    HStack(spacing: Theme.Space.s) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("更新于 \(Format.updateAge(profile.updatedAt, now: context.date))")
                        }
                        if let exp = profile.subscription?.expire {
                            let soon = exp.timeIntervalSinceNow < 7 * 86400
                            HStack(spacing: 3) {
                                if soon { Image(systemName: "exclamationmark.circle.fill") }
                                Text("到期 \(exp.formatted(date: .numeric, time: .omitted))")
                            }
                            .foregroundStyle(soon ? Theme.warningText : .secondary)
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 22)
                    if let sub = profile.subscription, sub.total > 0 {
                        usageBar(sub).padding(.leading, 22)
                    }
                    if let message = state.profileUpdateErrors[profile.id] {
                        Label("自动更新失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(Theme.failure).lineLimit(2)
                            .padding(.leading, 22)
                            .help(message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(selected ? "当前使用的配置" : "点击切换到此配置")
            HStack(spacing: 8) {
                if state.updatingProfiles.contains(profile.id) || state.updatingProfileNodes.contains(profile.id) {
                    ProgressView().controlSize(.mini)
                } else if profile.kind == .remote {
                    Button {
                        if locallyModified { confirmOverwrite() } else { Task { await state.updateProfile(profile.id) } }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("更新订阅").accessibilityLabel("更新订阅")
                }
                menu
            }
        }
        .panel(padding: 12)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        )
        .hoverHighlight()
    }

    private var menu: some View {
        Menu {
            Button("在编辑器中打开 YAML") { NSWorkspace.shared.open(profile.fileURL) }
            if state.selectedProfileID == profile.id {
                Button("重新加载（编辑 YAML 后）") { Task { await state.reloadCurrentProfile() } }
            }
            Button(nodeUpdateTitle) {
                Task { await state.updateProfileNodes(profile.id) }
            }
            .disabled(!state.canUpdateProfileNodes(profile.id))
            Button("编辑信息…", action: onEdit)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([profile.fileURL]) }
            if let url = profile.url {
                Button("复制订阅链接") { state.copy(url, message: "已复制订阅链接") }
            }
            if let home = profile.homepage, let u = URL(string: home) {
                Button("打开订阅主页") { NSWorkspace.shared.open(u) }
            }
            Divider()
            Button("删除…", role: .destructive, action: confirmDelete)
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
            .accessibilityLabel("「\(profile.name)」的更多操作")
    }

    /// 不可用的原因直接写在菜单项标题里，不再额外放一条不能点的说明
    private var nodeUpdateTitle: String {
        if state.updatingProfileNodes.contains(profile.id) { return "正在更新订阅节点…" }
        if state.selectedProfileID != profile.id { return "更新订阅节点（需先切换到此配置）" }
        if !state.isRunning { return "更新订阅节点（需先启动内核）" }
        return "更新订阅节点"
    }

    private func confirmDelete() {
        let id = profile.id
        state.confirm("删除配置「\(profile.name)」？",
                      message: state.selectedProfileID == id
                          ? "会删除配置文件，并切换到其他配置重启内核。删除前会在 backups 目录保留一份备份。"
                          : "会删除配置文件。删除前会在 backups 目录保留一份备份。") {
            Task { await state.deleteProfile(id) }
        }
    }

    private func confirmOverwrite() {
        let id = profile.id
        state.confirm("覆盖本地修改？",
                      message: "「\(profile.name)」在本地改过，更新订阅会用下载内容覆盖这些修改。覆盖前会在 backups 目录保留一份备份。",
                      confirmTitle: "更新并覆盖") {
            Task { await state.updateProfile(id) }
        }
    }

    private func usageBar(_ sub: SubscriptionInfo) -> some View {
        let ratio = min(Double(sub.used) / Double(sub.total), 1)
        let tint = ratio > 0.9 ? Theme.failure : ratio > 0.75 ? Theme.warning : Color.accentColor
        return HStack(spacing: Theme.Space.s) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.inset)
                    Capsule().fill(tint).frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 4)
            Text("\(Format.bytes(sub.used)) / \(Format.bytes(sub.total))")
                .font(Theme.numeral(10, weight: .regular)).foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct AddSubscriptionPage: View {
    @Environment(AppState.self) private var state
    var back: () -> Void
    @State private var url: String

    init(initialURL: String, back: @escaping () -> Void) {
        _url = State(initialValue: initialURL)
        self.back = back
    }
    @State private var name = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: "添加订阅", back: back)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                PanelSection(footer: "订阅需返回 mihomo / Clash 格式的 YAML；添加时会用内核校验。") {
                    PanelRow(title: "订阅链接") {
                        TextField("https://", text: $url).panelField().frame(width: PanelMetrics.fieldWidth)
                    }
                    PanelRow(title: "名称", divider: false) {
                        TextField("可选", text: $name).panelField().frame(width: PanelMetrics.fieldWidth)
                    }
                }
                if let error {
                    ScrollView {
                        Text(error).font(.caption).foregroundStyle(Theme.failure).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                HStack {
                    if loading { ProgressView().controlSize(.small); Text("下载并校验中…").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("添加") {
                        loading = true
                        error = nil
                        Task {
                            do {
                                try await state.addRemoteProfile(url: url, name: name)
                                back()
                            } catch let e {
                                error = e.localizedDescription
                            }
                            loading = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                }
            }
            .padding(14)
            Spacer()
        }
    }
}

private struct EditProfilePage: View {
    @Environment(AppState.self) private var state
    @State var profile: Profile
    var back: () -> Void

    init(profile: Profile, back: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        self.back = back
    }

    var body: some View {
        VStack(spacing: 0) {
            SubpageHeader(title: "编辑配置", back: back) {
                Button("保存") {
                    if state.saveProfile(profile) {
                        back()
                    }
                }
                .buttonStyle(.borderless)
                .toolbarAction(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                PanelSection {
                    PanelRow(title: "名称", divider: profile.kind == .remote) {
                        TextField("名称", text: $profile.name).panelField().frame(width: PanelMetrics.fieldWidth)
                    }
                    if profile.kind == .remote {
                        PanelRow(title: "订阅链接") {
                            TextField("https://", text: Binding(get: { profile.url ?? "" }, set: { profile.url = $0 }))
                                .panelField().frame(width: PanelMetrics.fieldWidth)
                        }
                        PanelRow(title: "自动更新", divider: false) {
                            Stepper(profile.updateInterval == 0 ? "关闭" : "每 \(profile.updateInterval) 小时",
                                    value: $profile.updateInterval, in: 0...168)
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(14)
            Spacer()
        }
    }
}
