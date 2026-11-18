import SwiftUI

struct AllNodesPage: View {
    @Environment(AppState.self) private var state
    var back: () -> Void
    @State private var sections: [NodeSection] = []
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var testingSections: Set<String> = []
    @State private var loading = false
    @State private var error: String?

    private struct LoadKey: Equatable {
        var running: Bool
        var profileID: UUID?
        var port: Int?
        var revision: Int
        var profileIDs: [UUID]
    }

    private var loadKey: LoadKey {
        LoadKey(
            running: state.isRunning,
            profileID: state.selectedProfileID,
            port: state.api?.port,
            revision: state.profileRevision,
            profileIDs: state.profiles.map(\.id)
        )
    }

    private var totalNodeCount: Int {
        sections.reduce(0) { $0 + $1.nodes.count }
    }

    private var filteredSections: [NodeSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(query)
                || section.profileName.localizedCaseInsensitiveContains(query) {
                return section
            }
            let matching = section.nodes.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.type.localizedCaseInsensitiveContains(query)
            }
            guard !matching.isEmpty else { return nil }
            var copy = section
            copy.nodes = matching
            return copy
        }
    }

    private var filteredNodeCount: Int {
        filteredSections.reduce(0) { $0 + $1.nodes.count }
    }

    var body: some View {
        let displayed = filteredSections
        let hasQuery = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            SubpageHeader(title: "节点列表", back: back) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await load() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .toolbarAction()
                    .help("重新读取节点列表")
                    .disabled(state.profiles.isEmpty)
                }
            }
            if totalNodeCount > 10 || hasQuery {
                TextField("搜索节点、协议或来源", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .accessibilityLabel("搜索节点")
            }
            if !sections.isEmpty || error != nil {
                summaryBar(displayed: displayed, hasQuery: hasQuery)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            Divider()
            contentView(displayed: displayed, hasQuery: hasQuery)
        }
        .task(id: loadKey) { await load() }
    }

    @ViewBuilder
    private func summaryBar(displayed: [NodeSection], hasQuery: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hasQuery
                     ? "\(filteredNodeCount) / \(totalNodeCount) 个节点"
                     : "共 \(totalNodeCount) 个节点")
                if sections.count > 1 {
                    Text("· \(displayed.count) 个来源")
                }
                Spacer()
                if !state.isRunning && !sections.isEmpty {
                    Text("内核未运行，启动后可测速")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let error {
                HStack(spacing: 8) {
                    Text("读取运行节点失败：\(error)")
                        .font(.caption2)
                        .foregroundStyle(Theme.failure)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("重试") { Task { await load() } }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func contentView(displayed: [NodeSection], hasQuery: Bool) -> some View {
        if state.coreState == .starting && sections.isEmpty {
            LoadingHint(text: "内核启动中…")
        } else if state.profiles.isEmpty {
            EmptyHint(text: "还没有配置，请先添加订阅或导入配置")
                .multilineTextAlignment(.center)
        } else if loading && sections.isEmpty {
            LoadingHint(text: "读取节点中…")
        } else if sections.isEmpty {
            EmptyHint(text: state.isRunning ? "当前配置中没有节点" : "当前配置中没有可显示的节点\n若使用远程 Provider，请先启动内核")
                .multilineTextAlignment(.center)
        } else if displayed.isEmpty {
            EmptyHint(text: "没有匹配的节点")
                .multilineTextAlignment(.center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(displayed) { section in
                        sectionView(section, forceExpanded: hasQuery)
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: NodeSection, forceExpanded: Bool) -> some View {
        let isExpanded = forceExpanded || !collapsed.contains(section.id)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionHeader(section, isExpanded: isExpanded, forceExpanded: forceExpanded)

            if isExpanded {
                if section.nodes.isEmpty {
                    Text(section.offlineHint ?? "暂无节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s),
                                        GridItem(.flexible(), spacing: Theme.Space.s)],
                              spacing: Theme.Space.s) {
                        ForEach(Array(section.nodes.enumerated()), id: \.offset) { _, node in
                            NodeCell(
                                name: node.name,
                                canTest: section.isLive,
                                showLatency: section.isLive,
                                detail: node.udp == true ? "\(node.type) · UDP" : node.type,
                                delay: section.isLive ? state.delay(of: node.name) : nil,
                                isTesting: section.isLive && state.testingProxies.contains(node.name),
                                onTest: {
                                    guard section.isLive else { return }
                                    Task { await state.testProxy(node.name, provider: section.providerName) }
                                },
                                onCopy: { state.copy(node.name) }
                            )
                            .equatable()
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: NodeSection, isExpanded: Bool, forceExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                guard !forceExpanded else { return }
                if collapsed.contains(section.id) {
                    collapsed.remove(section.id)
                } else {
                    collapsed.insert(section.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(section.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    sourceTag(for: section.source)
                    if state.profiles.count > 1 {
                        if case .provider = section.source {
                            Text(section.profileName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if section.isActiveProfile {
                            Tag(text: "当前", tint: Theme.accent)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)

            if !section.nodes.isEmpty {
                let isTesting = testingSections.contains(section.id)
                let helpText = !section.isActiveProfile
                    ? "需先切换到此配置并启动内核后才可测速"
                    : (section.isLive ? "测试本列表全部节点的延迟" : "启动内核后可测速")
                Button {
                    testSection(section)
                } label: {
                    TestingLabel(testing: isTesting)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .toolbarAction(prominent: true)
                .fixedSize()
                .disabled(!section.isLive || isTesting)
                .help(helpText)
            }

            Text("\(section.nodes.count) 个")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func testSection(_ section: NodeSection) {
        guard section.isLive, !testingSections.contains(section.id) else { return }
        testingSections.insert(section.id)
        let names = section.nodes.map(\.name)
        let provider = section.providerName
        Task {
            defer { testingSections.remove(section.id) }
            await state.testNodes(names, provider: provider)
        }
    }

    @ViewBuilder
    private func sourceTag(for source: NodeSection.Source) -> some View {
        switch source {
        case .provider(_, let vehicleType, _):
            let upper = vehicleType.uppercased()
            let label = upper == "HTTP" ? "Provider · 远程"
                : upper == "FILE" ? "Provider · 本地"
                : upper == "INLINE" ? "Provider · 内联"
                : "Provider · \(vehicleType)"
            let tint: Color = upper == "HTTP" ? .teal : upper == "FILE" ? .indigo : .pink
            Tag(text: label, tint: tint)
        case .profile:
            Tag(text: "配置文件")
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }

        let ordered = ProfileNodes.orderedProfiles(state.profiles, selectedProfileID: state.selectedProfileID)
        let selectedID = state.selectedProfileID
        var result: [NodeSection] = []
        var liveLoadedProfileID: UUID?

        if state.isRunning, let selected = ordered.first(where: { $0.id == selectedID }) {
            do {
                let (providers, proxies) = try await state.reloadProxiesAndProviders()
                guard !Task.isCancelled else { return }
                result.append(contentsOf: ProfileNodes.liveSections(for: selected, providers: providers, proxies: proxies))
                let loadedNames = Set(providers.map(\.name))
                let pending = await Task.detached {
                    ProfileNodes.pendingOfflineProviders(for: selected, loadedProviderNames: loadedNames)
                }.value
                guard !Task.isCancelled else { return }
                result.append(contentsOf: pending)
                liveLoadedProfileID = selected.id
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }

        let remaining = ordered.filter { $0.id != liveLoadedProfileID }
        let offline = await Task.detached {
            remaining.flatMap { profile in
                ProfileNodes.offlineSections(for: profile, isActiveProfile: profile.id == selectedID)
            }
        }.value
        guard !Task.isCancelled else { return }
        result.append(contentsOf: offline)
        sections = result
    }
}
