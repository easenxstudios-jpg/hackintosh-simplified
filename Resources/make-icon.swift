// Draws the app icon into an .iconset folder. Usage: swift make-icon.swift <folder>
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let inset = size * 0.1
    let square = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: square, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.2, blue: 0.5, alpha: 1))!.draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let box = symbol.size
        symbol.draw(in: NSRect(x: (size - box.width) / 2, y: (size - box.height) / 2, width: box.width, height: box.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(pixels).write(to: folder.appendingPathComponent("icon_\(name).png"))
}
