import AppKit
import CharkerCore
import SwiftUI

/// The only first-run decision Charker cannot infer: which physical product
/// the user owns, followed by whether this run should use hardware or the local
/// simulator. Connection details remain on the product-specific Devices page.
struct InitialSetupView: View {
    @ObservedObject var model: AppModel
    @State private var selectedProduct: ChargerProduct?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    progress

                    Group {
                        if let selectedProduct {
                            routeStep(for: selectedProduct)
                                .transition(stepTransition(forward: true))
                        } else {
                            productStep
                                .transition(stepTransition(forward: false))
                        }
                    }
                    .animation(Motion.reduced(Motion.ui, reduceMotion), value: selectedProduct)
                }
                .padding(.horizontal, Space.xxxl)
                .padding(.vertical, Space.xxl)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .background(Palette.bg.ignoresSafeArea())
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: "Charker")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("充电器功率与能耗监控")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

            Spacer(minLength: Space.m)
            Chip(text: L10n.text("首次设置"), tone: .neutral)
        }
    }

    private var progress: some View {
        HStack(spacing: Space.s) {
            setupStep(
                number: 1,
                title: L10n.text("选择型号"),
                active: selectedProduct == nil,
                completed: selectedProduct != nil
            )
            Capsule(style: .continuous)
                .fill(selectedProduct == nil ? Palette.strokeStrong : Palette.accent.opacity(0.55))
                .frame(maxWidth: 48)
                .frame(height: Stroke.hairline)
                .accessibilityHidden(true)
            setupStep(
                number: 2,
                title: L10n.text("选择使用方式"),
                active: selectedProduct != nil,
                completed: false
            )
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.format(
            "首次设置，第 %d 步，共 2 步",
            selectedProduct == nil ? 1 : 2
        )))
    }

    private func setupStep(
        number: Int,
        title: String,
        active: Bool,
        completed: Bool
    ) -> some View {
        HStack(spacing: Space.s) {
            ZStack {
                Circle().fill(active || completed ? Palette.accentWash : Palette.well)
                if completed {
                    Image(systemName: "checkmark")
                } else {
                    Text(verbatim: "\(number)")
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(active || completed ? Palette.accentText : Palette.textTertiary)
            .frame(width: 20, height: 20)
            .overlay {
                Circle().strokeBorder(
                    active || completed ? Palette.accent.opacity(0.34) : Palette.stroke,
                    lineWidth: Stroke.hairline
                )
            }
            Text(title)
                .font(Typo.micro)
                .foregroundStyle(active ? Palette.textPrimary : Palette.textTertiary)
        }
    }

    private var productStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("你使用哪一款充电器？")
                    .font(.ui(26, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("先选择产品型号，下一步再决定连接真实设备还是进入模拟体验。")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            HStack(alignment: .top, spacing: Space.l) {
                ProductChoiceButton(product: .a2687) {
                    choose(.a2687)
                }
                ProductChoiceButton(product: .a2345) {
                    choose(.a2345)
                }
            }

            Label("以后可以随时在“设备与连接”中更换型号", systemImage: "arrow.triangle.2.circlepath")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func routeStep(for product: ChargerProduct) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("选择使用方式")
                    .font(.ui(26, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("先连接真实设备，或者不需要硬件直接体验完整界面。")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            HStack(alignment: .top, spacing: Space.l) {
                selectedProductCard(product)
                    .frame(width: 270)

                VStack(spacing: Space.m) {
                    SetupRouteButton(
                        title: L10n.text("连接真实设备"),
                        detail: realConnectionDetail(for: product),
                        symbol: product == .a2687
                            ? "antenna.radiowaves.left.and.right"
                            : "wifi",
                        primary: true
                    ) {
                        connectRealDevice(product)
                    }

                    SetupRouteButton(
                        title: L10n.text("体验模拟设备"),
                        detail: L10n.text("无需充电器或账号，使用本机模拟数据体验总览、端口与能耗记录。"),
                        symbol: "play.fill",
                        primary: false
                    ) {
                        model.enterDemoMode(product: product)
                    }

                    HStack {
                        Button {
                            choose(nil)
                        } label: {
                            Label("重新选择型号", systemImage: "arrow.left")
                        }
                        .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func selectedProductCard(_ product: ChargerProduct) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            productArtwork(product, height: 116)
                .frame(maxWidth: .infinity)
                .frame(height: 128)
                .accessibilityHidden(true)
                .background {
                    RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                        .fill(Palette.well.opacity(0.72))
                }

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: product.displayName)
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Text(product.connectionLabel)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.accentText)
                Text(productPortSummary(product))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Space.l)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func productArtwork(_ product: ChargerProduct, height: CGFloat) -> some View {
        switch product {
        case .a2687:
            ProductStage(active: true, height: height)
        case .a2345:
            A2345ProductStage(active: true, height: height * 0.82)
                .padding(.horizontal, Space.m)
        }
    }

    private func choose(_ product: ChargerProduct?) {
        withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
            selectedProduct = product
        }
    }

    private func connectRealDevice(_ product: ChargerProduct) {
        switch product {
        case .a2687: model.useBluetoothConnection()
        case .a2345: model.useA2345CloudConnection()
        }
    }

    private func realConnectionDetail(for product: ChargerProduct) -> String {
        switch product {
        case .a2687:
            return L10n.text("直接扫描附近充电器，无需先在 macOS 蓝牙设置中配对。")
        case .a2345:
            return L10n.text("使用绑定设备的 Anker 账号登录；请先在官方 App 中完成 Wi-Fi 配网。")
        }
    }

    private func productPortSummary(_ product: ChargerProduct) -> String {
        switch product {
        case .a2687: return L10n.text("3 个 USB-C 端口 · 最高 160 W")
        case .a2345: return L10n.text("4 个 USB-C + 2 个 USB-A · 最高 250 W")
        }
    }

    private func stepTransition(forward: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 12 : -12)),
            removal: .opacity
        )
    }
}

private struct ProductChoiceButton: View {
    let product: ChargerProduct
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.m) {
                productArtwork
                    .frame(maxWidth: .infinity)
                    .frame(height: 112)
                    .accessibilityHidden(true)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                            .fill(Palette.well.opacity(0.72))
                    }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: product.displayName)
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Text(product.connectionLabel)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.accentText)
                    Text(portSummary)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }

                HStack(spacing: Space.s) {
                    Text("选择这款")
                        .font(Typo.label)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .offset(x: hovering && !reduceMotion ? 2 : 0)
                }
                .foregroundStyle(Palette.accentText)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(hovering ? Palette.surfaceElevated : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        hovering ? Palette.accent.opacity(0.48) : Palette.stroke,
                        lineWidth: hovering ? Stroke.focus : Stroke.hairline
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
        .accessibilityLabel(Text(L10n.format(
            "选择 %@，%@",
            product.displayName,
            product.connectionLabel
        )))
    }

    @ViewBuilder
    private var productArtwork: some View {
        switch product {
        case .a2687:
            ProductStage(active: true, height: 102)
        case .a2345:
            A2345ProductStage(active: true, height: 86)
                .padding(.horizontal, Space.m)
        }
    }

    private var portSummary: String {
        switch product {
        case .a2687: return L10n.text("3 个 USB-C 端口 · 最高 160 W")
        case .a2345: return L10n.text("4 个 USB-C + 2 个 USB-A · 最高 250 W")
        }
    }
}

private struct SetupRouteButton: View {
    let title: String
    let detail: String
    let symbol: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primary ? Palette.accentText : Palette.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(primary ? Palette.accentWash : Palette.surfaceRaised))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title)
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Text(detail)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(primary ? Palette.accentText : Palette.textTertiary)
                    .offset(x: hovering && !reduceMotion ? 2 : 0)
                    .accessibilityHidden(true)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(border, lineWidth: Stroke.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
        .accessibilityLabel(Text("\(title)。\(detail)"))
    }

    private var background: Color {
        if primary { return Palette.accentWash.opacity(hovering ? 0.82 : 0.58) }
        return hovering ? Palette.surfaceRaised : Palette.surface
    }

    private var border: Color {
        if primary { return Palette.accent.opacity(hovering ? 0.55 : 0.36) }
        return hovering ? Palette.strokeStrong : Palette.stroke
    }
}
