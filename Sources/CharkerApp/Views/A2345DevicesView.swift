import CharkerCore
import SwiftUI

struct A2345DevicesView: View {
    @ObservedObject var model: AppModel
    @State private var signingIn = false
    @State private var confirmingSignOut = false
    /// Width of the detail pane. Choosing one branch from this value avoids
    /// `ViewThatFits` constructing both connection-card layouts just to discard one.
    @State private var contentWidth: CGFloat

    /// Rebuilt on every sidebar visit; starting from the last measured width
    /// spares the first measurement a write that would re-run this body.
    init(model: AppModel) {
        self.model = model
        _contentWidth = State(initialValue: Self.lastContentWidth)
    }

    private static var lastContentWidth: CGFloat = 0
    private static let currentCardWideBreakpoint: CGFloat = 560

    private var snapshot: A2345ConnectionSnapshot { model.a2345Snapshot }
    private var isFailed: Bool {
        if case .failed = snapshot.phase { return true }
        return false
    }
    private var hasSelectedBoundDevice: Bool {
        guard model.a2345BoundDevices.count > 1 else { return true }
        return model.a2345BoundDevices.contains {
            $0.serialNumber == model.preferences.a2345SelectedSerial
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if snapshot.isDemo { demoBanner }
                currentConnectionCard
                if !snapshot.isDemo, model.hasRememberedCharger { accountCard }
            }
            .padding(Space.xxl)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .measuringContainerWidth()
        .onContainerWidthChange { width in
            guard width != contentWidth else { return }
            contentWidth = width
            Self.lastContentWidth = width
        }
        .sheet(isPresented: $signingIn) {
            AnkerSignInView(model: model, purpose: .a2345Cloud)
        }
        .confirmationDialog(
            "退出 A2345 云端连接？",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("退出并删除钥匙串令牌", role: .destructive) {
                model.forgetA2345Account()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会解除官方 Anker App 中的设备绑定，也不会删除本地能耗记录。")
        }
    }

    private var demoBanner: some View {
        SlateCard {
            HStack(spacing: Space.m) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.accentWash))
                Text("正在使用 A2345 模拟设备")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Space.m)
                Button("选择其他充电器") { model.restartInitialSetup() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))
                Button("退出模拟") { model.exitDemoMode() }
                    .buttonStyle(CharkerActionButtonStyle())
            }
        }
    }

    private var currentConnectionCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.l) {
                currentConnectionHeader

                if snapshot.isDemo {
                    connectedContent
                } else if case .failed(let reason) = snapshot.phase {
                    failedContent(reason)
                } else if snapshot.device != nil {
                    connectedContent
                } else if snapshot.phase.isBusy {
                    connectionProgressContent
                } else {
                    onboardingContent
                }

                if model.a2345BoundDevices.count > 1 {
                    Divider().overlay(Palette.stroke)
                    devicePicker
                }
            }
        }
    }

    @ViewBuilder
    private var currentConnectionHeader: some View {
        if connectionCardFitsSideBySide {
            HStack(alignment: .center, spacing: Space.m) {
                currentConnectionHeading
                Spacer(minLength: Space.m)
                currentConnectionActions
            }
        } else {
            VStack(alignment: .leading, spacing: Space.m) {
                currentConnectionHeading
                currentConnectionActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var currentConnectionHeading: some View {
        Text("当前连接")
            .font(Typo.heading)
            .foregroundStyle(Palette.textPrimary)
    }

    private var currentConnectionActions: some View {
        HStack(spacing: Space.s) {
            if snapshot.isDemo {
                Chip(text: L10n.text("模拟"), tone: .accent)
            } else {
                Button {
                    model.restartInitialSetup()
                } label: {
                    Label("选择其他充电器", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))

                if snapshot.phase.isBusy {
                    ProgressView().controlSize(.small)
                } else if model.canRetryA2345, snapshot.device != nil, !isFailed {
                    Button {
                        model.retryA2345Connection()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CharkerActionButtonStyle())
                }
            }
        }
    }

    private var connectedContent: some View {
        Group {
            if connectionCardFitsSideBySide {
                // Mirrors the A2687 connection card: the product well stretches
                // to the row the identity column sets, in layout rather than
                // through a measured height written back into state.
                HStack(alignment: .top, spacing: Space.xl) {
                    connectionArtwork(
                        active: snapshot.hasFreshTelemetry,
                        height: 136,
                        fillsRowHeight: true
                    )
                    .frame(width: 176)
                    connectedDetails
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    connectionArtwork(active: snapshot.hasFreshTelemetry, height: 108)
                    connectedDetails
                }
            }
        }
    }

    private var connectedDetails: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(snapshot.displayName)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                statusLine
            }

            connectedMetadataPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: some View {
        let tone = A2345StateTone(
            phase: snapshot.phase,
            stale: snapshot.isStale,
            isDemo: snapshot.isDemo
        )
        return HStack(spacing: Space.s) {
            A2345StateDot(
                phase: snapshot.phase,
                stale: snapshot.isStale,
                isDemo: snapshot.isDemo,
                diameter: 8,
                glowsWhenLive: false
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeStatusLabel)
                    .font(Typo.label)
                    .foregroundStyle(tone.labelColor)
                Text(model.activeStatusDetail)
                    .font(Typo.caption)
                    .foregroundStyle(tone == .danger ? Palette.dangerText : Palette.textTertiary)
            }
        }
    }

    /// The connection page deliberately uses a static render. This keeps the
    /// dashboard as the single interactive 3D surface and gives identity details
    /// the same bounded media well used by the A2687 page.
    private func connectionArtwork(
        active: Bool,
        height: CGFloat,
        fillsRowHeight: Bool = false
    ) -> some View {
        A2345ProductStage(active: active, height: height)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.m)
            .frame(maxHeight: fillsRowHeight ? .infinity : nil)
            .background {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .fill(Palette.well.opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
            }
    }

    private var connectedMetadataPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                metadataCell("型号", value: "A2345")
                metadataDivider
                metadataCell("固件", value: snapshot.device?.firmwareVersion ?? "—")
            }
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: Stroke.hairline)
            HStack(alignment: .top, spacing: 0) {
                metadataCell("Wi-Fi", value: wifiStatus)
                metadataDivider
                metadataCell(
                    "序列号",
                    value: snapshot.device?.serialNumber ?? "A2345-DEMO",
                    middleTruncation: true
                )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .fill(Palette.well.opacity(0.56))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
    }

    private var metadataDivider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(width: Stroke.hairline)
            .padding(.vertical, Space.m)
    }

    private func metadataCell(
        _ label: String,
        value: String,
        middleTruncation: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(.numeral(11, .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(middleTruncation ? .middle : .tail)
                .minimumScaleFactor(0.78)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
    }

    private var onboardingContent: some View {
        Group {
            if connectionCardFitsSideBySide {
                HStack(alignment: .center, spacing: Space.xl) {
                    connectionArtwork(active: false, height: 136)
                        .frame(width: 176)
                    onboardingDetails
                }
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    connectionArtwork(active: false, height: 108)
                    onboardingDetails
                }
            }
        }
    }

    private var connectionProgressContent: some View {
        HStack(alignment: .top, spacing: Space.m) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(snapshot.phase.shortLabel)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                Text(snapshot.phase.detail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func failedContent(_ reason: String) -> some View {
        Group {
            if connectionCardFitsSideBySide {
                HStack(alignment: .center, spacing: Space.xl) {
                    connectionArtwork(active: false, height: 136)
                        .frame(width: 176)
                    failedDetails(reason)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    connectionArtwork(active: false, height: 108)
                    failedDetails(reason)
                }
            }
        }
    }

    /// Match the A2687 identity card's breakpoint and media-well width. Before
    /// the first measurement, prefer the normal-window branch to avoid a compact
    /// to wide flash on launch.
    private var connectionCardFitsSideBySide: Bool {
        contentWidth == 0 || contentWidth >= Self.currentCardWideBreakpoint
    }

    private func failedDetails(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "bolt.slash.fill")
                    .foregroundStyle(Palette.danger)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("连接没有完成")
                        .font(Typo.title)
                        .foregroundStyle(Palette.textPrimary)
                    Text(reason)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.dangerText)
                        .cjkParagraph(11, target: 1.55)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Space.s) {
                if model.canRetryA2345, hasSelectedBoundDevice {
                    Button {
                        model.retryA2345Connection()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                } else if !model.hasRememberedCharger {
                    Button {
                        signingIn = true
                    } label: {
                        Label("重新登录", systemImage: "person.badge.key")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                }

                Button {
                    model.enterDemoMode(product: .a2345)
                } label: {
                    Label("体验模拟设备", systemImage: "play.fill")
                }
                .buttonStyle(CharkerActionButtonStyle(
                    emphasis: .secondary
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("账号中的 A2345")
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)

            ForEach(model.a2345BoundDevices) { device in
                let selected = snapshot.device?.serialNumber == device.serialNumber
                    || (snapshot.device == nil
                        && model.preferences.a2345SelectedSerial == device.serialNumber)
                Button {
                    model.selectA2345Device(serialNumber: device.serialNumber)
                } label: {
                    HStack(spacing: Space.m) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Palette.accentText : Palette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(Typo.label)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(device.serialNumber)
                                .font(.numeral(10, .regular))
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: Space.s)
                        Text(deviceWiFiStatus(device.isWiFiOnline))
                            .font(Typo.micro)
                            .foregroundStyle(device.isWiFiOnline == true
                                ? Palette.okText
                                : (device.isWiFiOnline == false
                                    ? Palette.warnText
                                    : Palette.textTertiary))
                    }
                    .padding(.horizontal, Space.m)
                    .frame(minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(selected ? Palette.accentWash : Palette.well)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(selected ? Palette.accent.opacity(0.45) : Palette.stroke)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(snapshot.phase.isBusy)
                .accessibilityLabel(Text(L10n.format("%@，序列号 %@", device.name, device.serialNumber)))
                .accessibilityValue(Text(L10n.format(
                    "%@，%@",
                    selected ? L10n.text("已选择") : L10n.text("未选择"),
                    deviceWiFiStatus(device.isWiFiOnline)
                )))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(Text(L10n.text("按下以监控这台设备")))
            }
        }
    }

    private func deviceWiFiStatus(_ online: Bool?) -> String {
        switch online {
        case true: return L10n.text("Wi-Fi 在线")
        case false: return L10n.text("Wi-Fi 离线")
        case nil: return L10n.text("Wi-Fi 状态未知")
        }
    }

    private var onboardingDetails: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("使用 Anker 账号查找 A2345")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            VStack(alignment: .leading, spacing: Space.s) {
                step(1, "确认充电器已在官方 Anker App 中完成 Wi-Fi 配网")
                step(2, "使用绑定该设备的同一个 Anker 账号登录")
            }

            HStack(spacing: Space.s) {
                Button {
                    signingIn = true
                } label: {
                    Label("登录并连接", systemImage: "person.badge.key")
                }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                .disabled(snapshot.phase.isBusy || model.isSigningIn)
                .help(L10n.text("登录 Anker 账号并连接 A2345"))

                Button {
                    model.restartInitialSetup()
                } label: {
                    Label("重新选择型号", systemImage: "arrow.left")
                }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wifiStatus: String {
        switch snapshot.device?.isWiFiOnline {
        case true: return L10n.text("已连接")
        case false: return L10n.text("离线")
        case nil: return L10n.text("未知")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(verbatim: "\(number)")
                .font(.numeral(9, .semibold))
                .foregroundStyle(Palette.accentText)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.accentWash))
            Text(L10n.text(text))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountCard: some View {
        SlateCard {
            HStack {
                Text("Anker 账号")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Space.m)
                Button("退出账号") { confirmingSignOut = true }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .destructive))
            }
        }
    }
}
