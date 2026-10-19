import SwiftUI
import AppKit

@main
@MainActor
enum Preview {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let router = RouterController(autoStart: false)
        router.shutdown()
        router.accessibility = false
        router.monitoring = false
        router.status = "输入仍在 Mac：系统输入权限尚未生效"
        let renderer = ImageRenderer(content: RouterView(router: router).environment(\.colorScheme, .light).background(Color.white))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 600, height: nil)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "UI preview", code: 1)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
