import AppKit
import Carbon

@main @MainActor enum VoiceHIDChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previous = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            do { try await run(); previous?.activate(options: []); app.terminate(nil) }
            catch { print("FAIL: \(error)"); fflush(stdout); previous?.activate(options: []); exit(1) }
        }
        app.run()
    }

    static func run() async throws {
        let voice = VoiceBridge()
        defer { voice.leave() }
        let previous = NSWorkspace.shared.frontmostApplication
        let activated = try await prepareVoiceFromHID(voice)
        guard activated, NSApp.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            throw NSError(domain: "VoiceHIDChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Activation did not finish while HID was waiting"])
        }
        await Task.detached { voice.leaveFromHID() }.value
        guard !voice.isPrepared,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == previous?.processIdentifier else {
            throw NSError(domain: "VoiceHIDChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Previous app did not regain input"])
        }
        print("PASS: AppKit activation finishes before the real HID callback returns; client closes after handoff")
        fflush(stdout)
    }
}
