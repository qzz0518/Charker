import A2687Protocol
import AppKit
import SwiftUI
import CharkerCore
import Foundation
import ImageIO

/// A reversible square crop. Coordinates are normalised from the source
/// image's top-left corner so the same value can drive both the SwiftUI editor
/// and AppKit's final texture renderer.
struct ModelScreenCrop: Codable, Equatable {
    static let centered = ModelScreenCrop(centerX: 0.5, centerY: 0.5, zoom: 1)

    var centerX: Double
    var centerY: Double
    var zoom: Double

    func clamped(for sourceSize: NSSize) -> ModelScreenCrop {
        let width = max(sourceSize.width, 1)
        let height = max(sourceSize.height, 1)
        let safeZoom = min(max(zoom.isFinite ? zoom : 1, 1), ModelScreenArtwork.maximumZoom)
        let cropSide = min(width, height) / safeZoom
        let halfX = cropSide / width / 2
        let halfY = cropSide / height / 2

        return ModelScreenCrop(
            centerX: min(max(centerX.isFinite ? centerX : 0.5, halfX), 1 - halfX),
            centerY: min(max(centerY.isFinite ? centerY : 0.5, halfY), 1 - halfY),
            zoom: safeZoom
        )
    }

    func sourceRect(for sourceSize: NSSize) -> NSRect {
        let crop = clamped(for: sourceSize)
        let side = min(sourceSize.width, sourceSize.height) / crop.zoom
        return NSRect(
            x: sourceSize.width * crop.centerX - side / 2,
            // NSImage source rectangles use a bottom-left origin; the persisted
            // crop intentionally uses the top-left convention people drag in.
            y: sourceSize.height * (1 - crop.centerY) - side / 2,
            width: side,
            height: side
        )
    }
}

/// The soft dark ring the official app burns around a cover image.
///
/// It has to be part of the pixels. The charger displays exactly the 240×240 it
/// was handed and applies no effect of its own, so a vignette added at display
/// time would show on the 3D model and be missing on the physical screen. Both
/// renderers therefore take the same value, the way they already share `crop`.
///
/// Consequence worth stating where someone will read it: changing the vignette
/// changes the image, and a changed image is a fresh transfer that occupies
/// another one of the charger's four slots. It is not a view setting.
struct ModelScreenVignette: Codable, Equatable {
    /// What Anker ships: black, reaching the corners, leaving the middle clear.
    static let official = ModelScreenVignette(red: 0, green: 0, blue: 0, strength: 0.62)
    /// No ring at all — the cropped photo, edge to edge.
    ///
    /// Deliberately not spelled `none`. This type is not Optional, so the moment
    /// anything holds a `ModelScreenVignette?` the literal `.none` resolves to
    /// `Optional.none` instead, and the compiler picks it without complaint.
    static let disabled = ModelScreenVignette(red: 0, green: 0, blue: 0, strength: 0)

    var red: Double
    var green: Double
    var blue: Double
    /// Opacity at the very corner. 0 disables the effect entirely.
    var strength: Double
    /// Fraction of the half-diagonal that stays untouched before the ring starts.
    /// Below this the image is exactly the crop; above it the colour ramps in.
    var innerRadius: Double = 0.45

    var isEnabled: Bool { strength > 0.001 }

    var color: NSColor {
        NSColor(srgbRed: clamp(red), green: clamp(green), blue: clamp(blue), alpha: 1)
    }

    private func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v.isFinite ? v : 0, 0), 1)) }

    init(red: Double, green: Double, blue: Double, strength: Double, innerRadius: Double = 0.45) {
        self.red = red
        self.green = green
        self.blue = blue
        self.strength = strength
        self.innerRadius = innerRadius
    }

    init(color: NSColor, strength: Double, innerRadius: Double = 0.45) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent), strength: strength, innerRadius: innerRadius
        )
    }

    /// Decoding tolerates a `vignette.json` that exists but is missing keys —
    /// a schema difference between builds, not a migration path. A slot saved
    /// before vignettes existed has no file at all and never reaches this
    /// initialiser; see ``ModelScreenArtworkStore/loadVignette(at:)`` for that.
    ///
    /// Every default here therefore has to mean "the file gave no evidence of a
    /// ring", `strength` included. It used to default to 0.62 to match
    /// `official`, which was the same mistake `loadVignette` made: a decode
    /// fallback inventing a ring the pixels never had.
    private enum CodingKeys: String, CodingKey { case red, green, blue, strength, innerRadius }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0
        innerRadius = try c.decodeIfPresent(Double.self, forKey: .innerRadius) ?? 0.45
    }
}

