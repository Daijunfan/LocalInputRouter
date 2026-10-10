import AppKit

let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let backdrop = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 205, yRadius: 205)
let shadow = NSShadow(); shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.14); shadow.set()
NSColor(calibratedRed: 0.93, green: 0.43, blue: 0.20, alpha: 1).setFill(); backdrop.fill()
NSShadow().set()
let pointer = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "输入路由指针")!
    .withSymbolConfiguration(.init(pointSize: 620, weight: .semibold))!
    .withSymbolConfiguration(.init(paletteColors: [NSColor(calibratedRed: 1, green: 0.98, blue: 0.94, alpha: 1)]))!
let scale = min(520 / pointer.size.width, 620 / pointer.size.height)
let size = NSSize(width: pointer.size.width * scale, height: pointer.size.height * scale)
pointer.draw(in: NSRect(x: (1024-size.width)/2, y: (1024-size.height)/2, width: size.width, height: size.height),
           from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
