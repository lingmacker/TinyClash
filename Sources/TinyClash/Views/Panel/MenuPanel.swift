import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case home, proxies, profiles, rules, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .proxies: return "策略"
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
    /// 表单里下拉列表与整行输入框的统一宽度，同一卡片内左右边缘对齐
    static let fieldWidth: CGFloat = 160
}

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    #if TINYCLASH_PREVIEW
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Group {
            if state.showSpeedInMenuBar && state.isRunning {
                Image(nsImage: MenuBarSpeedImage.image(upload: state.upSpeed, download: state.downSpeed,
                                                      active: state.isProxying))
                    .accessibilityLabel("TinyClash，上传 \(Format.speed(state.upSpeed))，下载 \(Format.speed(state.downSpeed))")
                    .help("上传 \(Format.speed(state.upSpeed)) · 下载 \(Format.speed(state.downSpeed))")
            } else {
                Image(state.isProxying ? "MenuBarIcon" : "MenuBarIconIdle")
                    .accessibilityLabel("TinyClash")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: PanelTab = {
        #if TINYCLASH_PREVIEW
        return PanelTab(rawValue: UserDefaults.standard.string(forKey: "uiTab") ?? "") ?? .home
        #else
        return .home
        #endif
    }()
    /// 访问过的标签页保持挂载，切换标签时不丢失正在编辑的表单和滚动位置
    @State private var visited: Set<PanelTab> = []
    /// 停止内核没有对应的 coreState，用本地标记让按钮在停止过程中也显示转圈
    @State private var stoppingCore = false
    @Namespace private var tabNamespace

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
            ZStack(alignment: .top) {
                ForEach(PanelTab.allCases) { t in
                    if t == tab || visited.contains(t) {
                        tabContent(t)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .opacity(t == tab ? 1 : 0)
                            .scaleEffect(t == tab ? 1 : 0.985, anchor: .top)
                            // 切入用 spring，轻量弹性；reduceMotion 退化为普通淡入
                            .animation(
                                reduceMotion
                                    ? .easeOut(duration: 0.12)
                                    : .spring(response: 0.28, dampingFraction: 0.86),
                                value: tab
                            )
                            // 隐藏的标签页禁用交互，避免其中的 ⎋ / ↩ 快捷键被触发
                            .disabled(t != tab)
                            .allowsHitTesting(t == tab)
                            .accessibilityHidden(t != tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // 确认框显示时禁用下层内容，避免其中的 ⎋ 返回等快捷键抢先响应
        .disabled(state.confirmation != nil)
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast = state.toast {
                    ToastView(text: toast)
                        .padding(.bottom, 14)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // 动画只作用于提示层，不影响面板其他内容
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: state.toast)
        }
        .overlay {
            if let confirmation = state.confirmation {
                ConfirmationOverlay(confirmation: confirmation)
            }
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background(Theme.canvas.ignoresSafeArea())
        .accentColor(Theme.accent)
        .tint(Theme.accent)
        .environment(\.controlActiveState, .key)
        // 窗口打开时 AppKit 会把焦点给第一个输入框并全选文字，这里清掉，避免误输入
        .onAppear {
            clearFocus()
            visited.insert(tab)
            state.activeTab = tab
            state.isPanelOpen = true
            Task { await state.panelDidOpen() }
        }
        .onDisappear {
            state.isPanelOpen = false
        }
        .onChange(of: tab) {
            visited.insert(tab)
            state.activeTab = tab
            clearFocus()
            state.confirmation = nil
        }
        .onChange(of: state.addSubscriptionRequest) {
            if state.addSubscriptionRequest != nil { tab = .profiles }
        }
        .onChange(of: state.openGroupRequest) {
            if state.openGroupRequest != nil { tab = .proxies }
        }
        #if TINYCLASH_PREVIEW
        .task {
            // 截图检查：启动参数 -uiConfirmDemo YES 显示一个示例确认框
            guard UserDefaults.standard.bool(forKey: "uiConfirmDemo") else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            state.confirm("删除这条规则？", message: "RULE-SET,telegram,美国\n会从当前配置的 YAML 中删除。") {}
        }
        .task {
            // 截图检查：启动参数 -uiCycleTabs YES，内核就绪并测速后每 4 秒切换一个标签页
            guard UserDefaults.standard.bool(forKey: "uiCycleTabs") else { return }
            while !Task.isCancelled && (!state.isRunning || state.visibleGroups.isEmpty) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await state.testGroups(state.visibleGroups.map(\.name))
            NSLog("TinyClash uiCycleTabs: start")
            for t in PanelTab.allCases {
                tab = t
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        #endif
    }

    @ViewBuilder private func tabContent(_ t: PanelTab) -> some View {
        switch t {
        case .home: HomeTab()
        case .proxies: ProxiesTab()
        case .profiles: ProfilesTab()
        case .rules: RulesTab()
        case .settings: SettingsTab()
        }
    }

    private func clearFocus() {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.firstResponder is NSText { w.makeFirstResponder(nil) }
        }
    }

    private var header: some View {
        let running = state.isRunning
        let toggling = !state.restarting && (state.coreState == .starting || stoppingCore)
        let coreBusy = toggling || state.restarting || state.quitting
        return HStack(spacing: 10) {
            TinyClashBadge(active: state.isProxying)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("TinyClash").font(.headline)
                    StatusBadge()
                }
                Text(state.selectedProfile?.name ?? "未选择配置")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            HeaderAction(icon: "arrow.clockwise", tint: Theme.accentForeground, busy: state.restarting) {
                Task { await state.restartCore() }
            }
            .disabled(!running || coreBusy)
            .help("重启")
            .accessibilityLabel(state.restarting ? "正在重启" : "重启")

            HeaderAction(icon: running ? "stop.fill" : "play.fill", size: running ? 15 : 13,
                         tint: running ? Theme.warningText : Theme.active, busy: toggling) {
                Task {
                    if state.isRunning {
                        stoppingCore = true
                        await state.stopCore()
                        stoppingCore = false
                    } else {
                        await state.startCore()
                    }
                }
            }
            .disabled(coreBusy)
            .help(running ? "停止" : "启动")
            .accessibilityLabel(running ? "停止" : "启动")

            HeaderAction(icon: "power", tint: Theme.failure, pulsing: state.quitting) {
                NSApp.terminate(nil)
            }
            .disabled(state.quitting)
            .keyboardShortcut("q")
            .help("退出 TinyClash（⌘Q）")
            .accessibilityLabel("退出 TinyClash")
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
                    .foregroundStyle(tab == t ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .matchedGeometryEffect(id: t, in: tabNamespace)
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: Theme.Radius.tile, enabled: tab != t)
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("\(t.title)（⌘\(i + 1)）")
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            shape.fill(Theme.selectedSurface)
                .overlay(shape.strokeBorder(Theme.panelBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                .selectionStretch(on: tab, reduceMotion: reduceMotion)
                .matchedGeometryEffect(id: tab, in: tabNamespace, isSource: false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: tab)
    }
}

private struct HeaderAction: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let icon: String
    var size: CGFloat = 13
    let tint: Color
    var busy = false
    var pulsing = false
    let action: () -> Void

    var body: some View {
        let highlighted = enabled && hovering
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(highlighted ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .symbolEffect(.pulse, options: .repeating, isActive: pulsing && !reduceMotion)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .scaleEffect(highlighted && !reduceMotion ? 1.1 : 1)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: 26, height: 26)
            .background(shape.fill(tint.opacity(highlighted ? 0.14 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .opacity(enabled || busy ? 1 : 0.6)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .onChange(of: enabled) { if !enabled { hovering = false } }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .animation(.easeOut(duration: 0.15), value: busy)
        .animation(.easeOut(duration: 0.15), value: enabled)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: icon)
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
                    .accessibilityLabel("关闭错误提示")
                Button {
                    state.copy(message, message: "已复制错误信息")
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.borderless)
                    .help("复制错误信息")
                    .accessibilityLabel("复制错误信息")
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.failure.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

/// 面板底部的短暂成功提示，不抢焦点
private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.active)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            .strokeBorder(Theme.panelBorder, lineWidth: 0.5))
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.14), radius: 10, y: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 子页面标题栏：返回 + 居中标题 + 右侧操作
struct SubpageHeader<Trailing: View>: View {
    var title: String
    var back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        CenteredBarLayout(spacing: Theme.Space.s) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回")
                }
            }
            .buttonStyle(.borderless)
            .toolbarAction(prominent: true)
            .keyboardShortcut(.cancelAction)

            Text(title)
                .font(Theme.toolbarFont.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 0) { trailing }
        }
        // 与各标签页顶部工具栏同一字号
        .font(Theme.toolbarFont)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

extension SubpageHeader where Trailing == EmptyView {
    init(title: String, back: @escaping () -> Void) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

/// 三段式标题栏布局：两侧预留相同空间，长标题截断也不偏离整栏中心
private struct CenteredBarLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let titleNatural = subviews[1].sizeThatFits(.unspecified)

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)

        let sideWidth = max(leading.width, trailing.width)
        let margin = sideWidth > 0 ? sideWidth + spacing : 0
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY),
                          anchor: .center,
                          proposal: ProposedViewSize(width: max(0, bounds.width - 2 * margin), height: titleNatural.height))
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
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous)
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

extension View {
    /// 设置行内下拉列表：统一固定宽度并靠右对齐
    func panelPicker(width: CGFloat = PanelMetrics.fieldWidth) -> some View {
        modifier(PanelPickerModifier(width: width))
    }
}

private struct PanelPickerModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var width: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let picker = content.labelsHidden()
        Group {
            if #available(macOS 26, *) {
                picker.buttonSizing(.flexible).frame(width: width, alignment: .trailing)
            } else {
                picker.frame(width: width, alignment: .trailing)
            }
        }
        // 切换颜色模式时原生弹出按钮会丢掉 tint、退回系统强调色，随外观重建以重新应用
        .id(colorScheme)
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
