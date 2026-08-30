import SwiftUI

// MARK: - Container width measurement
//
// `ViewThatFits` picks a layout by *building and measuring every candidate* on
// each layout pass, then throwing the losers away. That is fine for a row of
// labels and ruinous when a candidate holds an `NSViewRepresentable` or a Swift
// Charts plot: the overview was constructing a second SceneKit host (model
// clone, port buttons, Metal view) and a second port inspector on every display
// cycle. Measuring the window-driven width once and building a single branch
// removes that duplication outright.
//
// The width is read from a container whose size the *parent* imposes — a scroll
// view, a window-sized frame — never from the branch content, so the choice can
// never feed back into the measurement and oscillate.

struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Publishes this view's laid-out width through ``ContainerWidthKey``.
    /// Attach it to something the parent sizes, not to content that can grow.
    func measuringContainerWidth() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: ContainerWidthKey.self, value: proxy.size.width)
            }
        }
    }

    /// Receives the width published by ``measuringContainerWidth()``.
    func onContainerWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        onPreferenceChange(ContainerWidthKey.self) { width in
            guard width > 0 else { return }
            action(width)
        }
    }
}
