import AppKit

/// The product icon, wherever it can be found — always on Apple's icon grid
/// (1024 canvas, 824 rounded-rect body, transparent margins), never the bare
/// square artwork: the Dock draws whatever it is handed verbatim.
///
/// A bundled Charker.app carries AppIcon.icns and AppKit already resolved it.
/// A bare `swift run` from the repo prefers the generated icns (same grid the
/// bundle ships), and only if that is missing masks the raw artwork itself.
/// The #filePath trick only works on the machine that built the binary, which
/// is exactly the dev-build case; nil means callers draw their vector fallback.
enum AppIconImage {
    static let image: NSImage? = {
        if Bundle.main.bundleIdentifier != nil {
            return NSApp.applicationIconImage
        }
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Design
            .deletingLastPathComponent()  // CharkerApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources")
        if let icns = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns")) {
            return icns
        }
        return NSImage(contentsOf: resources.appendingPathComponent("AppIcon.png")).map(masked)
    }()

    /// Fallback grid for raw artwork, mirroring Scripts/make-icon.swift. Plain
    /// rounded corners rather than the true continuous curve — acceptable for a
    /// path that only runs when the generated icns is missing.
    private static func masked(_ artwork: NSImage) -> NSImage {
        let canvas: CGFloat = 1024
        let body: CGFloat = 824
        let radius: CGFloat = 185.4
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        let bodyRect = NSRect(
            x: (canvas - body) / 2, y: (canvas - body) / 2, width: body, height: body
        )
        NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius).addClip()
        artwork.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }
}
