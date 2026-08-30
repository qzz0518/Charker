import AppKit
import CharkerCore
import SwiftUI

/// A native, non-destructive square cropper for the model's standby image.
/// The photo tracks the pointer 1:1 and the editor returns only crop metadata;
/// the original image remains available for later edits.
///
/// The vignette lives here rather than in a settings row because it is the same
/// kind of decision as the framing: both are baked into the pixels by
/// ``ModelScreenArtwork``, neither can be re-applied later, and both want the
/// picture in front of you while you choose. Everything in this sheet is
/// previewed live on the crop itself for that reason.
struct ModelScreenCropEditor: View {
    let sourceImage: NSImage
    /// Whether this picture's pixels are already inside the charger — see
    /// ``AppModel/coverSyncedSlots``. The only thing it changes is whether
    /// ``residentWarning`` appears: an edit to a screen that has never left this
    /// Mac is free, and saying otherwise would make the cheap tier look
    /// expensive.
    let isSyncedToCharger: Bool
    let onApply: (ModelScreenCrop, ModelScreenVignette) -> Void

    @State private var crop: ModelScreenCrop
    @State private var vignette: ModelScreenVignette
    /// The strength to come back to when the switch is turned on again.
    ///
    /// Switching off writes `strength = 0` instead of replacing the whole value,
    /// so a colour chosen earlier survives a trip through "off" — `strength` is
    /// the single thing ``ModelScreenVignette/isEnabled`` reads, and the rest of
    /// the value stays meaningful while it is zero.
    ///
    /// The number itself has nowhere in that value to ride: zero *is* what gets
    /// saved. Held only in `@State` it died with the sheet, so a ring switched
    /// off, saved, and reopened the next day came back at Anker's 0.62 rather
    /// than at whatever the user had dialled in. It is kept in `UserDefaults`
    /// instead — one value for the whole app rather than one per slot, which is
    /// the granularity 「我喜欢的强度」 actually has.
    @State private var restoredStrength: Double
    @GestureState private var dragTranslation = CGSize.zero
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let outerSize: CGFloat = 356
    private let viewportSize: CGFloat = 324
    /// Below this the ring is invisible but `isEnabled` is still true, which
    /// would leave the switch on and the picture unchanged. The switch owns
    /// "none"; the slider only travels between visible values.
    private static let minimumVisibleStrength = 0.08
    /// Where ``restoredStrength`` waits out a relaunch.
    private static let rememberedStrengthKey = "modelScreenVignetteStrength"

    init(
        sourceImage: NSImage,
        crop: ModelScreenCrop,
        vignette: ModelScreenVignette,
        isSyncedToCharger: Bool,
        onApply: @escaping (ModelScreenCrop, ModelScreenVignette) -> Void
    ) {
        self.sourceImage = sourceImage
        self.isSyncedToCharger = isSyncedToCharger
        self.onApply = onApply
        _crop = State(initialValue: crop.clamped(for: sourceImage.size))
        _vignette = State(initialValue: vignette)
        // The slot's own strength wins while the ring is on: within one sheet,
        // off-then-on must give back exactly what was on screen a moment ago,
        // not the app-wide memory of some other picture.
        _restoredStrength = State(
            initialValue: vignette.isEnabled
                ? vignette.strength
                : Self.rememberedStrength()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            HStack {
                Spacer(minLength: 0)
                cropPreview
                Spacer(minLength: 0)
            }

            zoomRow

            Divider().overlay(Palette.stroke)

            vignetteSection

            HStack {
                Button("居中") {
                    if reduceMotion {
                        crop = .centered
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
                            crop = .centered
                        }
                    }
                }
                .buttonStyle(CharkerActionButtonStyle())

                Spacer()

                Button("取消") { dismiss() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))
                Button("应用裁剪与暗角") {
                    onApply(crop.clamped(for: sourceImage.size), vignette)
                    dismiss()
                }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 500)
        .background(Palette.bg)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: vignette.isEnabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("裁剪与暗角")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
            Text("拖动图片调整位置，用滑块放大；黑框以内就是最终的正方形画面，暗角也一起画进去。")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var zoomRow: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            Slider(value: zoomBinding, in: 1...ModelScreenArtwork.maximumZoom)
                .tint(Palette.accent)
                .accessibilityLabel(Text("图片缩放"))
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            Text(L10n.format("%.1f×", crop.zoom))
                .font(.numeral(11, .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var cropPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(Color.black)

            ZStack {
                Color.black
                Image(nsImage: sourceImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayedImageSize.width, height: displayedImageSize.height)
                    .offset(displayedOffset)
                    .allowsHitTesting(false)

                // Between the photo and the guides, which is where the renderer
                // puts it: over the pixels, under nothing that ships.
                vignettePreview

                CropThirdsGrid()
                    .allowsHitTesting(false)
            }
            .frame(width: viewportSize, height: viewportSize)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .gesture(cropDrag)
        }
        .frame(width: outerSize, height: outerSize)
        .overlay(
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("方形图片裁剪区域"))
        .accessibilityValue(Text(L10n.format("缩放 %.1f 倍", crop.zoom)))
    }

