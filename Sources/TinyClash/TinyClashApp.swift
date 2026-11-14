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
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // kill / launchctl 发来的 SIGTERM 默认直接结束进程，跳过 shutdown，内核和系统代理会残留；
        // 转成正常退出流程。terminate 要等主线程上的 shutdown 任务，不能在主队列回调里直接调用
        // （会互相等待卡死），改为经 run loop 定时器调度。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        source.resume()
        termSource = source
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
