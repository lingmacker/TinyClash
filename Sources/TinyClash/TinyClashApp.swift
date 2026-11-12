import AppKit
import SwiftUI

@main
struct TinyClashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(state)
        } label: {
            MenuBarLabel().environment(state)
        }
        .menuBarExtraStyle(.menu)

        Window("TinyClash", id: "main") {
            MainView().environment(state)
        }
        .defaultSize(width: 1000, height: 660)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await AppState.shared.bootstrap()
            if AppState.shared.profiles.isEmpty { WindowOpener.open() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppState.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 再次打开 App（Finder / Dock / open 命令）时显示主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowOpener.open() }
        return true
    }
}

/// 在没有 SwiftUI 环境的地方（AppDelegate）也能打开主窗口
@MainActor
enum WindowOpener {
    static var openAction: OpenWindowAction?

    static func open() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openAction?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
