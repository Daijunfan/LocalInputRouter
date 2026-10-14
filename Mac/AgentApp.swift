import AppKit
import SwiftUI

/// Owns the router engine and its standalone window.
@MainActor enum RouterAgentApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = RouterAgentDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class RouterAgentDelegate: NSObject, NSApplicationDelegate {
    private var router: RouterController?
    private var panel: ToolWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        router = RouterController(autoStart: false)
        if !CommandLine.arguments.contains("--background") { showWindow() }
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
    func applicationWillTerminate(_ notification: Notification) { router?.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }
}