/// Produces the exact 2.4:1 texture used by the A2687 artwork plane. The GLB
/// expects a transparent canvas, while the physical display itself is a large
/// centred square. Keeping those two shapes distinct prevents a chosen photo
/// from being stretched to the texture canvas's aspect ratio.
enum ModelScreenArtwork {
    static let pixelWidth = 960
    static let pixelHeight = 400
    static let aspectRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
    static let maximumZoom = 4.0

    /// Keep the artwork nearly full-height inside the model's 400 pt UV strip.
    /// The source UV island sits slightly left of the cover's optical centre,
    /// so the face receives a small correction to the right.
    static let screenFrameRect = NSRect(x: 294, y: 2, width: 396, height: 396)
    static let screenImageRect = screenFrameRect.insetBy(dx: 12, dy: 12)

    static let ankerPrimeTexture: NSImage = bitmapImage { canvas, _ in
        NSColor.clear.setFill()
        canvas.fill()

        // The default screen is not a second black panel. Draw only the pixels
        // emitted below the continuous cover glass; the renderer additively
        // places them over the Charker-owned glass geometry.

        let logoRect = NSRect(
            x: canvas.midX - 143,
            y: canvas.midY + 2,
            width: 286,
            height: 68
        )
        if let logo = BrandAssets.ankerLogo {
            logo.draw(
                in: logoRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 52, weight: .semibold),
                .foregroundColor: brandBlue,
                .kern: 1.2,
            ]
            drawCentered("ANKER", in: logoRect, attributes: attributes)
        }

