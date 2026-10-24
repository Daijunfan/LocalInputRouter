import AppKit

@main enum ConsoleDesktopChecks {
    static func main() {
        let rdp = RemoteDesktopMode.rdp.bundleIdentifier
        let console = RemoteDesktopMode.console.bundleIdentifier
        precondition(RemoteDesktopMode.nativePointer(bundle: rdp, title: "DJF-Windows", destination: .windows))
        precondition(RemoteDesktopMode.nativePointer(bundle: rdp, title: "DJF-Windows", destination: .mac))
        precondition(!RemoteDesktopMode.nativePointer(bundle: rdp, title: "BUPT Windows 11", destination: .windows))
        precondition(RemoteDesktopMode.nativePointer(bundle: console, title: "DJF-Windows", destination: .mac))
        precondition(!RemoteDesktopMode.nativePointer(bundle: console, title: "DJF-Windows", destination: .windows))
        precondition(!RemoteDesktopMode.nativePointer(bundle: console, title: "another host", destination: .mac))
        let control = InputControl()
        control.configure(available: true, pid: 123)
        control.confirm(.windows)
        control.setRDPPointer(RemoteDesktopMode.nativePointer(bundle: console, title: "DJF-Windows", destination: .windows))
        let mouse = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        precondition(control.guardLocal(mouse) == nil, "Routed console input must not activate Mac fullscreen edges")
        control.confirm(.mac)
        precondition(control.guardLocal(mouse) != nil, "Unrouted console input remains local to the viewer")
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            _ = RemoteDesktopMode.focusedViewer()
            finished.signal()
        }
        precondition(finished.wait(timeout: .now() + 0.5) == .success,
                     "The HID focus check must complete while AppKit's main queue is blocked")
        print("PASS: RDP pointer behavior retained; console routing blocks local edges; unrouted viewer input preserved")
        print("PASS: shortcut focus check does not wait for the AppKit main queue")
    }
}
