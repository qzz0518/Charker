// Turns one square artwork PNG into a macOS app icon.
//
// macOS icons are not bare squares: the artwork sits on Apple's rounded-rect
// grid — a 1024 pt canvas with an 824 pt body, continuous ("squircle") corners
// of radius 185.4, and transparent margins. SwiftUI's
// RoundedRectangle(style: .continuous) is that exact curve, so the mask is
// rendered rather than approximated.
//
//   swift Scripts/make-icon.swift artwork.png Resources/AppIcon.icns
//
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <artwork.png> <out.icns>\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let artwork = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
    exit(1)
}

/// Apple's macOS icon grid, in points on a 1024 canvas.
enum Grid {
    static let canvas: CGFloat = 1024
    static let body: CGFloat = 824
    static let radius: CGFloat = 185.4
}

struct IconCanvas: View {
    let artwork: NSImage

    var body: some View {
        ZStack {
            Color.clear
            Image(nsImage: artwork)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: Grid.body, height: Grid.body)
                .clipShape(RoundedRectangle(cornerRadius: Grid.radius, style: .continuous))
                // The shelf shadow in Apple's own template: soft, close, and far
                // weaker than a UI drop shadow.
                .shadow(color: .black.opacity(0.28), radius: 12, y: 10)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
        .frame(width: Grid.canvas, height: Grid.canvas)
    }
}

@MainActor
func renderCanvas() -> CGImage? {
    let renderer = ImageRenderer(content: IconCanvas(artwork: artwork))
    renderer.scale = 1
    renderer.isOpaque = false
    return renderer.cgImage
}

func write(_ image: CGImage, side: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(
        image, in: CGRect(x: 0, y: 0, width: side, height: side)
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let rendered = MainActor.assumeIsolated { renderCanvas() }
guard let rendered else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}

let iconset = outputURL.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The set macOS actually asks for. 16 and 32 carry the menu-bar-adjacent sizes,
// so they matter more than their pixel count suggests.
let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    try write(rendered, side: variant.side, to: iconset.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)

let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
print("wrote \(outputURL.path) (\(size) bytes)")
