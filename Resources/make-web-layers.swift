// Renders the icon's SVG layers to PNG for the website. Usage: swift make-web-layers.swift <icon-assets> <output>
// PNGs look the same everywhere, including on GPUs that draw curved SVG paths incorrectly.
import AppKit

let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let size = 720

for name in ["aura", "ring", "letter", "spark"] {
    guard let image = NSImage(contentsOf: assets.appendingPathComponent("\(name).svg")) else { fatalError("Can't read \(name).svg") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
}
