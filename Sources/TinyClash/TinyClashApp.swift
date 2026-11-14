import AppKit
import SwiftUI

@main
struct TinyClashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(state)
        } label: {
            MenuBarLabel().environment(state)
        }
        .menuBarExtraStyle(.window)

        #if TINYCLASH_PREVIEW
        Window("TinyClash 面板预览", id: "panel-preview") {
            MenuPanel().environment(state)
        }
        .windowResizability(.contentSize)
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if TINYCLASH_PREVIEW
        switch UserDefaults.standard.string(forKey: "uiAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
        Task { @MainActor in await AppState.shared.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppState.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach(AppState.shared.handleOpenURL) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
