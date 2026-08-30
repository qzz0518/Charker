import A2687Protocol
import AppKit
import CharkerCore
import SwiftUI

/// 同步屏保 — the second tier of 模型屏保, and the only surface in the app that
/// writes pixels into the charger.
///
/// The two tiers share one source image, one ``ModelScreenCrop`` and one
/// ``ModelScreenVignette``:
/// ``ModelScreenArtwork/customTexture(from:crop:vignette:)`` renders the 960×400
/// strip the 3D model wears,
/// ``ModelScreenArtwork/deviceCoverJPEG(from:crop:vignette:quality:)`` renders the
/// 240×240 JPEG the panel wants. Same picture, same crop, same ring, two products
/// — so the framing dragged into place on the model is the framing the hardware
/// receives. The official app cannot do that; it pushes and then looks
/// at the charger to find out what it did.
///
/// Three things this view exists to say out loud, none of which the protocol
/// layer can say for itself:
///
/// 1. **The write cannot be undone.** No BLE command erases a cover — the
///    official app's delete goes through Anker's cloud. The confirm panel is the
///    only honest source of `acknowledgedIrreversible: true` in this app, and it
///    is shown *before* the first `0x021F`, never as a footnote under a bar.
/// 2. **Finishing is not the same as being seen to work.** ``CoverVerification``
///    is switched over rather than flattened into "done": 「像素都发完了」 and
///    「屏幕确实换了」 are different claims and get different cards.
/// 3. **Failures differ in what is now inside the charger.** Four remedies, from
///    「一个字节都没写进去」 to 「图全在里面，只有最后一步没生效」.
/// 4. **Evidence is not the message.** The `0xE1` ids either side of the push,
///    the slice count and the byte count are how *we* know the screen changed;
///    to the person reading the card they are noise, and a result that arrives
///    with its working attached reads as a result that is not sure of itself.
///    They go to the diagnostics log instead — see `AppModel.finishCoverPush` —
///    so a bug report still carries the one comparison that separates 「真的换了」
///    from 「固件只是应答了」. The failure cards obey the same rule, and took
///    longer to: they printed 「等第 47 片的回执超时」 straight from the protocol
///    layer for a while. The slice index, the status byte and the cover id now
///    leave through ``CoverTransferError/diagnostic``, and what stays on the
///    card is what is inside the charger and what to do about it.
struct CoverSyncSection: View {
    @ObservedObject var model: AppModel
    /// The custom screen this tier acts on, or nil when 模型屏保 is sitting on the
    /// Anker Prime default — there is no user picture to push then.
    let artwork: ModelScreenArtworkItem?

