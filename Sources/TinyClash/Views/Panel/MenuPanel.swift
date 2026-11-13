import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case home, proxies, profiles, rules, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .proxies: return "代理"
        case .profiles: return "配置"
        case .rules: return "规则"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .home: return "gauge.with.dots.needle.33percent"
        case .proxies: return "globe.asia.australia"
        case .profiles: return "doc.text"
        case .rules: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

enum PanelMetrics {
    static let width: CGFloat = 360
    static let height: CGFloat = 560
}

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    #if TINYCLASH_PREVIEW
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        HStack(spacing: 4) {
            Image(state.isProxying ? "MenuBarIcon" : "MenuBarIconIdle")
            if state.showSpeedInMenuBar && state.isRunning {
                Text("\(Image(systemName: "arrow.down"))\(Format.compactSpeed(state.downSpeed)) \(Image(systemName: "arrow.up"))\(Format.compactSpeed(state.upSpeed))")
                    .monospacedDigit()
            }
        }
        #if TINYCLASH_PREVIEW
        .onAppear {
            if UserDefaults.standard.bool(forKey: "uiPanelPreview") { openWindow(id: "panel-preview") }
        }
        #endif
    }
}

/// 菜单栏面板：TinyClash 的全部界面
struct MenuPanel: View {
    @Environment(AppState.self) private var state
    @State private var tab: PanelTab = {
        #if TINYCLASH_PREVIEW
        return PanelTab(rawValue: UserDefaults.standard.string(forKey: "uiTab") ?? "") ?? .home
        #else
        return .home
        #endif
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            tabBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            if let message = state.errorMessage {
                ErrorBanner(message: message)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            Divider()
            Group {
                switch tab {
                case .home: HomeTab()
                case .proxies: ProxiesTab()
                case .profiles: ProfilesTab()
                case .rules: RulesTab()
                case .settings: SettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        // 窗口打开时 AppKit 会把焦点给第一个输入框并全选文字，这里清掉，避免误输入
        .onAppear(perform: clearFocus)
        .onChange(of: tab) { clearFocus() }
        #if TINYCLASH_PREVIEW
        .task {
            // 截图检查：启动参数 -uiCycleTabs YES，内核就绪并测速后每 4 秒切换一个标签页
            guard UserDefaults.standard.bool(forKey: "uiCycleTabs") else { return }
            while !Task.isCancelled && (!state.isRunning || state.visibleGroups.isEmpty) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { g in
                for group in state.visibleGroups { g.addTask { await state.testGroup(group.name) } }
            }
            NSLog("TinyClash uiCycleTabs: start")
            for t in PanelTab.allCases {
                tab = t
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        #endif
    }

    private func clearFocus() {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.firstResponder is NSText { w.makeFirstResponder(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TinyClashMark()
                .frame(width: 17, height: 17)
                .foregroundStyle(state.isProxying ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(state.isProxying ? AnyShapeStyle(Theme.controlFill) : AnyShapeStyle(Theme.inset))
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("TinyClash").font(.headline)
                    StatusBadge()
                }
                Text(state.selectedProfile?.name ?? "未选择配置")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            // 首页已有大号速度读数，其他页在这里显示
            if state.isRunning && tab != .home {
                VStack(alignment: .trailing, spacing: 1) {
                    Label(Format.speed(state.downSpeed), systemImage: "arrow.down").foregroundStyle(Theme.download)
                    Label(Format.speed(state.upSpeed), systemImage: "arrow.up").foregroundStyle(Theme.upload)
                }
                .font(Theme.numeral(11, weight: .medium))
                .labelStyle(TrailingIconLabelStyle())
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                        Text(t.title).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(tab == t ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(tab == t ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("\(t.title)（⌘\(i + 1)）")
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 8, weight: .bold))
        }
    }
}

/// 面板内的错误提示，替代弹窗
private struct ErrorBanner: View {
    @Environment(AppState.self) private var state
    let message: String
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.failure)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .lineLimit(expanded ? 12 : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { expanded.toggle() }
            VStack(spacing: 6) {
                Button {
                    state.errorMessage = nil
                } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .help("关闭")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.borderless)
                    .help("复制错误信息")
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.failure.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

/// 子页面标题栏：返回 + 标题 + 右侧操作
struct SubpageHeader<Trailing: View>: View {
    var title: String
    var back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("返回")
                }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            Text(title).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            trailing.frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension SubpageHeader where Trailing == EmptyView {
    init(title: String, back: @escaping () -> Void) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

/// 面板内一组设置行的容器
struct PanelSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tile + 2, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.tile + 2, style: .continuous)
                        .strokeBorder(Theme.panelBorder, lineWidth: 0.5)
                )
            if let footer {
                Text(footer).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 设置行：标签在左，控件或数值在右
struct PanelRow<Trailing: View>: View {
    var title: String
    var icon: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                }
                Text(title).font(.callout)
                Spacer(minLength: Theme.Space.s)
                trailing
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            if divider { Divider().padding(.leading, icon == nil ? 12 : 38) }
        }
    }
}

/// 可点击进入子页面的设置行
struct NavRow: View {
    var title: String
    var icon: String?
    var value: String?
    var divider = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRow(title: title, icon: icon, divider: divider) {
                if let value { Text(value).font(.callout).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
