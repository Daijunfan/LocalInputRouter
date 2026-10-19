import AppKit
import SwiftUI

/// Owns both the unchanged router engine and its independent accessory window.
@MainActor enum RouterAgentApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = RouterAgentDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class RouterAgentDelegate: NSObject, NSApplicationDelegate {
    private var router: RouterController?
    private var panel: ToolWindow?
    private var windowObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        ToolDock.install()
        router = RouterController(autoStart: false)
        windowObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.djf.inputrouter.control"), object: nil, queue: .main) { [weak self] note in
                if note.userInfo?["command"] as? String == "show-window" {
                    MainActor.assumeIsolated { self?.showWindow() }
                }
            }
        if !CommandLine.arguments.contains("--background") && !CommandLine.arguments.contains("--toolbox") { showWindow() }
        DispatchQueue.main.async { [weak self] in self?.router?.reconnect() }
    }
    private func showWindow() {
        guard let router else { return }
        if panel == nil {
            panel = ToolWindow(title: "输入路由", size: NSSize(width: 680, height: 800)) {
                ScrollView { RouterView(router: router).frame(maxWidth: .infinity) }
            }
        }
        panel?.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let windowObserver { DistributedNotificationCenter.default().removeObserver(windowObserver) }
        router?.shutdown()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }
}
