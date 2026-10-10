import AppKit
import CoreGraphics

/// Own only this process's hide calls, and balance them on every return path.
final class LocalCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var remote = false
    private var hides = 0
    private var activation: NSObjectProtocol?

    init() {
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    var hidden: Bool {
        lock.lock(); defer { lock.unlock() }
        return remote && hides > 0
    }

    func setRouting(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        remote = value
        if value {
            _ = DJFAllowBackgroundCursor()
            hideIfNeeded()
        } else {
            while hides > 0 {
                _ = CGDisplayShowCursor(CGMainDisplayID())
                hides -= 1
            }
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            // NSTextView can hide the cursor until motion after a key event.
            // Clear that temporary Cocoa state after closing the speech panel.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let local = !self.remote; self.lock.unlock()
                if local { NSCursor.setHiddenUntilMouseMoves(false) }
            }
        }
    }

    func refresh() {
        lock.lock(); defer { lock.unlock() }
        if remote { hideIfNeeded() }
    }

    private func hideIfNeeded() {
        if hides == 0 || DJFCursorIsVisible() != 0 {
            if CGDisplayHideCursor(CGMainDisplayID()) == .success { hides += 1 }
        }
        _ = CGAssociateMouseAndMouseCursorPosition(0)
    }

    deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        setRouting(false)
    }
}
