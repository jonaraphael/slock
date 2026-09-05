import AppKit

// Render the same vector artwork used in the README at every macOS icon size.
// This keeps the bundle icon in sync without a separate bitmap asset to update.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate-app-icon artwork.svg output.iconset\n", stderr)
    exit(1)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let image = NSImage(contentsOf: source) else {
    fputs("Cannot load app icon artwork: \(source.path)\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "AppIcon", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot create a \(pixels)-pixel icon bitmap."
                ])
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            // Leave breathing room around the rounded tile in Finder and the Dock.
            let inset = CGFloat(pixels) * 0.08
            image.draw(in: canvas.insetBy(dx: inset, dy: inset), from: .zero,
                       operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "AppIcon", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot encode a \(pixels)-pixel icon."
                ])
            }
            let suffix = scale == 2 ? "@2x" : ""
            try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
} catch {
    fputs("App icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
