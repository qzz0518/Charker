import AppKit
import CoreGraphics

/// Prepares a picture for the A2345 clock screen the way the official app
/// does: filled into 480×200 and saved as a JPEG of roughly 77–96 KB.
enum A2345PictureEncoder {
    static let size = CGSize(width: 480, height: 200)
    static let maximumBytes = 98_304
    static let minimumBytes = 78_643

    /// The fill crop, for preview and upload alike.
    static func crop(_ image: NSImage) -> CGImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let scale = max(size.width / sourceSize.width, size.height / sourceSize.height)
        let drawn = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(source, in: CGRect(
            x: (size.width - drawn.width) / 2,
            y: (size.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        return context.makeImage()
    }

    /// Searches the JPEG quality (1…90) for a file inside the size window.
    static func jpeg(_ cropped: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cropped)
        func encode(_ quality: Int) -> Data? {
            rep.representation(using: .jpeg, properties: [.compressionFactor: Double(quality) / 100])
        }
        var low = 1
        var high = 90
        var best: Data?
        var quality = 45
        for _ in 0..<8 {
            guard let data = encode(quality) else { return best }
            if data.count > maximumBytes {
                high = quality - 1
            } else {
                best = data
                if data.count >= minimumBytes { return data }
                low = quality + 1
            }
            guard low <= high else { break }
            quality = (low + high) / 2
        }
        return best ?? encode(1)
    }
}
