import A2687Protocol
import AppKit
import CharkerCore
import SwiftUI

private struct CurrentConnectionDetailsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Everything the radio can see, so a charger that auto-detection misses can still
/// be picked by hand. This is also the honest answer to "为什么搜不到设备".
struct DevicesView: View {
    @ObservedObject var model: AppModel
    @State private var signingIn = false
    @State private var showsScreenSettings = false
    /// Staged copy of the manual owner-id field. Binding the TextField straight
    /// to preferences rebuilt the BLE session on every keystroke.
    @State private var ownerDraft = ""
    @State private var serialCopied = false
    /// Guards the copy tick's own timer, so a second copy is not un-ticked by
    /// the first one's countdown.
    @State private var copyGeneration = 0
    @State private var confirmingForget = false
    /// Brightness is staged locally and sent only when Apply is pressed. Sending
    /// on every slider tick would turn one drag into dozens of BLE writes.
    @State private var brightnessDraft = 100.0
    @State private var brightnessEditing = false
    /// The devices page already has a 680 pt reading column, but the app window
    /// can be narrowed below it. Build one connection-card branch from that real
    /// width instead of letting the product stage squeeze the metadata into a
    /// long, sparse key/value table.
    @State private var contentWidth: CGFloat = 0
    /// In the wide card, the product well and the identity column are one visual
    /// row. Let the taller identity column set the well's floor so their top and
    /// bottom edges agree instead of leaving an arbitrary eight-point step.
    @State private var currentConnectionDetailsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: SessionSnapshot { model.snapshot }
    private static let currentCardWideBreakpoint: CGFloat = 560
    private static let nearbyRowHeight: CGFloat = 48
    private static let nearbyListMaxHeight: CGFloat = 280

    /// One or two results should not reserve an empty five-row viewport. The
    /// list grows with its content, then becomes an internal scroller once it
    /// reaches the cap requested for busy Bluetooth environments.
    private static func nearbyListHeight(deviceCount: Int) -> CGFloat {
        let rows = CGFloat(max(deviceCount, 1))
        let gaps = CGFloat(max(deviceCount - 1, 0)) * Space.xs
        return min(rows * nearbyRowHeight + gaps, nearbyListMaxHeight)
    }

    private var showsFirstConnectionFlow: Bool {
        !snapshot.isDemo && !model.hasRememberedCharger && snapshot.peripheralID == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if showsFirstConnectionFlow {
                    firstConnectionCard
                    nearbyCard
                } else {
                    if snapshot.isDemo { demoModeCard }
                    currentCard
                    deviceSettingsCard
                    modelScreenCard
                    if !snapshot.isDemo {
                        accountCard
                        nearbyCard
                    }
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: 680, alignment: .leading)
            .measuringContainerWidth()
            // Centered by the scroll view itself. Wrapping the ScrollView in an
            // outer flexible frame displaced the legacy scroller off the
            // window edge under "always show scroll bars".
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .onContainerWidthChange { contentWidth = $0 }
        .onAppear {
            ownerDraft = model.preferences.ownerUserID
            syncBrightnessDraft(snapshot.telemetry?.settings?.screenBrightness)
            // Picker browsing disables transport auto-connect. Let a remembered
            // charger finish its own reconnect path instead of racing it here.
            if snapshot.peripheralID == nil, snapshot.canBrowseNearbyDevices {
                model.browse()
            }
        }
        // The sign-in sheet writes the id from over the top of this view; the
        // staged draft must follow, or its next commit would overwrite the
        // freshly fetched account id with stale text.
        .onChange(of: model.preferences.ownerUserID) { _, value in
            if ownerDraft != value { ownerDraft = value }
        }
        .onChange(of: snapshot.telemetry?.settings?.screenBrightness) { _, value in
            syncBrightnessDraft(value)
        }
        .sheet(isPresented: $signingIn) { AnkerSignInView(model: model) }
        .sheet(isPresented: $showsScreenSettings) {
            ModelScreenSettingsSheet(
                model: model,
                style: model.preferences.modelScreenStyle,
                artworks: model.modelScreenArtworks,
                selectedCustomID: model.preferences.modelScreenCustomSlot,
                importError: model.modelScreenArtworkError,
                onSelectAnkerPrime: { model.selectAnkerPrimeModelScreen() },
                onSelectCustom: { model.selectModelScreenArtwork(id: $0) },
                onCommit: { id, image, crop, vignette in
                    model.saveModelScreenArtwork(
                        replacing: id,
                        sourceImage: image,
                        crop: crop,
                        vignette: vignette
                    )
                },
                onRemove: { model.removeModelScreenArtwork(id: $0) }
            )
        }
    }

    // MARK: - Connection onboarding

