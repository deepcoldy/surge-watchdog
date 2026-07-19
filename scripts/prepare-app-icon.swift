import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: prepare-app-icon <input> <output>\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: inputURL) else {
    fputs("Cannot read icon source\n", stderr)
    exit(1)
}

let pixels = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [.alphaFirst],
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Cannot create icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Cannot create icon context\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
NSColor.clear.setFill()
canvas.fill()

// Image generation leaves a narrow presentation margin outside the app tile.
// Crop that margin, then clip to a transparent macOS-style icon silhouette.
let iconBounds = canvas.insetBy(dx: 8, dy: 8)
let mask = NSBezierPath(roundedRect: iconBounds, xRadius: 250, yRadius: 250)
mask.addClip()
let sourceInsetX = source.size.width * 0.045
let sourceInsetY = source.size.height * 0.045
let sourceCrop = NSRect(
    x: sourceInsetX,
    y: sourceInsetY,
    width: source.size.width - sourceInsetX * 2,
    height: source.size.height - sourceInsetY * 2
)
source.draw(
    in: canvas,
    from: sourceCrop,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Cannot encode icon PNG\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
