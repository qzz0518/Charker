#!/usr/bin/env swift
import AppKit
import Foundation

private let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: make-dmg-background.swift <source.png> <output.png>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("cannot read \(sourceURL.path)\n", stderr)
    exit(1)
}

let size = NSSize(width: 660, height: 400)
let targetAspect = size.width / size.height
let sourceAspect = source.size.width / source.size.height
let sourceRect: NSRect
if sourceAspect > targetAspect {
    let width = source.size.height * targetAspect
    sourceRect = NSRect(
        x: (source.size.width - width) / 2,
        y: 0,
        width: width,
        height: source.size.height
    )
} else {
    let height = source.size.width / targetAspect
    sourceRect = NSRect(
        x: 0,
        y: (source.size.height - height) / 2,
        width: source.size.width,
        height: height
    )
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("cannot create DMG background canvas\n", stderr)
    exit(1)
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
source.draw(
    in: NSRect(origin: .zero, size: size),
    from: sourceRect,
    operation: .copy,
    fraction: 1
)

// Finder chooses black icon-label text even when the background image is dark.
// Quiet light backplates keep both native labels readable without baking a
// second copy of their text into the artwork.
for rect in [
    NSRect(x: 109, y: 88, width: 138, height: 28),
    NSRect(x: 417, y: 88, width: 130, height: 28),
] {
    let plate = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
    NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.67, alpha: 0.92).setFill()
    plate.fill()
    NSColor.white.withAlphaComponent(0.16).setStroke()
    plate.lineWidth = 0.75
    plate.stroke()
}

let centered = NSMutableParagraphStyle()
centered.alignment = .center

let title = "拖动安装  ·  Drag to install"
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
    .paragraphStyle: centered,
    .kern: 0.2,
]
title.draw(
    in: NSRect(x: 40, y: 329, width: 580, height: 30),
    withAttributes: titleAttributes
)

let subtitle = "将 Charker 拖到 Applications 文件夹"
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.57, green: 0.62, blue: 0.70, alpha: 1),
    .paragraphStyle: centered,
    .kern: 0.1,
]
subtitle.draw(
    in: NSRect(x: 40, y: 306, width: 580, height: 20),
    withAttributes: subtitleAttributes
)

let accent = NSColor(calibratedRed: 0.07, green: 0.72, blue: 0.92, alpha: 0.92)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 268, y: 166))
arrow.line(to: NSPoint(x: 389, y: 166))
arrow.move(to: NSPoint(x: 389, y: 166))
arrow.line(to: NSPoint(x: 376, y: 174))
arrow.move(to: NSPoint(x: 389, y: 166))
arrow.line(to: NSPoint(x: 376, y: 158))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
accent.setStroke()
arrow.stroke()

let startDot = NSBezierPath(ovalIn: NSRect(x: 262, y: 163, width: 6, height: 6))
accent.withAlphaComponent(0.72).setFill()
startDot.fill()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("cannot encode DMG background\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
print("wrote \(outputURL.path) (\(Int(size.width))x\(Int(size.height)))")