    /// First connection is a short, contextual path rather than a modal tour:
    /// explain the one Bluetooth-specific constraint, put the live picker right
    /// below it, and leave simulation as an equally visible optional branch.
    private var firstConnectionCard: some View {
        SlateCard {
            HStack(alignment: .top, spacing: Space.xl) {
                ZStack {
                    RadarPulse(diameter: 92, active: snapshot.phase.isBusy)
                    ChargerFigure(height: 52)
                }
                .frame(width: 100, height: 104)
                .background {
                    RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                        .fill(Palette.well.opacity(0.6))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                }

                VStack(alignment: .leading, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("连接第一台充电器")
                            .font(Typo.heading)
                            .foregroundStyle(Palette.textPrimary)
                        Text("无需先在 macOS 蓝牙设置里配对；Charker 会在下方列出附近设备。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .cjkParagraph(11, target: 1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Space.s) {
                        connectionStep(1, "给 Anker Prime 充电器通电")
                        connectionStep(2, "退出可能正在占用它的官方 Anker App")
                        connectionStep(3, "在下方选择带“充电器”标记的设备并点“连接”")
                    }

                    HStack(spacing: Space.s) {
                        Button {
                            model.browse()
                        } label: {
                            Label(
                                snapshot.isScanning ? "正在扫描…" : "扫描附近设备",
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                        }
                        .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                        .disabled(!snapshot.canBrowseNearbyDevices || snapshot.isScanning)

                        Button {
                            model.enterDemoMode()
                        } label: {
                            Label("体验模拟设备", systemImage: "play.fill")
                        }
                        .buttonStyle(CharkerActionButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func connectionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(verbatim: "\(number)")
                .font(.numeral(9, .semibold))
                .foregroundStyle(Palette.accentText)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.accentWash))
                .overlay {
                    Circle().strokeBorder(Palette.accent.opacity(0.32), lineWidth: Stroke.hairline)
                }
            Text(L10n.text(text))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The simulator is a real app state, not an unexplained mock peripheral.
    /// This banner names the boundary and keeps the way back visible before the
    /// device details and controls begin.
    private var demoModeCard: some View {
        SlateCard {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.accentWash))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("正在使用模拟设备")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                    Text("实时功率、端口操作和能耗记录均为模拟，不连接蓝牙，也不会写入真实历史。")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .cjkParagraph(11, target: 1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                Button("退出模拟") { model.exitDemoMode() }
                    .buttonStyle(CharkerActionButtonStyle())
            }
        }
    }

    // MARK: - Current connection

    private var currentCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.l) {
                currentCardHeader
                currentConnectionContent
                if let advertised = conflictingAdvertisedName {
                    advertisedNameNote(advertised)
                }
            }
            .padding(.bottom, Space.xxs)
            // Drives the advertised-name note's insertion; its .transition needs this.
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: conflictingAdvertisedName)
        }
        // The destructive action lives behind the trailing actions menu, but the
        // confirmation belongs to the stable card so closing the menu cannot
        // swallow its presentation on macOS.
        .confirmationDialog(
            L10n.text("忘记这台充电器？"),
            isPresented: $confirmingForget
        ) {
            Button("忘记", role: .destructive) { forgetCharger() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L10n.text(
                "会断开当前连接并清掉记住的设备，Charker 之后从头扫描附近的充电器。能耗历史、Anker 账号 ID、端口别名和菜单栏设置都会保留；官方 App 里的绑定关系不受影响。"
            ))
        }
    }

    private var currentCardHeader: some View {
        HStack(spacing: Space.m) {
            Text("当前连接")
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Space.m)
            Button { model.reconnect() } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CharkerActionButtonStyle())
            deviceActionsMenu
        }
    }

    /// Forget is necessary but rare and destructive. Keeping it in a compact
    /// overflow menu preserves access and confirmation without granting it an
    /// entire permanent row in the connection card.
    private var deviceActionsMenu: some View {
        Menu {
            Button("忘记这台充电器", role: .destructive) { confirmingForget = true }
                .disabled(snapshot.peripheralID == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.surfaceRaised))
                .overlay {
                    Circle().strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(snapshot.peripheralID == nil)
        .help(L10n.text("更多设备操作"))
        .accessibilityLabel(Text(L10n.text("更多设备操作")))
    }

    /// Hold the richer side-by-side instrument until its contents actually stop
    /// fitting. Width zero is the unmeasured first frame; defaulting that frame to
    /// wide avoids a compact-to-wide flash when the page first opens.
    @ViewBuilder
    private var currentConnectionContent: some View {
        if contentWidth == 0 || contentWidth >= Self.currentCardWideBreakpoint {
            HStack(alignment: .top, spacing: Space.xl) {
                currentDeviceStage(
                    height: 136,
                    minimumSurfaceHeight: currentConnectionDetailsHeight
                )
                    .frame(width: 176)
                currentConnectionDetails
                    .background {
                        GeometryReader { details in
                            Color.clear.preference(
                                key: CurrentConnectionDetailsHeightKey.self,
                                value: details.size.height
                            )
                        }
                    }
            }
            .onPreferenceChange(CurrentConnectionDetailsHeightKey.self) { measuredHeight in
                guard measuredHeight > 0 else { return }
                let height = ceil(measuredHeight)
                guard abs(height - currentConnectionDetailsHeight) > 0.5 else { return }
                currentConnectionDetailsHeight = height
            }
        } else {
            VStack(alignment: .leading, spacing: Space.l) {
                currentDeviceStage(height: 108)
                    .frame(maxWidth: .infinity)
                currentConnectionDetails
            }
        }
    }

    /// A bounded media well gives the product a real visual role without letting
    /// its transparent artwork create a large, unmeasured void in the card.
    private func currentDeviceStage(
        height: CGFloat,
        minimumSurfaceHeight: CGFloat? = nil
    ) -> some View {
        ProductStage(
            portWatts: A2687.Port.allCases.map { port in
                snapshot.telemetry?.port(port).map { $0.isOn ? $0.power : 0 } ?? 0
            },
            portsLit: A2687.Port.allCases.map {
                snapshot.telemetry?.port($0)?.isDelivering == true
            },
            totalFraction: (snapshot.totalPower ?? 0) / 160,
            active: snapshot.phase.isLive,
            height: height
        )
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

    private var currentConnectionDetails: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                // The device name can be any advertised string, Chinese included,
                // so it must not go through the rounded numeral face.
                Text(snapshot.displayName ?? "—")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                ConnectionLadder(phase: snapshot.phase)
            }
            currentMetadataPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Identity details are one object, so they share a quiet inset surface. The
    /// labels sit above their values rather than anchoring to opposite card edges;
    /// that keeps the eye inside each fact and survives longer translations.
    private var currentMetadataPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // This charger carries several unrelated version numbers, and
                // only one arrives over BLE. Naming the layer prevents this value
                // being compared with the official app's unrelated version.
                currentInfoCell(
                    "BLE 版本",
                    snapshot.deviceInfo.firmwareVersion ?? "—",
                    help: "充电器握手时报告的 BLE / 设备版本号。官方 App 显示的版本号属于另一套体系，两者不能直接比较。"
                )
                Rectangle()
                    .fill(Palette.stroke)
                    .frame(width: Stroke.hairline)
                    .padding(.vertical, Space.m)
                currentInfoCell(
                    "蓝牙地址",
                    snapshot.deviceInfo.macAddress ?? "—"
                )
            }
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: Stroke.hairline)
            serialRow
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

    /// The connected-device card is private, operational context: users need the
    /// full serial to compare it with the official app or a warranty record. The
    /// diagnostics export keeps its independent redaction boundary.
    private var serialRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L10n.text("序列号"))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            HStack(spacing: Space.s) {
                if let serial = snapshot.deviceInfo.serialNumber, !serial.isEmpty {
                    Text(serial)
                        .font(.numeral(12, .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .textSelection(.enabled)
                        .help(L10n.text("完整序列号；导出诊断时仍然隐藏"))
                    Spacer(minLength: Space.s)
                    Button {
                        copySerial(serial)
                    } label: {
                        serialCopyIcon(serialCopied ? "checkmark" : "doc.on.doc")
                    }
                    .help(L10n.text("复制完整序列号"))
                } else {
                    Text("—")
                        .font(.numeral(12, .medium))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
        }
        .padding(Space.m)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func serialCopyIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.accentText)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Palette.surfaceRaised))
            .overlay {
                Circle().strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
            }
            .contentShape(Circle())
    }

    /// Copies the unredacted serial. Redaction protects a screen and a log file,
    /// not the user's own clipboard — putting the masked form there would make
    /// the button pointless.
    private func copySerial(_ serial: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
        serialCopied = true
        copyGeneration &+= 1
        let generation = copyGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard generation == copyGeneration else { return }
            serialCopied = false
        }
    }

    /// The advertised local name and the `0x0029` a4 serial are the same string on
    /// this charger, so a disagreement means the info card is describing a device
    /// other than the one on the air. Comparison is loose on purpose: an
    /// advertisement may carry the shortened local name, and a prefix relation is
    /// not evidence of anything wrong.
    ///
    /// This wants to be a diagnostics WARN, but the log is private to ``AppModel``
    /// and reaching it from here would mean editing that file, so the finding is
    /// shown quietly instead.
    private var conflictingAdvertisedName: String? {
        // The demo fixture advertises ASHDJW-MOCK against a different mock serial,
        // and a warning about a device that does not exist is pure noise.
        guard !snapshot.isDemo else { return nil }
        guard let advertised = snapshot.advertisedName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !advertised.isEmpty,
              let serial = snapshot.deviceInfo.serialNumber, !serial.isEmpty
        else { return nil }
        let longer = advertised.count >= serial.count ? advertised : serial
        let shorter = advertised.count >= serial.count ? serial : advertised
        guard !longer.lowercased().hasPrefix(shorter.lowercased()) else { return nil }
        return advertised
    }

    private func advertisedNameNote(_ advertised: String) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textTertiary)
            Text(L10n.format("广播名 %@ 与序列号不一致", Redact.identifier(advertised)))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(L10n.text("这台充电器的广播名通常就是它的序列号。两者对不上时，握手读到的信息可能来自另一台设备。"))
        .transition(.opacity)
    }

    // MARK: - Device settings

    /// The charger's own settings, read at handshake time and written with the
    /// five commands verified on the owner's firmware v0.0.5.2.
    ///
    /// Two things about this card are not decoration.
    ///
    /// **It is a snapshot, not a reading.** These fields arrive with the
    /// handshake and then never move: turning the screen brightness from 80% to
    /// 50% on the charger's own display leaves `a9` untouched for the whole
    /// remaining session, and only a reconnect brings the new value. Verified
    /// twice on hardware. A user who just changed a setting has to be able to
    /// tell "one connection behind" from "Charker is wrong", so the card keeps
    /// the 上次连接时的值 chip and the reconnect button next to the title. What
    /// it no longer keeps is the paragraph that explained the handshake: the
    /// chip plus the button already say everything the user can act on, and the
    /// mechanism behind them is our problem, not theirs.
    ///
    /// Each display write requires an ACK, then Charker reconnects and compares
    /// the new `A8`/`A9`/`AF`/`B2` snapshot. Language is labelled more weakly:
    /// its command is confirmed, but no language read-back field exists.
    private var deviceSettingsCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Text("设备设置")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Chip(text: L10n.text("上次连接时的值"), tone: .neutral)
                        // The one consequence worth stating, and only on hover:
                        // a value the user just changed may not be here yet.
                        .help(L10n.text("在充电器上改过设置后，重新连接才会更新。"))
                    Spacer(minLength: Space.s)
                    Button("重新连接以刷新") { model.reconnect() }
                        .buttonStyle(GhostButtonStyle())
                }
                displaySettingsRows
                if let note = chargerSettingNote {
                    settingNote(note)
                }
                Divider().overlay(Palette.stroke)
                chargingModeRow
            }
            .padding(.bottom, Space.xxs)
        }
    }

    // MARK: - Model screen

    /// The same sheet configures Charker's 3D model and can push the selected
    /// artwork to the physical charger, so the entry belongs beside the rest of
    /// the charger's display settings rather than under app-wide Advanced options.
    private var modelScreenCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.m) {
                    Text("模型屏保")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: Space.m)
                    Button("设置…") {
                        showsScreenSettings = true
                    }
                    .buttonStyle(CharkerActionButtonStyle())
                    .accessibilityLabel(Text("设置模型屏保"))
                }

                HStack(spacing: Space.m) {
                    modelScreenThumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(modelScreenTitle)
                            .font(Typo.body)
                            .foregroundStyle(Palette.textPrimary)
                        Text(modelScreenSubtitle)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: Space.m)
                }

                Text("这里换的是 Charker 中三维模型的顶屏画面。同一张图也能经蓝牙推到实体充电器自己的屏幕上，推送前会单独确认一次。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .cjkParagraph(11, target: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelScreenImage: NSImage {
        if model.preferences.modelScreenStyle == .custom,
           let custom = model.modelScreenCustomImage {
            return custom
        }
        return ModelScreenArtwork.ankerPrimeTexture
    }

    private var modelScreenTitle: String {
        guard let selected = model.selectedModelScreenArtwork,
              let index = model.modelScreenArtworks.firstIndex(where: { $0.id == selected.id }) else {
            return "Anker Prime"
        }
        return L10n.format("自定义屏保 %d", index + 1)
    }

    private var modelScreenSubtitle: String {
        guard model.selectedModelScreenArtwork != nil else {
            return L10n.text("默认品牌待机画面")
        }
        return L10n.format("已保存 %d / 3", model.modelScreenArtworks.count)
    }

    private var modelScreenThumbnail: some View {
        ZStack {
            Color.black
            ModelScreenSquare(image: modelScreenImage, side: 64)
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var displaySettingsRows: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            languageRow
            timeoutRow
            brightnessRow
            gyroscopeRow
            orientationRow
            Text(L10n.text("手动选择屏幕方向会暂时接管自动旋转；充电器重新通电后会恢复陀螺仪控制。"))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .cjkParagraph(11, target: 1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageRow: some View {
        HStack {
            Text(L10n.text("设备语言"))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Menu {
                ForEach(DeviceLanguage.allCases, id: \.rawValue) { language in
                    Button(Self.languageLabel(language)) {
                        model.setChargerSetting(.language(language))
                    }
                }
            } label: {
                settingMenuLabel(languageMenuText)
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(GhostButtonStyle())
            .fixedSize()
            .disabled(displayControlsDisabled)
            .help(model.chargerSettingBlocker
                  ?? L10n.text("语言没有可读取的设置字段，写入后请以充电器屏幕为准。"))
        }
    }

    private var timeoutRow: some View {
        HStack {
            Text(L10n.text("自动锁屏"))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if displayedTimeout == nil {
                Text("—").font(Typo.label).foregroundStyle(Palette.textPrimary)
            } else {
                Menu {
                    ForEach(ScreenTimeout.allCases, id: \.rawValue) { timeout in
                        Button {
                            model.setChargerSetting(.screenTimeout(timeout))
                        } label: {
                            if displayedTimeout == timeout {
                                Label(Self.timeoutLabel(timeout), systemImage: "checkmark")
                            } else {
                                Text(Self.timeoutLabel(timeout))
                            }
                        }
                        .disabled(displayedTimeout == timeout)
                    }
                } label: {
                    settingMenuLabel(Self.timeoutLabel(displayedTimeout!))
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(GhostButtonStyle())
                .fixedSize()
                .disabled(displayControlsDisabled)
            }
        }
    }

    private var brightnessRow: some View {
        HStack(spacing: Space.m) {
            Text(L10n.text("屏幕亮度"))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            Slider(
                value: $brightnessDraft,
                in: 25...100,
                step: 1,
                onEditingChanged: { brightnessEditing = $0 }
            )
            .frame(minWidth: 150)
            .disabled(displayControlsDisabled || currentBrightness == nil)
            .accessibilityLabel(Text(L10n.text("屏幕亮度")))
            Text("\(brightnessPercent)%")
                .font(.numeral(12, .medium))
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Button("应用") {
                model.setChargerSetting(.brightness(UInt8(brightnessPercent)))
            }
            .buttonStyle(CharkerActionButtonStyle(emphasis: .secondary))
            .disabled(displayControlsDisabled || currentBrightness == nil || !brightnessChanged)
        }
        .help(model.chargerSettingBlocker
              ?? L10n.text("固件会把低于 25% 的值自动调整为 25%，所以滑杆从 25% 开始。"))
    }

    private var gyroscopeRow: some View {
        HStack {
            Text(L10n.text("自动旋转"))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if displayedGyroscope == nil {
                Text("—").font(Typo.label).foregroundStyle(Palette.textPrimary)
            } else {
                Toggle("", isOn: Binding(
                    get: { displayedGyroscope ?? false },
                    set: { model.setChargerSetting(.gyroscope($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(displayControlsDisabled)
                .accessibilityLabel(Text(L10n.text("自动旋转")))
            }
        }
    }

    private var orientationRow: some View {
        HStack {
            Text(L10n.text("屏幕方向"))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if displayedOrientation == nil {
                Text("—").font(Typo.label).foregroundStyle(Palette.textPrimary)
            } else {
                Menu {
                    ForEach(ScreenOrientation.allCases, id: \.rawValue) { orientation in
                        Button {
                            model.setChargerSetting(.orientation(orientation))
                        } label: {
                            if displayedOrientation == orientation {
                                Label(Self.orientationLabel(orientation), systemImage: "checkmark")
                            } else {
                                Text(Self.orientationLabel(orientation))
                            }
                        }
                        .disabled(displayedOrientation == orientation)
                    }
                } label: {
                    settingMenuLabel(Self.orientationLabel(displayedOrientation!))
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(GhostButtonStyle())
                .fixedSize()
                .disabled(displayControlsDisabled)
            }
        }
    }

    private func settingMenuLabel(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(text).font(Typo.label)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var currentBrightness: UInt8? {
        snapshot.telemetry?.settings?.screenBrightness
    }

    private var brightnessPercent: Int {
        min(100, max(25, Int(brightnessDraft.rounded())))
    }

    private var brightnessChanged: Bool {
        currentBrightness.map { Int($0) } != brightnessPercent
    }

    private func syncBrightnessDraft(_ brightness: UInt8?) {
        guard !brightnessEditing, let brightness else { return }
        brightnessDraft = Double(min(100, max(25, brightness)))
    }

    private var displayControlsDisabled: Bool {
        model.chargerSettingBlocker != nil
            || model.isChangingChargerSetting
            || model.chargingModeChange?.outcome == .sending
    }

    private var pendingChargerSetting: ChargerSetting? {
        guard let change = model.chargerSettingChange,
              change.outcome == .sending || change.outcome == .reconnecting else { return nil }
        return change.setting
    }

    private var languageMenuText: String {
        if case .language(let language)? = pendingChargerSetting {
            return Self.languageLabel(language)
        }
        return L10n.text("选择…")
    }

    private var displayedTimeout: ScreenTimeout? {
        if case .screenTimeout(let timeout)? = pendingChargerSetting { return timeout }
        guard let raw = snapshot.telemetry?.settings?.screenTimeout else { return nil }
        return ScreenTimeout(rawValue: raw)
    }

    private var displayedOrientation: ScreenOrientation? {
        if case .orientation(let orientation)? = pendingChargerSetting { return orientation }
        guard let raw = snapshot.telemetry?.settings?.screenOrientation else { return nil }
        return ScreenOrientation(rawValue: raw)
    }

    private var displayedGyroscope: Bool? {
        if case .gyroscope(let enabled)? = pendingChargerSetting { return enabled }
        return snapshot.telemetry?.settings?.gyroscopeEnabled
    }

    private var chargerSettingNote: (text: String, tone: Color)? {
        if let change = model.chargerSettingChange {
            let summary = Self.settingSummary(change.setting)
            switch change.outcome {
            case .sending:
                return (L10n.format("正在写入「%@」…", summary), Palette.textSecondary)
            case .reconnecting:
                return (
                    L10n.format("充电器已接受「%@」，正在重新连接并回读…", summary),
                    Palette.textSecondary
                )
            case .confirmed:
                return (
                    L10n.format("「%@」已写入，并通过重新连接回读确认。", summary),
                    Palette.okText
                )
            case .accepted:
                return (
                    L10n.format("充电器已接受「%@」。这个设置没有可读取的回读字段。", summary),
                    Palette.okText
                )
            case .unconfirmed:
                return (
                    L10n.format("充电器已接受「%@」，但重新连接后的值没有确认变化；请先查看设备，不要连续重试。", summary),
                    Palette.warnText
                )
            case .failed(let reason):
                return (reason, Palette.dangerText)
            }
        }
        if let blocker = model.chargerSettingBlocker {
            return (blocker, Palette.textTertiary)
        }
        return nil
    }

    private func settingNote(_ note: (text: String, tone: Color)) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if model.isChangingChargerSetting {
                ProgressView().controlSize(.small)
            }
            Text(note.text)
                .font(Typo.caption)
                .foregroundStyle(note.tone)
                .cjkParagraph(11, target: 1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .transition(.opacity)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: note.text)
    }

    private static func languageLabel(_ language: DeviceLanguage) -> String {
        switch language {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        case .german: return "Deutsch"
        }
    }

    private static func timeoutLabel(_ timeout: ScreenTimeout) -> String {
        switch timeout {
        case .thirtySeconds: return L10n.text("30 秒")
        case .oneMinute: return L10n.text("1 分钟")
        case .fiveMinutes: return L10n.text("5 分钟")
        case .thirtyMinutes: return L10n.text("30 分钟")
        case .twelveHours: return L10n.text("12 小时")
        }
    }

    private static func orientationLabel(_ orientation: ScreenOrientation) -> String {
        switch orientation {
        case .up: return L10n.text("向上")
        case .left: return L10n.text("向左")
        case .down: return L10n.text("向下")
        case .right: return L10n.text("向右")
        }
    }

    private static func settingSummary(_ setting: ChargerSetting) -> String {
        switch setting {
        case .language(let language):
            return L10n.format("设备语言：%@", languageLabel(language))
        case .screenTimeout(let timeout):
            return L10n.format("自动锁屏：%@", timeoutLabel(timeout))
        case .brightness(let percent):
            return L10n.format("屏幕亮度：%d%%", Int(percent))
        case .orientation(let orientation):
            return L10n.format("屏幕方向：%@", orientationLabel(orientation))
        case .gyroscope(let enabled):
            return L10n.format("自动旋转：%@", enabled ? L10n.text("开") : L10n.text("关"))
        }
    }

    private var chargingModeText: String {
        guard let mode = snapshot.telemetry?.settings?.chargingMode else { return "—" }
        return Self.chargingModeLabel(mode)
    }

    /// The one row on this card that writes back.
    ///
    /// Laid out as a value that happens to be a control rather than as a switch
    /// with a label: the mode is a reading first, and it stays a reading in the
    /// two situations — demo mode, no link — where nothing can be sent.
    ///
    /// The single line underneath carries whichever one thing is worth saying
    /// right now; see ``chargingModeNote``.
    private var chargingModeRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(L10n.text("充电模式"))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if isSwitchingChargingMode {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
                if snapshot.telemetry?.settings?.chargingMode == nil {
                    // Nothing has been read, so there is no value to offer
                    // alternatives to. A menu here would invite a write against
                    // a charger whose current mode we cannot even name.
                    Text(chargingModeText)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                } else {
                    chargingModePicker
                }
            }
            if let note = chargingModeNote {
                HStack(alignment: .top, spacing: Space.xs) {
                    Text(note.text)
                        .font(Typo.caption)
                        .foregroundStyle(note.tone)
                        .cjkParagraph(11, target: 1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: chargingModeNote?.text)
        .animation(Motion.reduced(Motion.value, reduceMotion), value: isSwitchingChargingMode)
    }

    private var isSwitchingChargingMode: Bool {
        model.chargingModeChange?.outcome == .sending
    }

    /// The modes the picker offers, in the order the official app lists them.
    /// ``ChargingMode/unknown(_:)`` is deliberately not among them: a code
    /// nobody can name is not a meaningful user choice.
    private static let offeredChargingModes: [ChargingMode] = [.ai, .standard, .custom]

    /// The three modes, with the third one held apart.
    ///
    /// ``ChargingMode/isObservedOnHardware`` is what draws the line: two of
    /// these codes have been seen on this charger and the third comes out of the
    /// official app's enum and nowhere else. Offering all three in one flat list
    /// would present that third as being as good as the other two. It is still
    /// offered — a probe somebody may well want to run, and it costs nothing to
    /// undo — but under a heading that says what picking it may get you.
    private var chargingModePicker: some View {
        Menu {
            Section {
                ForEach(Self.offeredChargingModes.filter(\.isObservedOnHardware), id: \.code) {
                    chargingModeItem($0)
                }
            }
            Section(L10n.text("可能不生效，切回来就行")) {
                ForEach(Self.offeredChargingModes.filter { !$0.isObservedOnHardware }, id: \.code) {
                    chargingModeItem($0)
                }
            }
        } label: {
            // The chevrons are the whole difference between a value and a
            // control. Every other row on this card is a reading, so without
            // them this one reads as one too, and the modes stay undiscovered.
            HStack(spacing: Space.xs) {
                Text(chargingModeText).font(Typo.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(GhostButtonStyle())
        .fixedSize()
        .disabled(
            model.chargingModeBlocker != nil || isSwitchingChargingMode
                || model.isChangingChargerSetting
        )
        .help(model.chargingModeBlocker
              ?? L10n.text("切换会让充电器重新分配各口的功率，正在充电的设备可能会瞬断一下。"))
        .accessibilityLabel(Text(L10n.text("充电模式")))
        .accessibilityValue(Text(chargingModeText))
    }

    private func chargingModeItem(_ mode: ChargingMode) -> some View {
        Button {
            model.setChargingMode(mode)
        } label: {
            if snapshot.telemetry?.settings?.chargingMode == mode.code {
                Label(Self.chargingModeLabel(mode), systemImage: "checkmark")
            } else {
                Text(Self.chargingModeLabel(mode))
            }
        }
    }

    /// One line under the row, and only ever one.
    ///
    /// What just happened outranks what could happen, and a picker nobody can
    /// use outranks the consequence of using it. The bottom of the list is the
    /// sentence the user needs *before* the tap — a mode change re-negotiates
    /// the charger's allocation, and a phone already drawing power can blink —
    /// which is why it is a line on the card and not a dialog: the switch is
    /// undone by switching back, and a modal for that would cry wolf on the one
    /// panel this app keeps for writes that cannot be undone.
    private var chargingModeNote: (text: String, tone: Color)? {
        if let change = model.chargingModeChange {
            let mode = Self.chargingModeLabel(change.mode)
            switch change.outcome {
            case .sending:
                return (L10n.format("正在切到「%@」…", mode), Palette.textSecondary)
            case .confirmed:
                return (L10n.format("已经切到「%@」", mode), Palette.okText)
            // Not 「失败」, and not 「成功」 either. The command went out; this
            // firmware's settings field is a handshake snapshot and may simply
            // not move until the next one, so the only honest report is that
            // this connection cannot show the answer — and where the answer will
            // appear.
            case .unconfirmed:
                return (
                    L10n.format("「%@」已经发给充电器了，这次连接里还看不到变化。重新连接后再看这一行。", mode),
                    Palette.warnText
                )
            case .failed(let reason):
                return (reason, Palette.dangerText)
            }
        }
        if let blocker = model.chargingModeBlocker { return (blocker, Palette.textTertiary) }
        // No mode has been read, so there is no picker either, and a line about
        // what switching costs would be describing a control that is not there.
        guard snapshot.telemetry?.settings?.chargingMode != nil else { return nil }
        return (
            L10n.text("切换会让充电器重新分配各口的功率，正在充电的设备可能会瞬断一下。"),
            Palette.textTertiary
        )
    }

    /// `aa`, matched against the official app's enum: switching AI 模式 2.0 →
    /// 标准模式 moved it from 0 to 1, and 4 is the app's custom mode.
    ///
    /// Anything else prints its raw byte. The gap at 2 and 3 has never been
    /// observed on this unit and nothing says what would live there, so a
    /// plausible-sounding name would be an invention presented as a reading. The
    /// fallback is intentionally the same untranslated string in both languages:
    /// it is a hex dump for a bug report, not copy.
    ///
    /// Generic over the integer width on purpose: the field is a single byte on
    /// the wire, but whether the decoder surfaces it as `UInt8` or widens it to
    /// `Int` is its business, not this view's.
    /// Same names on the write side as on the read side. A menu item that said
    /// anything other than what the row will say once the charger agrees would
    /// leave the user unable to tell whether the switch took.
    private static func chargingModeLabel(_ mode: ChargingMode) -> String {
        chargingModeLabel(mode.code)
    }

    private static func chargingModeLabel(_ raw: some BinaryInteger) -> String {
        switch raw {
        case 0: return L10n.text("AI 模式 2.0")
        case 1: return L10n.text("标准模式")
        case 4: return L10n.text("自定义模式")
        default: return String(format: "Unknown (0x%02X)", Int(raw))
        }
    }

    // MARK: - Forget

    /// Local forget, in the only order that actually sticks.
    ///
    /// ``ChargerSession/forgetDevice()`` alone would not do it: it clears the
    /// snapshot but neither drops the link nor touches the stored id, so the very
    /// next publish writes the id straight back and the connected charger stays
    /// remembered. Tearing the session down first stops that write-back — and
    /// `stop()` closes the running energy segment through the normal save path,
    /// so history is finished, never discarded. Restarting afterwards leaves the
    /// user on a live scan instead of a dead screen.
    ///
    /// The closing `browse()` is load-bearing, not cosmetic: it is the call that
    /// latches the transport's `autoConnect` off. Lose it and the fresh session
    /// walks straight back onto the charger that was just forgotten and
    /// `AppModel.apply` writes its id into preferences again — the forget
    /// silently undoes itself, and the device list sits empty while it happens.
    /// But a brand-new ``ChargerSession`` starts out `stopped`, and its
    /// `browse()` is a `guard !stopped else { return }` no-op, so the call has to
    /// land *after* `start()`. ``AppModel`` hands `start()` and `browse()` to two
    /// separate unstructured `Task`s, and nothing promises the order in which
    /// those reach the session actor — hence the explicit gate instead of two
    /// calls in a row.
    ///
    /// This is a holding shape. The sequencing belongs in ``AppModel``, which owns
    /// the session and could simply `await` the steps inside one task; that file
    /// is not this change's to edit.
    ///
    /// The store is instantiated here rather than reached through ``AppModel``,
    /// whose own is private; both sit on the same `UserDefaults`, and `App.swift`
    /// already reads preferences this way at launch.
    private func forgetCharger() {
        model.stop()
        PreferencesStore().peripheralID = nil
        model.start()
        Task { @MainActor in
            await awaitRebuiltSession()
            model.browse()
        }
    }

    /// Waits until a snapshot from the *rebuilt* session has reached the model,
    /// which is the only thing observable from here that proves
    /// `ChargerSession.start()` has already run and cleared `stopped`.
    ///
    /// Both halves of the predicate are needed. `peripheralID == nil` rejects the
    /// stale snapshot the torn-down session left behind — the forget button is
    /// disabled unless that id is set — and `phase != .idle` rejects the new
    /// session's initial `updates()` yield, which is emitted on subscription and
    /// can therefore precede `start()`. Every phase past `.idle` can only come
    /// from `start()` or later, `.bluetoothUnavailable` and `.failed` included.
    ///
    /// The tick budget is a backstop, not a timing assumption: if the rebuild
    /// never reports, the browse still goes out rather than the task hanging
    /// around forever.
    private func awaitRebuiltSession() async {
        // ~2 s of 20 ms ticks.
        for _ in 0..<100 {
            let current = model.snapshot
            if current.peripheralID == nil, current.phase != .idle { return }
            guard (try? await Task.sleep(for: .milliseconds(20))) != nil else { return }
        }
    }

    // MARK: - Account

    /// Hardened firmware only streams to the account that owns the charger, so this
    /// field is the difference between a working app and a silent one. It is an
    /// account identifier, not a password — the app never sends it anywhere except
    /// to the charger over the local Bluetooth link.
    private var accountCard: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Text("Anker 账号 ID")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    if model.snapshot.authRejected {
                        // Some firmware keeps streaming after refusing the
                        // identity step; a scary chip next to live numbers would
                        // make the app contradict itself.
                        Chip(
                            text: L10n.text(authRejectedButReading ? "只读模式" : "身份被拒"),
                            tone: .warn
                        )
                    } else if PreferencesStore.isValidOwnerUserID(model.preferences.ownerUserID) {
                        Chip(text: L10n.text("已填写"), tone: .ok)
                    }
                }

                if model.snapshot.authRejected {
                    HStack(alignment: .top, spacing: Space.s) {
                        Image(systemName: authRejectedButReading
                              ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.warn)
                        Text(L10n.text(authRejectedButReading
                             ? "充电器拒绝了当前的账号身份，但仍在正常推送数据，监控不受影响。需要端口开关等控制功能时，再填写绑定这台充电器的账号 ID。"
                             : "充电器拒绝了当前的账号身份，不再返回数据。请确认填写的是绑定这台充电器的那个账号。"))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .cjkParagraph(11, target: 1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    .transition(.opacity)
                }

                Text(L10n.text(
                    "这台充电器的固件只向绑定它的那个 Anker 账号推送数据。这个 ID 是账号身份，不是密码。"
                ))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .cjkParagraph(11, target: 1.55)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.s) {
                    Button {
                        model.clearSignInError()
                        signingIn = true
                    } label: {
                        Label("用 Anker 账号获取", systemImage: "person.badge.key")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))

                    if let nickname = model.accountNickname {
                        Text(nickname).font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                }

                DisclosureGroup("或手动填写") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        TextField("40 位小写十六进制", text: $ownerDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.numeral(12, .regular))
                            .onSubmit(commitOwnerDraft)
                            .onChange(of: ownerDraft) { _, value in
                                // Commit silently the moment the id becomes valid;
                                // half-typed ids stay local.
                                if PreferencesStore.isValidOwnerUserID(value) {
                                    commitOwnerDraft()
                                }
                            }

                        if !ownerDraft.isEmpty, !PreferencesStore.isValidOwnerUserID(ownerDraft) {
                            Text("格式不对：应为 40 个字符的十六进制字符串。")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.warnText)
                                .transition(.opacity)
                        }

                        Text(L10n.text("不想在这里登录的话，也可以自己取：安卓端用 Frida 抓 MQTT 主题 dt/anker_power/<40位hex>，或在未加密的 iOS 备份里 grep 同样的主题。"))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .cjkParagraph(11, target: 1.55)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Space.s)
                    // Drives the format-error row's transition while typing.
                    .animation(
                        Motion.reduced(Motion.ui, reduceMotion),
                        value: !ownerDraft.isEmpty && !PreferencesStore.isValidOwnerUserID(ownerDraft)
                    )
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            }
            .padding(.bottom, Space.xxs)
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: model.snapshot.authRejected)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: authRejectedButReading)
    }

    /// Identity refused, yet telemetry is flowing anyway — true on firmware that
    /// only gates writes. The rejection is a fact; "it will go silent" is not.
    private var authRejectedButReading: Bool {
        snapshot.authRejected && snapshot.phase.isLive && snapshot.telemetry != nil
    }

    private func commitOwnerDraft() {
        let normalized = ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard model.preferences.ownerUserID != normalized else { return }
        model.preferences.ownerUserID = normalized
    }

    // MARK: - Nearby

    private var nearbyCard: some View {
        let devices = snapshot.sortedNearbyDevices
        return SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Text("附近的蓝牙设备")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    if snapshot.isScanning {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.accent)
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button("重新扫描") { model.browse() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(!snapshot.canBrowseNearbyDevices || snapshot.isScanning)
                }
                .animation(.easeOut(duration: 0.2), value: snapshot.isScanning)

                if let hint = snapshot.scanHint {
                    HStack(alignment: .top, spacing: Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.warn)
                        Text(hint)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .cjkParagraph(11, target: 1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }

                if devices.isEmpty {
                    Text("尚未发现设备。请确认充电器已通电，且官方 Anker App 没有连着它。")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .cjkParagraph(11, target: 1.5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: Space.xs) {
                            ForEach(devices) { device in
                                DeviceRow(
                                    device: device,
                                    isCurrent: device.id == snapshot.peripheralID,
                                    preferredName: device.id == snapshot.peripheralID
                                        ? snapshot.displayName
                                        : nil,
                                    connect: { model.connect(to: device.id) }
                                )
                                .transition(
                                    .opacity.combined(with: .offset(y: reduceMotion ? 0 : 4))
                                )
                            }
                        }
                        .padding(.trailing, Space.xs)
                    }
                    .frame(height: Self.nearbyListHeight(deviceCount: devices.count))
                    .scrollIndicators(.automatic)
                    .clipped()
                    .animation(
                        Motion.reduced(Motion.ui, reduceMotion),
                        value: devices.map(\.id)
                    )
                }
            }
            .padding(.bottom, Space.xxs)
            // Drives the scan-hint row's insertion; its .transition needs this.
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: snapshot.scanHint)
        }
    }

    private func currentInfoCell(
        _ label: String, _ value: String, help: String? = nil, numeric: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(numeric ? .numeral(12, .medium) : Typo.label)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .textSelection(.enabled)
                .help(help.map { L10n.text($0) } ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
    }
}

private struct DeviceRow: View {
    let device: DiscoveredCharger
    let isCurrent: Bool
    /// The encrypted handshake knows the product name; CoreBluetooth's cached
    /// peripheral name may only be the charger's serial after a system retrieval.
    let preferredName: String?
    let connect: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.m) {
            signal
            VStack(alignment: .leading, spacing: 1) {
                Text(preferredName ?? device.displayName)
                    .font(Typo.body)
                    .foregroundStyle(device.isCandidate ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: device.rssi)
            }
            Spacer(minLength: Space.s)
            if isCurrent {
                Chip(text: L10n.text("已连接"), tone: .ok)
            } else {
                if device.isCandidate {
                    Chip(text: L10n.text("充电器"), tone: .accent)
                }
                Button("连接", action: connect)
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .fill(hovering ? Palette.surfaceRaised : .clear)
        )
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
    }

    private var subtitle: String {
        var parts: [String] = []
        if device.hasMeasuredRSSI { parts.append("\(device.rssi) dBm") }
        if !device.serviceUUIDs.isEmpty {
            parts.append(device.serviceUUIDs.prefix(2).joined(separator: " "))
        }
        if !device.matchReasons.isEmpty {
            parts.append(device.matchReasons.map(\.chineseLabel).joined(separator: " · "))
        }
        if parts.isEmpty { parts.append(L10n.text("信号强度未报告")) }
        return parts.joined(separator: "  ")
    }

    private var signal: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(bar <= device.signalBars ? Palette.accent : Palette.idle.opacity(0.3))
                    .frame(width: 2.5, height: CGFloat(bar) * 3)
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
        .animation(.easeOut(duration: 0.3), value: device.signalBars)
    }
}

extension MatchReason {
    var chineseLabel: String {
        switch self {
        case .advertisedService: return L10n.text("广播服务")
        case .serviceData: return L10n.text("服务数据")
        case .overflowService: return L10n.text("溢出服务")
        case .productType: return L10n.text("产品型号")
        case .namePrefix: return L10n.text("名称")
        case .systemConnected: return L10n.text("系统已连")
        case .remembered: return L10n.text("已记住")
        }
    }
}
