import AppKit
import CharkerCore
import SwiftUI

/// Window sizes per product, measured from the overview: at this size it fits
/// whole, with the 3D model and the port panel side by side, and nothing
/// scrolls. Other pages may scroll. A taller window gives the extra height to
/// the overview's chart.
///
/// Heights are of the area below the title bar and toolbar (38 pt), the same
/// space SwiftUI lays the pages out in. Both are capped by the screen the
/// window is on.
@MainActor
enum MainWindowSizing {
    /// The smallest window that still shows the whole overview.
    static func minimum(for product: ChargerProduct) -> CGSize {
        switch product {
        case .a2687: return CGSize(width: 890, height: 840)
        case .a2345: return CGSize(width: 940, height: 910)
        }
    }

    /// The size a window opens at: the overview exactly. The A2345 is wider
    /// so its default 3D view shows the whole charger.
    static func comfortable(for product: ChargerProduct) -> CGSize {
        switch product {
        case .a2687: return CGSize(width: 969, height: 840)
        case .a2345: return CGSize(width: 1120, height: 910)
        }
    }

    /// The largest content size that keeps the whole window on `screen`.
    static func available(on screen: NSScreen?, chrome: CGFloat = 40) -> CGSize {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            return CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        return CGSize(width: visible.width, height: visible.height - chrome)
    }

    /// The minimum content size SwiftUI should enforce, never larger than the
    /// screen allows.
    static func enforcedMinimum(for product: ChargerProduct, screen: NSScreen? = nil) -> CGSize {
        let wanted = minimum(for: product)
        let limit = available(on: screen)
        return CGSize(width: min(wanted.width, limit.width), height: min(wanted.height, limit.height))
    }

    /// Sizes the window for `product`, keeping its top-left corner where it
    /// was and the whole window on screen. `exact` sets the comfortable size
    /// in both directions; otherwise only a smaller window grows to it.
    static func fit(_ window: NSWindow, for product: ChargerProduct, exact: Bool, animate: Bool) {
        // A full-screen window is the screen: resizing it only leaves a small
        // window in its Space. AppKit restores the windowed frame on exit.
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        // The page area: the window minus its title bar and toolbar.
        let content = window.contentLayoutRect.size
        let chrome = frame.height - content.height
        let limit = CGSize(width: visible.width, height: visible.height - chrome)
        let target = comfortable(for: product)

        var size = content
        if exact {
            size = target
        } else {
            size.width = max(size.width, target.width)
            size.height = max(size.height, target.height)
        }
        size.width = min(size.width, limit.width)
        size.height = min(size.height, limit.height)
        guard abs(size.width - content.width) > 0.5 || abs(size.height - content.height) > 0.5 else { return }

        var next = NSRect(
            x: 0, y: 0,
            width: frame.width + (size.width - content.width),
            height: size.height + chrome
        )
        next.origin.x = frame.minX
        next.origin.y = frame.maxY - next.height
        if next.maxY > visible.maxY { next.origin.y = visible.maxY - next.height }
        if next.minY < visible.minY { next.origin.y = visible.minY }
        if next.maxX > visible.maxX { next.origin.x = visible.maxX - next.width }
        if next.minX < visible.minX { next.origin.x = visible.minX }
        window.setFrame(next, display: true, animate: animate)
    }
}

/// Calls back once the hosting view is inside a window, so the window can be
/// sized as it opens rather than when it first becomes key.
struct WindowAttachmentReader: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onAttach: onAttach) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onAttach: (NSWindow) -> Void

        init(onAttach: @escaping (NSWindow) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After AppKit has applied the restored frame.
            DispatchQueue.main.async { [onAttach] in onAttach(window) }
        }
    }
}
