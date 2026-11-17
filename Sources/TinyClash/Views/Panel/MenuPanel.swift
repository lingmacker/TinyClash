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
    @State private var hoveringQuit = false
    @State private var hoveringCore = false
    /// 停止内核没有对应的 coreState，用本地标记让按钮在停止过程中也显示转圈
    @State private var stoppingCore = false

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
            hoveringQuit = false
            hoveringCore = false
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
        HStack(spacing: 10) {
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
            coreToggleButton
            // 退出是低频操作且有 ⌘Q，平时用低调的灰色图标；悬停时变红、浮出红色底并轻微放大，退出过程中图标脉动表示正在收尾
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hoveringQuit && !state.quitting ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.secondary))
                    .symbolEffect(.pulse, options: .repeating, isActive: state.quitting && !reduceMotion)
                    .scaleEffect(hoveringQuit && !state.quitting && !reduceMotion ? 1.1 : 1)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Theme.failure.opacity(hoveringQuit && !state.quitting ? 0.14 : 0))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(state.quitting)
            .opacity(state.quitting ? 0.6 : 1)
            .onHover { hoveringQuit = $0 }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.6), value: hoveringQuit)
            .animation(.easeOut(duration: 0.15), value: state.quitting)
            .keyboardShortcut("q")
            .help("退出 TinyClash（⌘Q）")
            .accessibilityLabel("退出 TinyClash")
        }
    }

    /// 内核启动 / 停止；启动中、重启中或退出时禁用，避免与进行中的流程交错。
    /// 动效与退出按钮一致：悬停时停止变琥珀色、启动变绿色，浮出同色底并轻微放大；启动、停止或重启过程中显示转圈
    private var coreToggleButton: some View {
        let running = state.isRunning
        let busy = state.coreState == .starting || state.restarting || stoppingCore
        let enabled = !busy && !state.quitting
        let tint = running ? Theme.warningText : Theme.active
        let highlighted = hoveringCore && enabled
        return Button {
            Task {
                if state.isRunning {
                    stoppingCore = true
                    await state.stopCore()
                    stoppingCore = false
                } else {
                    await state.startCore()
                }
            }
        } label: {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                } else {
                    // 实心方块的视觉面积比电源图标小，略放大让两枚图标看起来一样大
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .font(.system(size: running ? 15 : 13, weight: .medium))
                        .foregroundStyle(highlighted ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .scaleEffect(highlighted && !reduceMotion ? 1.1 : 1)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(tint.opacity(highlighted ? 0.14 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        // 转圈本身已表示进行中，不再整体变暗；只有退出时才变暗
        .opacity(state.quitting ? 0.6 : 1)
        .onHover { hoveringCore = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.6), value: hoveringCore)
        .animation(.easeOut(duration: 0.15), value: busy)
        .animation(.easeOut(duration: 0.15), value: state.quitting)
        .help(running ? "停止内核" : "启动内核")
        .accessibilityLabel(running ? "停止内核" : "启动内核")
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                        Text(t.title).font(.caption2.weight(.medium))
                    }
                    // 当前标签用中性凸起面 + 暖橙文字；实心橙只留给「已开启」的开关
                    .foregroundStyle(tab == t ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if tab == t {
                            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                                .fill(Theme.selectedSurface)
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                                    .strokeBorder(Theme.panelBorder, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: Theme.Radius.tile)
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

/// 子页面标题栏：返回 + 标题 + 右侧操作
struct SubpageHeader<Trailing: View>: View {
    var title: String
    var back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回")
                }
            }
            .buttonStyle(.borderless)
            .toolbarAction(prominent: true)
            .keyboardShortcut(.cancelAction)
            Text(title).font(Theme.toolbarFont.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
            trailing.frame(minWidth: 50, alignment: .trailing)
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
    @ViewBuilder
    func panelPicker(width: CGFloat = PanelMetrics.fieldWidth) -> some View {
        let picker = labelsHidden()
        if #available(macOS 26, *) {
            picker.buttonSizing(.flexible).frame(width: width, alignment: .trailing)
        } else {
            picker.frame(width: width, alignment: .trailing)
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
