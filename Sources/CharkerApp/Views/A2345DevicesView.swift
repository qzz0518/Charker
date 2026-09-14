import CharkerCore
import SwiftUI

private struct A2345ConnectionDetailsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct A2345DevicesView: View {
    @ObservedObject var model: AppModel
    @State private var signingIn = false
    @State private var confirmingSignOut = false
    /// Width of the detail pane. Choosing one branch from this value avoids
    /// `ViewThatFits` constructing both connection-card layouts just to discard one.
    @State private var contentWidth: CGFloat = 0
    /// Mirrors the A2687 connection card: in the wide branch, the product well
    /// shares the exact vertical footprint of the identity column.
    @State private var currentConnectionDetailsHeight: CGFloat = 0

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
                if !snapshot.isDemo { accountAndPrivacyCard }
                capabilityCard
            }
            .padding(Space.xxl)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .measuringContainerWidth()
        .onContainerWidthChange { contentWidth = $0 }
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
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("正在使用 A2345 模拟设备")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                    Text("六端口功率与能耗记录均为本机模拟，不会连接 Anker 账号。")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
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
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("当前连接")
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)
            Text("A2345 · Wi-Fi 云端只读")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
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
                HStack(alignment: .top, spacing: Space.xl) {
                    connectionArtwork(
                        active: snapshot.hasFreshTelemetry,
                        height: 136,
                        minimumSurfaceHeight: currentConnectionDetailsHeight
                    )
                    .frame(width: 176)
                    connectedDetails
                        .background {
                            GeometryReader { details in
                                Color.clear.preference(
                                    key: A2345ConnectionDetailsHeightKey.self,
                                    value: details.size.height
                                )
                            }
                        }
                }
                .onPreferenceChange(A2345ConnectionDetailsHeightKey.self) { measuredHeight in
                    guard measuredHeight > 0 else { return }
                    let height = ceil(measuredHeight)
                    guard abs(height - currentConnectionDetailsHeight) > 0.5 else { return }
                    currentConnectionDetailsHeight = height
                }
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
        minimumSurfaceHeight: CGFloat? = nil
    ) -> some View {
        A2345ProductStage(active: active, height: height)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.m)
            .frame(minHeight: minimumSurfaceHeight)
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
                    Text("A2345 连接没有完成")
                        .font(Typo.title)
                        .foregroundStyle(Palette.textPrimary)
                    Text(reason)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.dangerText)
                        .cjkParagraph(11, target: 1.55)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(failureRecoveryHint)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

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

    private var failureRecoveryHint: String {
        if model.a2345BoundDevices.count > 1 {
            return L10n.text("选择下方的一台设备后，Charker 会立即建立它的只读订阅。")
        }
        if model.hasRememberedCharger {
            return L10n.text("账号令牌仍安全保存在钥匙串，不需要重新输入密码。")
        }
        return L10n.text("请重新登录绑定这台充电器的 Anker 账号。")
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("账号中的 A2345")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                Text("选择要在总览和菜单栏中监控的设备。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

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
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("使用 Anker 账号查找 A2345")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("A2345 的 Wi-Fi 遥测通过 Anker 云端发送。登录后，Charker 会读取账号下绑定的设备并建立只读订阅。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .cjkParagraph(11, target: 1.55)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Space.s) {
                step(1, "确认充电器已在官方 Anker App 中完成 Wi-Fi 配网")
                step(2, "使用绑定该设备的同一个 Anker 账号登录")
                step(3, "Charker 自动识别 A2345 并订阅实时数据")
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

    private var accountAndPrivacyCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("账号与数据路径")
                            .font(Typo.heading)
                            .foregroundStyle(Palette.textPrimary)
                        Text("A2345 使用云端只读连接；A2687 仍保持本地蓝牙直连。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: Space.m)
                    if model.hasRememberedCharger {
                        Button("退出账号") { confirmingSignOut = true }
                            .buttonStyle(CharkerActionButtonStyle(emphasis: .destructive))
                    }
                }

                Divider().overlay(Palette.stroke)

                privacyRow("钥匙串", "只保存短期登录令牌，不保存密码", symbol: "key.fill")
                privacyRow("MQTT", "客户端证书仅驻留内存，断开后释放", symbol: "lock.shield.fill")
                privacyRow("Charker", "不上传到 Charker 服务器，也不转发遥测", symbol: "externaldrive.fill.badge.checkmark")
            }
        }
    }

    private func privacyRow(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accentText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title)).font(Typo.label).foregroundStyle(Palette.textPrimary)
                Text(L10n.text(detail)).font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var capabilityCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("当前支持范围")
                            .font(Typo.heading)
                            .foregroundStyle(Palette.textPrimary)
                        Text("只把已经由真机或可复核帧确认的字段放进产品。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    Chip(text: L10n.text("只读"), tone: .neutral)
                }

                Divider().overlay(Palette.stroke)

                capability("六端口实时电压、电流与功率", confirmed: true)
                capability("固件与 MCU / ESP32 部件版本", confirmed: true)
                capability("端口开关、定时、充电模式与屏幕设置", confirmed: false)
            }
        }
    }

    private func capability(_ text: String, confirmed: Bool) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: confirmed ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(confirmed ? Palette.ok : Palette.textTertiary)
            Text(L10n.text(text))
                .font(Typo.caption)
                .foregroundStyle(confirmed ? Palette.textSecondary : Palette.textTertiary)
            Spacer()
            if !confirmed {
                Text("尚未开放")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }
}
