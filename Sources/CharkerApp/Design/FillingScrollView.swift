import SwiftUI

/// A vertical scroll view whose content is never shorter than the viewport.
///
/// When the window is taller than the page, the spare height is offered to
/// the content's flexible children (the power timeline), so a tall window
/// shows a taller chart instead of an empty band. A page taller than the
/// window scrolls as before.
struct FillingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ViewportFillLayout(minimumHeight: proxy.size.height) {
                    content
                }
            }
        }
    }
}

/// Lays out its single child at its natural height, or at `minimumHeight`
/// when that is taller, proposing the larger height so flexible frames grow.
private struct ViewportFillLayout: Layout {
    var minimumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = max(natural.height, minimumHeight)
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: size.width, height: max(size.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