    @State private var isConfirming = false
    @State private var acknowledged = false
    @State private var preview: DeviceCoverPreview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("同步屏保")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s)
                Text("充电器实体屏")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.well))
            }

            card
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                        .fill(Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: 1)
                        .allowsHitTesting(false)
                )
        }
        .task(id: previewKey) { preview = Self.makePreview(for: artwork) }
        .onChange(of: artwork?.id) { _, _ in
            // Switching thumbnails mid-confirmation must not carry the tick over
            // to a different picture: the sentence was agreed to about one image.
            isConfirming = false
            acknowledged = false
        }
        // Animated on which card is showing, not on what is inside it.
        // Animating the whole state cross-fades the percentage eight times a
        // second, and a number caught mid-dissolve reads as a rendering fault.
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: cardIdentity)
    }

    /// Which of the six cards the section is currently showing.
    private var cardIdentity: Int {
        switch model.coverPush.phase {
        case .idle: return isConfirming ? 1 : 0
        case .running: return 2
        case .done: return 3
        case .failed: return 4
        case .reselected: return 5
        }
    }

    // MARK: - The card, one state at a time

    @ViewBuilder
    private var card: some View {
        switch model.coverPush.phase {
        case .idle:
            if isConfirming { confirmCard } else { idleCard }
        case .running(let progress):
            runningCard(progress)
        case .done(let outcome):
            doneCard(outcome)
        case .failed(let failure):
            failedCard(failure)
        case .reselected:
            reselectedCard
        }
    }

    // MARK: Idle

    @ViewBuilder
    private var idleCard: some View {
        if artwork == nil {
            hint(
                symbol: "photo.on.rectangle.angled",
                title: L10n.text("同步屏保推的是你自己的图"),
                detail: L10n.text("先在上面选一张自定义屏保。")
            )
        } else if artwork?.sourceImage == nil {
            hint(
                symbol: "exclamationmark.triangle.fill",
                title: L10n.text("这张屏保没有原图"),
                detail: L10n.text("它是旧版本存下的模型贴图，生成不出充电器要的方图。重新导入一次就能推。"),
                tint: Palette.warnText
            )
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .top, spacing: Space.m) {
                    devicePreview
                    VStack(alignment: .leading, spacing: 3) {
                        Text("把同一张图、同一处裁剪推到充电器自己的屏幕上。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let preview {
                            Text(verbatim: Self.durationHint(preview))
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let blocker = model.coverPushBlocker {
                    Label(blocker, systemImage: "lock.fill")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Space.s) {
                    Button("推送到充电器…") {
                        acknowledged = false
                        isConfirming = true
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                    .disabled(model.coverPushBlocker != nil || preview == nil)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Confirm — the gate

    /// Everything `acknowledgedIrreversible` stands for, in the order it matters.
    ///
    /// Deliberately a panel and not an alert: the checkbox is the record that the
    /// sentence was read, and the primary button stays dead until it is ticked.
    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label {
                Text("这一步撤不回来")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warn)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("写进充电器的封面没有任何删除命令，只能被之后的推送挤掉。")
                // 「别人的机器上观测到过两次，这台没验过」 was our confidence, not
                // the reader's decision: what they consent to is a slot being
                // spent and one of the four going, and which one is unknown.
                // How well we know that belongs in the source, and it is here.
                Text("机内固定 4 个位置。推第 5 张会挤掉其中一张，不确定是哪一张。")
                Text("官方 App 的「删除」走的是 Anker 云端，蓝牙上没有这条命令。")
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $acknowledged) {
                Text("我知道推上去的图删不掉")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textPrimary)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: Space.s) {
                Button("开始推送") {
                    guard let slot = artwork?.id else { return }
                    isConfirming = false
                    // The one place in the app that passes true. It is a claim
                    // about the three lines above having been on screen and
                    // ticked, not a formality — see `AppModel.pushCoverToDevice`.
                    model.pushCoverToDevice(slot: slot, acknowledgedIrreversible: acknowledged)
                }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .destructive))
                .disabled(!acknowledged || artwork == nil)

                Button("取消") {
                    isConfirming = false
                    acknowledged = false
                }
                .buttonStyle(CharkerActionButtonStyle())
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Running

    private func runningCard(_ progress: CoverTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(Self.stageLabel(progress))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Space.s)
                if progress.chunkCount > 0 {
                    Text(verbatim: "\(Int((progress.fraction * 100).rounded()))%")
                        .font(.numeral(11, .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }
            }

            if progress.chunkCount > 0 {
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
            } else {
                // A lone `0x021F` — ``AppModel/retryCoverSelection()`` — has no
                // slices, so there is no fraction to draw and nothing the cancel
                // button could honestly interrupt: it is one frame and a read.
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
            }

            otherScreenNote

            if progress.chunkCount > 0 {
                // The point survives without the word 「片」: cancelling is not an
                // undo, and that is the only part of it the user acts on.
                Text("取消撤不回已经写进去的部分。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.s) {
                    Button(model.coverPush.isStopping ? "正在停…" : "取消") {
                        model.cancelCoverPush()
                    }
                    .buttonStyle(CharkerActionButtonStyle())
                    .disabled(model.coverPush.isStopping)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Done

    /// Both halves of ``CoverVerification`` still get their own card — the enum
    /// makes that a compile-time obligation and this is where it is paid: 「完成」
    /// alone would let a push that changed nothing look exactly like one that
    /// worked.
    ///
    /// What the cards no longer do is show their working. The two `0xE1` ids are
    /// the proof, not the news; a success that arrives with a pair of five-digit
    /// numbers under it invites the reader to audit us instead of to close the
    /// panel. So the confirmed case is one line, and the two unconfirmed ones
    /// spend their second line on the only move that settles it — look at the
    /// charger — rather than on the numbers that could not.
    private func doneCard(_ outcome: CoverTransferOutcome) -> some View {
        let heading: (symbol: String, tint: Color, title: String, detail: String?)
        switch outcome.verification {
        case .witnessed:
            heading = (
                "checkmark.circle.fill",
                Palette.ok,
                L10n.text("屏幕换过来了"),
                nil
            )
        case .inconclusive(.alreadyShowingThisPicture):
            heading = (
                "questionmark.circle.fill",
                Palette.warn,
                L10n.text("传完了，但确认不了屏幕换没换"),
                L10n.text("充电器之前显示的可能就是这张图，看不出区别。去看一眼充电器的屏幕就知道了。")
            )
        case .inconclusive(.beforeStateUnreadable):
            heading = (
                "questionmark.circle.fill",
                Palette.warn,
                L10n.text("传完了，但确认不了屏幕换没换"),
                L10n.text("推送前没读到充电器在显示什么，没有对照。去看一眼充电器的屏幕就知道了。")
            )
        }

        return VStack(alignment: .leading, spacing: Space.s) {
            hint(
                symbol: heading.symbol,
                title: heading.title,
                detail: heading.detail,
                tint: heading.tint
            )
            otherScreenNote
            HStack(spacing: Space.s) {
                Button("完成") { model.dismissCoverPushResult() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Failed

    /// Two lines from the remedy — what is in the charger now, what to do about
    /// it — and a third only when there is a cause the reader can act on.
    ///
    /// ``CoverPushFailure/detail`` is usually nil, and the card is finished
    /// without it. What it never carries is the slice it stopped at or the
    /// status byte that stopped it: those are in the log, where the person
    /// reading a bug report is, and not under a heading the person holding a
    /// charger is trying to act on.
    private func failedCard(_ failure: CoverPushFailure) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            hint(
                symbol: failure.pixelsMayHaveLanded
                    ? "exclamationmark.triangle.fill"
                    : "xmark.circle.fill",
                title: failure.remedy.headline,
                detail: failure.detail,
                tint: failure.pixelsMayHaveLanded ? Palette.warnText : Palette.dangerText
            )

            Text(failure.remedy.advice)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if failure.suggestsCloudID {
                // The placeholder url key is the one real unknown in this
                // feature. A refusal here is the answer to it, and the answer is
                // 「这台固件要云端」 — which Charker does not do, and does not
                // pretend it is about to.
                Text("这台充电器可能只认 Anker 云端分配的图片，不接受本地推上去的。那条路要登录账号并联网，Charker 只走本地这条。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            otherScreenNote

            HStack(spacing: Space.s) {
                if failure.remedy == .selectionDidNotTake {
                    Button("重新指定这张封面") { model.retryCoverSelection() }
                        .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                        .disabled(model.coverPushBlocker != nil)
                }
                if artwork != nil {
                    Button("重新推一次") {
                        acknowledged = false
                        model.dismissCoverPushResult()
                        isConfirming = true
                    }
                    .buttonStyle(CharkerActionButtonStyle())
                    .disabled(model.coverPushBlocker != nil)
                }
                Button("关闭") { model.dismissCoverPushResult() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Re-selected

    /// Takes no id: the reported one was already checked against the expected
    /// one in ``AppModel/noteCoverSelection(_:expected:slot:)`` — reaching this
    /// card at all is what the match means — and it is logged there for anyone
    /// who has to go looking.
    private var reselectedCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            hint(
                symbol: "checkmark.circle.fill",
                title: L10n.text("充电器已经切到这张封面"),
                tint: Palette.ok
            )
            HStack(spacing: Space.s) {
                Button("完成") { model.dismissCoverPushResult() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Pieces

    /// The exact bytes the panel will receive, decoded back into a picture.
    ///
    /// Not the model texture: that one carries a drawn bezel because the 3D model
    /// has no physical one. The charger does, so what it gets is the bare square.
    private var devicePreview: some View {
        ZStack {
            Color.black
            if let image = preview?.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .accessibilityLabel(Text("充电器屏幕预览 240 × 240"))
    }

    /// Shown when the push on screen belongs to a screen other than the selected
    /// one — otherwise a result card silently reattributes itself to whichever
    /// thumbnail happens to be highlighted.
    @ViewBuilder
    private var otherScreenNote: some View {
        if let slot = model.coverPush.slot, slot != artwork?.id {
            Text("这是另一张自定义屏保的推送。")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func hint(
        symbol: String,
        title: String,
        detail: String? = nil,
        tint: Color = Palette.textSecondary
    ) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                // Optional on purpose: a sentence under 「屏幕换过来了」 restating
                // that it worked reads as a result hedging about itself.
                if let detail {
                    Text(detail)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Text

    private static func stageLabel(_ progress: CoverTransferProgress) -> String {
        switch progress.stage {
        case .idle, .selecting:
            return L10n.text("正在选图…")
        case .starting:
            return L10n.text("正在准备…")
        case .sending:
            // No counter: the percentage and the bar beside this label already
            // say how far along it is, and they say it in a unit that is ours to
            // invent rather than the firmware's.
            return L10n.text("正在推送图片…")
        case .verifying:
            return L10n.text("正在确认…")
        case .finished:
            return L10n.text("已完成")
        }
    }

    /// How long the wait is, as a magnitude rather than a countdown.
    ///
    /// The only number available is ``CoverTransferSchedule/minimumDuration(with:)``,
    /// which counts the deliberate pauses and nothing else — the time an
    /// acknowledgement takes to come back has never been measured, so the floor
    /// is roughly a quarter of the real thing. Quoting it as 「至少 4 秒」 asked the
    /// user to work that out from a parenthesis about round trips; quoting it as
    /// 「4 秒」 would simply be wrong. So it is bucketed one step coarser than the
    /// floor and read out in words: nobody plans a minute around 「十几秒」, and
    /// nobody feels lied to when it turns out to be twenty.
    private static func durationHint(_ preview: DeviceCoverPreview) -> String {
        switch preview.minimumSeconds {
        case ..<7: return L10n.text("推一次大概十几秒")
        case ..<21: return L10n.text("推一次大概半分钟")
        case ..<46: return L10n.text("推一次大概一两分钟")
        default: return L10n.text("推一次大概要几分钟")
        }
    }

    // MARK: - Preview rendering

    /// Recomputed only when the picture or its crop changes; the encode is a few
    /// hundred microseconds but a view body runs far more often than that.
    private var previewKey: String {
        guard let artwork, artwork.sourceImage != nil else { return "none" }
        let crop = artwork.crop
        // The vignette belongs in the key: it is burned into these very bytes,
        // so a re-tint changes both the thumbnail and the transfer size, and a
        // key that ignored it would leave the old picture on screen under the
        // new numbers.
        let ring = artwork.vignette
        return """
        \(artwork.id)|\(crop.centerX)|\(crop.centerY)|\(crop.zoom)\
        |\(ring.red)|\(ring.green)|\(ring.blue)|\(ring.strength)|\(ring.innerRadius)
        """
    }

    private static func makePreview(for artwork: ModelScreenArtworkItem?) -> DeviceCoverPreview? {
        guard let artwork, let source = artwork.sourceImage,
              let jpeg = try? ModelScreenArtwork.deviceCoverJPEG(
                  from: source, crop: artwork.crop, vignette: artwork.vignette
              ),
              // Built for one reason now: the pause budget is the only honest
              // input to 「大概多久」. Its slice and checkpoint counts are the
              // protocol's own arithmetic and stay there — the byte and slice
              // counts of a push that happened are logged by `AppModel`, and no
              // count of a push that has not happened yet tells anyone anything.
              let schedule = try? CoverTransferSchedule(jpeg: jpeg) else { return nil }
        let floor = schedule.minimumDuration(with: CoverTransferSession.Options())
        return DeviceCoverPreview(
            image: NSImage(data: Data(jpeg)),
            minimumSeconds: max(1, Int(floor.components.seconds))
        )
    }
}

/// What the panel is about to be handed, decoded back for display.
struct DeviceCoverPreview {
    let image: NSImage?
    /// Deliberate pauses only — see ``CoverTransferSchedule/minimumDuration(with:)``.
    /// Never shown as a number: ``CoverSyncSection`` buckets it into words,
    /// because the round trips it omits are worth about three times as much
    /// again and nobody has measured them.
    let minimumSeconds: Int
}