    /// The ring, drawn with the same arithmetic as
    /// ``ModelScreenArtwork/drawVignette(_:in:)``: transparent until
    /// `innerRadius` of the half-diagonal, full strength at the corner, so the
    /// edge midpoints stay lighter than the corners.
    ///
    /// A gradient rather than a re-render of the real texture. The renderer is
    /// cheap but not free, and this redraws on every frame of a slider drag; the
    /// two agree because they are handed the same numbers, which is the same
    /// reason the model and the panel agree.
    @ViewBuilder
    private var vignettePreview: some View {
        if vignette.isEnabled {
            let tint = Color(nsColor: vignette.color)
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: tint.opacity(0), location: clampedInnerRadius),
                    .init(color: tint.opacity(clampedStrength), location: 1),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: viewportSize * sqrt(2) / 2
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Vignette controls

    private var vignetteSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("暗角")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                // Said once, quietly, where the control is: this is not a filter
                // the app puts over the picture, it becomes the picture.
                Text("画进图片里")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.well))

                Spacer(minLength: Space.s)

                Button("官方同款") { apply(.official) }
                    .buttonStyle(CharkerActionButtonStyle())
                    .disabled(vignette == .official)
                    .help("黑色，强度 0.62，和 Anker 官方 App 一样")

                Toggle(isOn: enabledBinding) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(Text("暗角"))
            }

            if vignette.isEnabled {
                HStack(spacing: Space.s) {
                    ForEach(Self.presets, id: \.name) { preset in
                        presetSwatch(preset)
                    }
                    ColorPicker(selection: colorBinding, supportsOpacity: false) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("自定义暗角颜色"))
                    Spacer(minLength: 0)
                }

                HStack(spacing: Space.m) {
                    Text("强度")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Slider(value: strengthBinding, in: Self.minimumVisibleStrength...1)
                        .tint(Palette.accent)
                        .accessibilityLabel(Text("暗角强度"))
                    Text(verbatim: "\(Int((clampedStrength * 100).rounded()))%")
                        .font(.numeral(11, .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                Text("关掉之后就是裁剪出来的那张图，四角不压暗。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

            if isSyncedToCharger { residentWarning }
        }
    }

    /// Shown only for a picture that is already in the charger.
    ///
    /// Here rather than under the push button: by the time someone reaches the
    /// confirm panel they have decided, and the thing they need to know is that
    /// this edit is what created the need to push again.
    private var residentWarning: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.warn)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("这张图已经推给过充电器")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textPrimary)
                Text("暗角和裁剪都是画进像素里的，充电器只显示推上去的那 240×240。这里改完，模型上立刻变，充电器上还是旧的那张——要它跟着变就得重推一次，而每推一次都会再占机内 4 个位置里的一个，没有删除命令。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .fill(Palette.warn.opacity(0.12))
        )
    }

    private func presetSwatch(_ preset: VignettePreset) -> some View {
        let selected = matches(preset)
        return Button {
            apply(ModelScreenVignette(
                color: preset.color,
                strength: max(vignette.strength, Self.minimumVisibleStrength),
                innerRadius: vignette.innerRadius
            ))
        } label: {
            Circle()
                .fill(Color(nsColor: preset.color))
                .overlay(Circle().strokeBorder(Palette.strokeStrong, lineWidth: 1))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(
                    Circle()
                        .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 2)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.text(preset.name))
        .accessibilityLabel(Text(L10n.format("暗角颜色 %@", L10n.text(preset.name))))
        .accessibilityValue(Text(L10n.text(selected ? "已选择" : "未选择")))
    }

    /// Presets exist to save a trip through the colour panel for the handful of
    /// rings people actually ask for; the picker beside them is the real answer
    /// to "any colour".
    private static let presets: [VignettePreset] = [
        VignettePreset(name: "黑", color: .black),
        VignettePreset(name: "白", color: .white),
        VignettePreset(
            name: "深蓝",
            color: NSColor(srgbRed: 0.04, green: 0.09, blue: 0.28, alpha: 1)
        ),
        VignettePreset(
            name: "青",
            color: NSColor(srgbRed: 0, green: 167 / 255, blue: 225 / 255, alpha: 1)
        ),
        VignettePreset(
            name: "洋红",
            color: NSColor(srgbRed: 0.86, green: 0.09, blue: 0.45, alpha: 1)
        ),
    ]

    private var clampedStrength: Double {
        min(max(vignette.strength.isFinite ? vignette.strength : 0, 0), 1)
    }

    private var clampedInnerRadius: Double {
        min(max(vignette.innerRadius.isFinite ? vignette.innerRadius : 0.45, 0), 0.95)
    }

    private func matches(_ preset: VignettePreset) -> Bool {
        let candidate = ModelScreenVignette(color: preset.color, strength: vignette.strength)
        // Eight bits is the resolution the ring is rendered at, so anything
        // closer than half a step is the same colour on screen.
        let tolerance = 1.0 / 512
        return abs(candidate.red - vignette.red) < tolerance
            && abs(candidate.green - vignette.green) < tolerance
            && abs(candidate.blue - vignette.blue) < tolerance
    }

    private func apply(_ value: ModelScreenVignette) {
        vignette = value
        if value.isEnabled { remember(strength: value.strength) }
    }

    /// Records the strength to come back to, in this sheet and on disk.
    ///
    /// Called on every frame of a slider drag; `UserDefaults` keeps that in
    /// memory and coalesces the writes, so this is a property assignment's worth
    /// of work rather than a file's.
    private func remember(strength: Double) {
        restoredStrength = strength
        UserDefaults.standard.set(strength, forKey: Self.rememberedStrengthKey)
    }

    /// The last visible strength, or the official ring's when there has never
    /// been one. Clamped on the way in: a number left by an older build — or by
    /// `defaults write` — must not park the slider off its own track.
    private static func rememberedStrength() -> Double {
        guard let stored = UserDefaults.standard.object(forKey: rememberedStrengthKey) as? Double,
              stored.isFinite else {
            return ModelScreenVignette.official.strength
        }
        return min(max(stored, minimumVisibleStrength), 1)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { vignette.isEnabled },
            set: { isOn in
                if isOn {
                    vignette.strength = max(restoredStrength, Self.minimumVisibleStrength)
                } else {
                    remember(strength: vignette.strength)
                    vignette.strength = 0
                }
            }
        )
    }

    private var strengthBinding: Binding<Double> {
        Binding(
            get: { clampedStrength },
            set: { newValue in
                vignette.strength = newValue
                remember(strength: newValue)
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: vignette.color) },
            set: { newValue in
                let srgb = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                vignette.red = Double(srgb.redComponent)
                vignette.green = Double(srgb.greenComponent)
                vignette.blue = Double(srgb.blueComponent)
            }
        )
    }

    // MARK: - Crop gesture

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { crop.zoom },
            set: { newValue in
                crop.zoom = newValue
                crop = crop.clamped(for: sourceImage.size)
            }
        )
    }

    private var cropDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let size = displayedImageSize
                let finalOffset = clampedOffset(
                    CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    ),
                    displayedSize: size
                )
                crop.centerX = 0.5 - finalOffset.width / size.width
                crop.centerY = 0.5 - finalOffset.height / size.height
                crop = crop.clamped(for: sourceImage.size)
            }
    }

    private var displayedImageSize: CGSize {
        let sourceWidth = max(sourceImage.size.width, 1)
        let sourceHeight = max(sourceImage.size.height, 1)
        let aspect = sourceWidth / sourceHeight
        let baseSize: CGSize
        if aspect >= 1 {
            baseSize = CGSize(width: viewportSize * aspect, height: viewportSize)
        } else {
            baseSize = CGSize(width: viewportSize, height: viewportSize / aspect)
        }
        return CGSize(width: baseSize.width * crop.zoom, height: baseSize.height * crop.zoom)
    }

    private var baseOffset: CGSize {
        let safeCrop = crop.clamped(for: sourceImage.size)
        let size = displayedImageSize
        return CGSize(
            width: size.width * (0.5 - safeCrop.centerX),
            height: size.height * (0.5 - safeCrop.centerY)
        )
    }

    private var displayedOffset: CGSize {
        clampedOffset(
            CGSize(
                width: baseOffset.width + dragTranslation.width,
                height: baseOffset.height + dragTranslation.height
            ),
            displayedSize: displayedImageSize
        )
    }

    private func clampedOffset(_ offset: CGSize, displayedSize: CGSize) -> CGSize {
        let maximumX = max(0, (displayedSize.width - viewportSize) / 2)
        let maximumY = max(0, (displayedSize.height - viewportSize) / 2)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }
}

/// A named colour on the swatch row. `innerRadius` is deliberately absent: three
/// sliders for one effect is three ways to get it wrong, and 0.45 is the only
/// value the official ring uses.
private struct VignettePreset {
    let name: String
    let color: NSColor
}

private struct CropThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                path.move(to: CGPoint(x: size.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
        }
    }
}
