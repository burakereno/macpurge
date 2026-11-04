#!/usr/bin/env swift
import AppKit

// Run from the repository root after updating Artwork/AppIcon-2048.png.
// Preserve the supplied artwork; only add the transparent macOS icon margins
// and rounded silhouette required by the legacy .icns format.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("Artwork")
let development = CommandLine.arguments.contains("--development")
let iconName = development ? "AppIcon-Dev" : "AppIcon"
let sourceURL = artwork.appendingPathComponent("AppIcon-2048.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Cannot load \(sourceURL.path)")
}
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacPurge-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func render(size: Int, to destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSGraphicsContext.saveGraphicsState()
    context.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    let bounds = NSRect(x: 84 * scale, y: 84 * scale,
                        width: 856 * scale, height: 856 * scale)
    NSBezierPath(roundedRect: bounds, xRadius: 195 * scale, yRadius: 195 * scale).addClip()
    source.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    if development {
        // Draw the build label at each native resolution, keeping it crisp.
        let badge = NSRect(x: 478 * scale, y: 94 * scale, width: 454 * scale, height: 208 * scale)
        NSColor(calibratedRed: 0.96, green: 0.40, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 55 * scale, yRadius: 55 * scale).fill()
        let label = "DEV" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 145 * scale, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: badge.midX - textSize.width / 2,
                               y: badge.midY - textSize.height / 2), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon PNG")
    }
    try data.write(to: destination)
}

for points in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 2 ? "@2x" : ""
        try render(size: points * density,
                   to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(size: 2048, to: artwork.appendingPathComponent("\(iconName)-Dock-2048.png"))
try render(size: 256, to: artwork.appendingPathComponent("\(iconName)-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", artwork.appendingPathComponent("\(iconName).icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created \(iconName).icns (16–1024 px) and native macOS previews.")
