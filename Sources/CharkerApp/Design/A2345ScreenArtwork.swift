import AppKit

/// A high-resolution, deliberately non-live screen for the A2345 model.
///
/// The official GLB ships a 960×384 transparent dashboard plus a lossy JPEG
/// copy of the same pixels as an emissive layer. That is adequate at the web
/// viewer's normal size, but the duplicate JPEG edge noise becomes obvious
/// when SceneKit lets somebody inspect the product up close. A clock theme is
/// both sharper and more honest than showing fixed power numbers next to live
/// port data: it reads as a screensaver, not as telemetry.
enum A2345ScreenArtwork {
    static let pixelWidth = 1_920
    static let pixelHeight = 768

    static func bubbleClock(at date: Date = Date()) -> NSImage {
        let size = NSSize(width: pixelWidth, height: pixelHeight)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return NSImage(size: size)
        }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let canvas = NSRect(origin: .zero, size: size)
        NSColor(deviceWhite: 0.004, alpha: 1).setFill()
        canvas.fill()

        drawBubble(
            center: NSPoint(x: 120, y: 690),
            radius: 430,
            color: NSColor(srgbRed: 0.02, green: 0.34, blue: 0.58, alpha: 1)
        )
        drawBubble(
            center: NSPoint(x: 1_840, y: 84),
            radius: 390,
            color: NSColor(srgbRed: 0.00, green: 0.55, blue: 0.72, alpha: 1)
        )
        drawBubble(
            center: NSPoint(x: 1_640, y: 720),
            radius: 170,
            color: NSColor(srgbRed: 0.10, green: 0.20, blue: 0.42, alpha: 1)
        )

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMM. d / EEE."

        drawCentered(
            timeFormatter.string(from: date),
            baselineY: 278,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 232, weight: .medium),
                .foregroundColor: NSColor.white,
                .kern: -8,
            ]
        )
        drawCentered(
            dateFormatter.string(from: date),
            baselineY: 210,
            attributes: [
                .font: NSFont.systemFont(ofSize: 54, weight: .medium),
                .foregroundColor: NSColor(deviceWhite: 0.64, alpha: 1),
                .kern: 1.2,
            ]
        )

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func drawBubble(center: NSPoint, radius: CGFloat, color: NSColor) {
        guard let gradient = NSGradient(
            colors: [
                color.withAlphaComponent(0.44),
                color.withAlphaComponent(0.15),
                color.withAlphaComponent(0),
            ],
            atLocations: [0, 0.58, 1],
            colorSpace: .sRGB
        ) else { return }
        gradient.draw(
            fromCenter: center,
            radius: 0,
            toCenter: center,
            radius: radius,
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )
    }

    private static func drawCentered(
        _ value: String,
        baselineY: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let string = NSAttributedString(string: value, attributes: attributes)
        let size = string.size()
        string.draw(
            at: NSPoint(
                x: (CGFloat(pixelWidth) - size.width) / 2,
                y: baselineY
            )
        )
    }
}