        let primeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 29, weight: .semibold),
            .foregroundColor: brandBlue,
            .kern: 7,
        ]
        drawCentered(
            "PRIME",
            in: NSRect(x: 0, y: canvas.midY - 59, width: canvas.width, height: 38),
            attributes: primeAttributes
        )
    }

    /// Paints the vignette over whatever is already in the current context.
    ///
    /// A radial gradient from clear at the middle to the chosen colour at the
    /// corner. The outer radius is the half-diagonal, not the half-width, so the
    /// corners reach full strength while the edge midpoints stay lighter — that
    /// asymmetry is what makes it read as a lens effect instead of a frame.
    ///
    /// `NSGradient.draw(fromCenter:...)` is deliberate: doing this by compositing
    /// a pre-rendered mask would resample it at every size the callers use
    /// (240 for the panel, 372 for the model), and the banding shows on a dark
    /// ramp like this one.
    static func drawVignette(_ vignette: ModelScreenVignette, in rect: NSRect) {
        guard vignette.isEnabled, rect.width > 0, rect.height > 0 else { return }
        let edge = vignette.color.withAlphaComponent(
            CGFloat(min(max(vignette.strength, 0), 1))
        )
        guard let gradient = NSGradient(
            colors: [edge.withAlphaComponent(0), edge],
            atLocations: [CGFloat(min(max(vignette.innerRadius, 0), 0.95)), 1],
            colorSpace: .sRGB
        ) else { return }
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let halfDiagonal = sqrt(rect.width * rect.width + rect.height * rect.height) / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        gradient.draw(
            fromCenter: centre, radius: 0,
            toCenter: centre, radius: halfDiagonal,
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    static func sourceImage(from url: URL) throws -> NSImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ModelScreenArtworkError.unsupportedImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0,
              image.height > 0 else {
            throw ModelScreenArtworkError.unsupportedImage
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    /// The 3D model's strip. Takes the same `vignette` as the panel JPEG so the
    /// preview and the physical screen cannot drift apart — that correspondence
    /// is the whole point of previewing on the model first.
    ///
    /// `vignette` has no default on purpose. A default here is exactly the shape
    /// of the bug this parameter was added to fix: the caller's choice gets
    /// swallowed at the call site, everything compiles, an image comes out, and
    /// only the colour is wrong. Every caller says which ring it wants.
    static func customTexture(
        from sourceImage: NSImage,
        crop: ModelScreenCrop,
        vignette: ModelScreenVignette
    ) -> NSImage {
        bitmapImage { canvas, context in
            NSColor.clear.setFill()
            canvas.fill()

            // The bezel is part of the generated artwork rather than the photo
            // crop. It therefore remains a consistent black ring for every
            // source image and every camera angle.
            // A translucent black surround preserves the requested screen
            // border while allowing the cover's glossy highlights to remain
            // continuous across it.
            NSColor(deviceWhite: 0.002, alpha: 0.54).setFill()
            NSBezierPath(
                roundedRect: screenFrameRect,
                xRadius: 50,
                yRadius: 50
            ).fill()

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(
                roundedRect: screenImageRect,
                xRadius: 36,
                yRadius: 36
            ).addClip()
            NSColor.black.setFill()
            screenImageRect.fill()
            context.imageInterpolation = .high
            sourceImage.draw(
                in: screenImageRect,
                from: crop.sourceRect(for: sourceImage.size),
                operation: .copy,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            // Inside the clip, so the ring follows the rounded screen cutout
            // rather than the square texture canvas.
            drawVignette(vignette, in: screenImageRect)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.withAlphaComponent(0.46).setStroke()
            let imageEdge = NSBezierPath(
                roundedRect: screenImageRect.insetBy(dx: 0.75, dy: 0.75),
                xRadius: 35.25,
                yRadius: 35.25
            )
            imageEdge.lineWidth = 1.5
            imageEdge.stroke()
        }
    }

    /// The same crop, encoded for the charger's own display instead of the 3D model.
    ///
    /// Deliberately shares `crop` and `vignette` with
    /// ``customTexture(from:crop:vignette:)`` so what the
    /// user lined up on the model is pixel-for-pixel what the panel shows. The
    /// output is bare, though: no bezel, no rounded corners, no transparency —
    /// that ring is drawn into the texture because the model has no physical
    /// bezel, while the real charger does. JPEG has no alpha either, so the
    /// canvas is filled black first rather than left clear.
    ///
    /// 240×240 is the panel's native size (ST7789), and the firmware rejects
    /// anything else. Quality 85 mirrors what the official app uploads; the
    /// reference encoder also disables chroma subsampling, which AppKit does not
    /// expose — a difference in fidelity, not in protocol.
    /// `vignette` is required for the same reason as on
    /// ``customTexture(from:crop:vignette:)``: these are the bytes the charger
    /// keeps, and a default would decide them silently.
    static func deviceCoverJPEG(
        from sourceImage: NSImage,
        crop: ModelScreenCrop,
        vignette: ModelScreenVignette,
        quality: Double = 0.85
    ) throws -> [UInt8] {
        let side = CoverTransfer.screenPixelSize
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            // Four samples with alpha, not the three a JPEG frame actually
            // carries. CoreGraphics has no 24-bit RGB backing store, so
            // `NSGraphicsContext(bitmapImageRep:)` below answers nil for a
            // 3-sample representation — which meant this function threw
            // `.cannotEncode` for every image it was ever handed, silently,
            // because until 同步屏保 landed nothing called it. The channel costs
            // nothing: the canvas is filled opaque black before anything is
            // drawn, and JPEG has no alpha to carry it into the file, so the
            // bytes that reach the charger are the same 240×240 RGB either way.
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw ModelScreenArtworkError.cannotEncode }
        representation.size = NSSize(width: side, height: side)

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw ModelScreenArtworkError.cannotEncode
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor.black.setFill()
        bounds.fill()
        context.imageInterpolation = .high
        sourceImage.draw(
            in: bounds,
            from: crop.sourceRect(for: sourceImage.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        // Burned in, not overlaid: the panel shows these bytes and nothing else.
        drawVignette(vignette, in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: max(0, min(1, quality))]
        ) else { throw ModelScreenArtworkError.cannotEncode }
        return [UInt8](data)
    }

    static func pngData(for image: NSImage) throws -> Data {
        let representation = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
            ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        guard let representation,
              let data = representation.representation(using: .png, properties: [:]) else {
            throw ModelScreenArtworkError.cannotEncode
        }
        return data
    }

    private static let brandBlue = NSColor(
        srgbRed: 0,
        green: 167 / 255,
        blue: 225 / 255,
        alpha: 1
    )

    private static func bitmapImage(
        draw: (NSRect, NSGraphicsContext) -> Void
    ) -> NSImage {
        let canvas = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
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
            return NSImage(size: canvas.size)
        }
        bitmap.size = canvas.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(canvas)
        draw(canvas, context)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: canvas.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func drawCentered(
        _ string: String,
        in rect: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let value = NSAttributedString(string: string, attributes: attributes)
        let size = value.size()
        value.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

/// Shows just the screen square out of a 960×400 model texture.
///
/// The strip is 2.4:1 and the panel image sits inside it at `screenImageRect`,
/// whose centre is *not* the strip's centre — the UV island runs left of the
/// cover's optical middle, so the artwork is drawn with a correction to the
/// right. Any square thumbnail that simply `scaledToFill`s the strip therefore
/// crops off-centre and drags in a slice of the black bezel, which is what made
/// every preview look tilted.
struct ModelScreenSquare: View {
    let image: NSImage
    let side: CGFloat

    var body: some View {
        let screen = ModelScreenArtwork.screenImageRect
        let canvasWidth = CGFloat(ModelScreenArtwork.pixelWidth)
        let canvasHeight = CGFloat(ModelScreenArtwork.pixelHeight)
        let scale = side / screen.width

        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            // Sizing the strip explicitly also normalises any texture whose
            // point size differs from the canvas the rects are expressed in.
            .frame(width: canvasWidth * scale, height: canvasHeight * scale)
            .offset(
                x: (canvasWidth / 2 - screen.midX) * scale,
                // The rect is AppKit's, y up; SwiftUI's offset is y down.
                y: (screen.midY - canvasHeight / 2) * scale
            )
            .frame(width: side, height: side)
            .clipped()
    }
}

struct ModelScreenArtworkItem: Identifiable {
    /// A stable, local-only slot. The UI presents items by their current order,
    /// so deleting an earlier image never exposes internal slot numbers.
    let id: Int
    let textureImage: NSImage
    let sourceImage: NSImage?
    let crop: ModelScreenCrop
    /// The ring already present in `textureImage`, not a setting waiting to be
    /// applied. Slots written before vignettes existed have no file and report
    /// `.disabled`, which is what their pixels are.
    let vignette: ModelScreenVignette
}

enum ModelScreenArtworkStore {
    static let maximumCustomImages = 3

    /// Loads all available custom screens in stable slot order. Slot zero also
    /// understands the original single-image filenames, so existing users keep
    /// their current crop without a migration prompt or another file import.
    static func loadArtworks() -> [ModelScreenArtworkItem] {
        (0..<maximumCustomImages).compactMap(loadArtwork)
    }

    @discardableResult
    static func saveImportedImage(
        slot: Int,
        sourceImage: NSImage,
        crop: ModelScreenCrop,
        vignette: ModelScreenVignette
    ) throws -> ModelScreenArtworkItem {
        let slotDirectory = try slotDirectoryURL(for: slot)
        let safeCrop = crop.clamped(for: sourceImage.size)
        let texture = ModelScreenArtwork.customTexture(
            from: sourceImage, crop: safeCrop, vignette: vignette
        )
        let sourceData = try ModelScreenArtwork.pngData(for: sourceImage)
        let textureData = try ModelScreenArtwork.pngData(for: texture)
        let cropData = try JSONEncoder().encode(safeCrop)
        let vignetteData = try JSONEncoder().encode(vignette)

        try FileManager.default.createDirectory(
            at: slotDirectory,
            withIntermediateDirectories: true
        )
        try sourceData.write(to: sourceArtworkURL(in: slotDirectory), options: .atomic)
        try cropData.write(to: cropURL(in: slotDirectory), options: .atomic)
        try vignetteData.write(to: vignetteURL(in: slotDirectory), options: .atomic)
        try textureData.write(to: customArtworkURL(in: slotDirectory), options: .atomic)

        // The new slot is now complete. Clearing the original single-image
        // files is best-effort and cannot turn a successful replacement into a
        // user-visible save failure.
        if slot == 0 { try? removeLegacyFiles() }

        return ModelScreenArtworkItem(
            id: slot,
            textureImage: NSImage(data: textureData) ?? texture,
            sourceImage: sourceImage,
            crop: safeCrop,
            vignette: vignette
        )
    }

    static func removeCustomImage(slot: Int) throws {
        let slotDirectory = try slotDirectoryURL(for: slot)
        if slot == 0 { try removeLegacyFiles() }
        if FileManager.default.fileExists(atPath: slotDirectory.path) {
            try FileManager.default.removeItem(at: slotDirectory)
        }
    }

    private static func loadArtwork(slot: Int) -> ModelScreenArtworkItem? {
        guard let slotDirectory = try? slotDirectoryURL(for: slot) else { return nil }
        let slotSourceURL = sourceArtworkURL(in: slotDirectory)
        let slotTextureURL = customArtworkURL(in: slotDirectory)
        let slotCropURL = cropURL(in: slotDirectory)

        var sourceImage = loadImage(at: slotSourceURL)
        var textureImage = loadImage(at: slotTextureURL)
        var crop = loadCrop(at: slotCropURL)
        let vignette = loadVignette(at: vignetteURL(in: slotDirectory))

        if slot == 0, sourceImage == nil, textureImage == nil {
            sourceImage = (try? legacySourceArtworkURL).flatMap(loadImage)
            textureImage = (try? legacyCustomArtworkURL).flatMap(loadImage)
            if let legacyCropURL = try? legacyCropURL {
                crop = loadCrop(at: legacyCropURL)
            }
        }

        // Re-render from the source and crop whenever possible. This carries
        // later bezel and sizing refinements into every saved screen instead of
        // freezing the flattened texture from an older build.
        if let sourceImage {
            let safeCrop = crop.clamped(for: sourceImage.size)
            return ModelScreenArtworkItem(
                id: slot,
                textureImage: ModelScreenArtwork.customTexture(
                    from: sourceImage,
                    crop: safeCrop,
                    vignette: vignette
                ),
                sourceImage: sourceImage,
                crop: safeCrop,
                vignette: vignette
            )
        }

        // No source to re-render from: the stored texture already has whatever
        // ring it was saved with baked in, so the value here is a record of that,
        // not something that can still be applied.
        guard let textureImage else { return nil }
        return ModelScreenArtworkItem(
            id: slot,
            textureImage: textureImage,
            sourceImage: nil,
            crop: crop,
            vignette: vignette
        )
    }

    private static func loadImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// An absent file means the slot was saved before vignettes existed, and
    /// those slots have no ring: the pre-vignette `customTexture` drew the
    /// bezel, the clip and the photo, and no gradient of any kind
    /// (`git show 81c4760:Sources/CharkerApp/Design/ModelScreenArtwork.swift`).
    /// So the answer is `disabled`. An earlier comment here claimed the opposite
    /// and returned `official`; it was simply wrong about the old pixels.
    ///
    /// Why that mattered rather than being a cosmetic slip: this value is a
    /// description of pixels that already exist, not a preference. `loadArtwork`
    /// re-renders from the stored source image whenever it has one, so returning
    /// `official` stamped a 62% black ring onto every custom cover a user
    /// already had, on upgrade, with no prompt and no way to see it coming.
    ///
    /// Unifying old covers on the official look is a defensible product call,
    /// but it is a product call — it would have to be told to the user. A
    /// decode fallback does not get to make it.
    private static func loadVignette(at url: URL) -> ModelScreenVignette {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ModelScreenVignette.self, from: data) else {
            return .disabled
        }
        return value
    }

    private static func loadCrop(at url: URL) -> ModelScreenCrop {
        guard let data = try? Data(contentsOf: url),
              let crop = try? JSONDecoder().decode(ModelScreenCrop.self, from: data) else {
            return .centered
        }
        return crop
    }

    private static func removeLegacyFiles() throws {
        let urls = [
            try? legacyCustomArtworkURL,
            try? legacySourceArtworkURL,
            try? legacyCropURL,
        ].compactMap { $0 }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static var directoryURL: URL {
        get throws {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ModelScreenArtworkError.storageUnavailable
            }
            return applicationSupport
                .appendingPathComponent("Charker", isDirectory: true)
                .appendingPathComponent("ModelScreen", isDirectory: true)
        }
    }

    private static func slotDirectoryURL(for slot: Int) throws -> URL {
        guard (0..<maximumCustomImages).contains(slot) else {
            throw ModelScreenArtworkError.invalidSlot
        }
        return try directoryURL
            .appendingPathComponent("slot-\(slot + 1)", isDirectory: true)
    }

    private static func customArtworkURL(in directory: URL) -> URL {
        directory.appendingPathComponent("custom.png", isDirectory: false)
    }

    private static func sourceArtworkURL(in directory: URL) -> URL {
        directory.appendingPathComponent("source.png", isDirectory: false)
    }

    private static func cropURL(in directory: URL) -> URL {
        directory.appendingPathComponent("crop.json", isDirectory: false)
    }

    private static func vignetteURL(in directory: URL) -> URL {
        directory.appendingPathComponent("vignette.json", isDirectory: false)
    }

    private static var legacyCustomArtworkURL: URL {
        get throws { try directoryURL.appendingPathComponent("custom.png", isDirectory: false) }
    }

    private static var legacySourceArtworkURL: URL {
        get throws { try directoryURL.appendingPathComponent("source.png", isDirectory: false) }
    }

    private static var legacyCropURL: URL {
        get throws { try directoryURL.appendingPathComponent("crop.json", isDirectory: false) }
    }
}

private enum ModelScreenArtworkError: LocalizedError {
    case unsupportedImage
    case cannotEncode
    case storageUnavailable
    case invalidSlot

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: return L10n.text("无法读取这张图片，请选择 PNG、JPEG、HEIC 或 WebP 文件")
        case .cannotEncode: return L10n.text("无法生成模型屏幕图片")
        case .storageUnavailable: return L10n.text("无法访问 Charker 的本地图片目录")
        case .invalidSlot: return L10n.text("自定义屏保位置无效")
        }
    }
}
