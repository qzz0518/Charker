import AppKit
import CharkerCore
import SwiftUI
import UniformTypeIdentifiers

/// Screen personalisation opened from Devices & Connection. Up to three local
/// custom screens can be kept at once; file selection does not commit anything
/// until the user confirms the native square crop editor.
struct ModelScreenSettingsSheet: View {
    /// Owner of the live BLE session, for the 同步屏保 tier below.
    ///
    /// Declared first so the memberwise initialiser takes it first, and
    /// non-optional so there is exactly one way for the tier to reach the
    /// session. An earlier draft made it optional with a fallback to a weak
    /// static on `AppModel`, because the call site lived in a file that change
    /// did not own; both the optionality and the static are gone now that
    /// `SettingsViews.swift` passes it down.
    let model: AppModel
    let style: ModelScreenStyle
    let artworks: [ModelScreenArtworkItem]
    let selectedCustomID: Int
    let importError: String?
    let onSelectAnkerPrime: () -> Void
    let onSelectCustom: (Int) -> Void
    let onCommit: (Int?, NSImage, ModelScreenCrop, ModelScreenVignette) -> Void
    let onRemove: (Int) -> Void

    @State private var showsImporter = false
    @State private var importDestination = ImportDestination.add
    @State private var cropSession: CropEditorSession?
    @State private var importerError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var orderedArtworks: [ModelScreenArtworkItem] {
        artworks.sorted { $0.id < $1.id }
    }

    private var selectedArtwork: ModelScreenArtworkItem? {
        guard style == .custom else { return nil }
        return orderedArtworks.first { $0.id == selectedCustomID }
    }

    private var selectedImage: NSImage {
        selectedArtwork?.textureImage ?? ModelScreenArtwork.ankerPrimeTexture
    }

    private var selectedArtworkNumber: Int? {
        guard let selectedArtwork else { return nil }
        return orderedArtworks.firstIndex { $0.id == selectedArtwork.id }.map { $0 + 1 }
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: Space.s),
            count: ModelScreenArtworkStore.maximumCustomImages
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            HStack(alignment: .center, spacing: Space.xl) {
                screenPreview
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(selectionTitle)
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                }
            }

            choiceRow(
                title: "Anker Prime",
                subtitle: "默认品牌待机画面",
                image: ModelScreenArtwork.ankerPrimeTexture,
                selected: style == .ankerPrime,
                action: onSelectAnkerPrime
            )

            customLibrary

            // The second tier. 模型屏保 dresses the 3D model inside Charker;
            // 同步屏保 sends the very same crop to the charger's own panel, so
            // the two live together rather than in two unrelated screens.
            Divider().overlay(Palette.stroke)
            CoverSyncSection(model: model, artwork: selectedArtwork)

            if let message = importerError ?? importError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionBar

            // Reworded now that 同步屏保 exists: the picture really can leave this
            // Mac, and the old 「不会上传」 would read as a promise it no longer
            // keeps. It still never touches a server — the only way out is the
            // Bluetooth link to the charger in front of you.
            Text("图片只保存在这台 Mac 上，不会修改原图，也不会传给任何服务器；同步屏保只经蓝牙写进充电器。")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xxl)
        .frame(width: 560)
        .background(Palette.bg)
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .sheet(item: $cropSession) { session in
            ModelScreenCropEditor(
                sourceImage: session.image,
                crop: session.crop,
                vignette: session.vignette,
                // Only a slot whose pixels are already in the charger earns the
                // warning. A new import has no target slot yet and cannot have
                // been pushed, so it stays quiet — 模型屏保 on its own is free.
                isSyncedToCharger: session.targetID
                    .map(model.coverSyncedSlots.contains) ?? false
            ) { newCrop, newVignette in
                importerError = nil
                onCommit(session.targetID, session.image, newCrop, newVignette)
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: style)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: selectedCustomID)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: artworks.count)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("模型屏保")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("设置充电器三维模型顶屏的待机画面。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: Space.l)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.well))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("关闭")
            .accessibilityLabel(Text("关闭模型屏保设置"))
        }
    }

    private var customLibrary: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("自定义屏保")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s)
                Text("\(orderedArtworks.count) / \(ModelScreenArtworkStore.maximumCustomImages)")
                    .font(.numeral(10, .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.well))
                if orderedArtworks.count == ModelScreenArtworkStore.maximumCustomImages {
                    Text("已满")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            LazyVGrid(columns: gridColumns, spacing: Space.s) {
                ForEach(0..<ModelScreenArtworkStore.maximumCustomImages, id: \.self) { index in
                    if index < orderedArtworks.count {
                        artworkCard(orderedArtworks[index], number: index + 1)
                    } else if index == orderedArtworks.count {
                        addCard
                    } else {
                        emptyCard
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Space.s) {
            if let selectedArtwork {
                Button("更换图片…") {
                    beginImport(.replace(selectedArtwork.id))
                }
                .buttonStyle(CharkerActionButtonStyle())

                if let sourceImage = selectedArtwork.sourceImage {
                    Button("编辑裁剪与暗角") {
                        cropSession = CropEditorSession(
                            targetID: selectedArtwork.id,
                            image: sourceImage,
                            crop: selectedArtwork.crop,
                            vignette: selectedArtwork.vignette
                        )
                    }
                    .buttonStyle(CharkerActionButtonStyle())
                }

                Button("移除", role: .destructive) {
                    onRemove(selectedArtwork.id)
                }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .destructive))
            } else if orderedArtworks.count < ModelScreenArtworkStore.maximumCustomImages {
                Button("添加屏保…") {
                    beginImport(.add)
                }
                .buttonStyle(CharkerActionButtonStyle())
            }

            Spacer(minLength: Space.m)
            Button("完成") { dismiss() }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
        }
        .frame(minHeight: 28)
    }

    private var screenPreview: some View {
        ZStack {
            Color.black
            ModelScreenSquare(image: selectedImage, side: 176)
            LinearGradient(
                colors: [.white.opacity(0.08), .clear, .black.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
        .frame(width: 176, height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(selectionAccessibilityLabel))
    }

    private func choiceRow(
        title: String,
        subtitle: String,
        image: NSImage,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                modelScreenThumbnail(image)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .font(Typo.body)
                        .foregroundStyle(Palette.textPrimary)
                    Text(L10n.text(subtitle))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: Space.m)
                selectionIndicator(selected)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(choiceBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.format("%@，%@", L10n.text(title), L10n.text(subtitle))))
        .accessibilityValue(Text(L10n.text(selected ? "已选择" : "未选择")))
    }

    private func artworkCard(
        _ artwork: ModelScreenArtworkItem,
        number: Int
    ) -> some View {
        let selected = style == .custom && selectedCustomID == artwork.id
        return Button {
            onSelectCustom(artwork.id)
        } label: {
            VStack(spacing: Space.s) {
                ZStack(alignment: .topTrailing) {
                    modelScreenThumbnail(artwork.textureImage, size: 76)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .background(Circle().fill(Palette.bg).padding(2))
                            .offset(x: 5, y: -5)
                            .allowsHitTesting(false)
                    }
                }
                Text(L10n.format("屏保 %d", number))
                    .font(Typo.caption)
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 118)
            .background(choiceBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.format("自定义屏保 %d", number)))
        .accessibilityValue(Text(L10n.text(selected ? "已选择" : "未选择")))
    }

    private var addCard: some View {
        Button {
            beginImport(.add)
        } label: {
            VStack(spacing: Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Palette.accentWash))
                Text("添加屏保")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 118)
            .background(
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .fill(Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(0.36), style: StrokeStyle(
                        lineWidth: 1,
                        dash: [4, 4]
                    ))
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("添加自定义屏保"))
    }

    private var emptyCard: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "photo")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.textTertiary.opacity(0.48))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.well.opacity(0.72)))
            Text("空位")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary.opacity(0.58))
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .fill(Palette.well.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke.opacity(0.64), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .accessibilityHidden(true)
    }

    /// Shows just the picture, square, out of the model's texture strip.
    ///
    /// What we store per screen is the whole 960×400 UV strip the 3D model
    /// wants, and the chosen picture only occupies `screenImageRect` inside it —
    /// a square that sits a little right of the strip's centre, because the UV
    /// island is off-centre and the artwork is drawn with a correction for it.
    /// Pouring that 2.4:1 strip into a square frame with `scaledToFill` therefore
    /// cut a slice out of the wrong place and brought the painted bezel along:
    /// that is what looked crooked.
    ///
    /// Done in layout rather than by cropping a new bitmap, because this runs on
    /// every body pass — once for the big preview and four more times for the
    /// thumbnails. Draw the strip at the scale that makes the screen square
    /// exactly `side` across, slide that square's centre onto the frame's
    /// centre, and let the frame clip away everything else.
    private func modelScreenThumbnail(
        _ image: NSImage,
        size: CGFloat = 58
    ) -> some View {
        ZStack {
            Color.black
            ModelScreenSquare(image: image, side: size)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func choiceBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
            .fill(selected ? Palette.accentWash.opacity(0.72) : Palette.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(
                        selected ? Palette.accent.opacity(0.72) : Palette.stroke,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
    }

    private func selectionIndicator(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? Palette.accent : Palette.textTertiary.opacity(0.55))
    }

    private var selectionTitle: String {
        selectedArtworkNumber.map { L10n.format("自定义屏保 %d", $0) } ?? "Anker Prime"
    }

    private var selectionAccessibilityLabel: String {
        selectedArtworkNumber.map { L10n.format("当前为自定义屏保 %d", $0) }
            ?? L10n.text("当前为 Anker Prime 默认屏保")
    }

    private func beginImport(_ destination: ImportDestination) {
        importerError = nil
        importDestination = destination
        showsImporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if importDestination == .add,
               orderedArtworks.count >= ModelScreenArtworkStore.maximumCustomImages {
                importerError = L10n.text("最多只能添加 3 个自定义屏保")
                return
            }
            importerError = nil
            do {
                let hasSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                let image = try ModelScreenArtwork.sourceImage(from: url)
                let targetID: Int?
                switch importDestination {
                case .add: targetID = nil
                case .replace(let id): targetID = id
                }
                // A freshly imported picture starts on the official ring, which
                // is also what an archive written before vignettes existed
                // decodes to — one look for every screen that was never tuned.
                cropSession = CropEditorSession(
                    targetID: targetID,
                    image: image,
                    crop: .centered,
                    vignette: .official
                )
            } catch {
                importerError = error.localizedDescription
            }
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            importerError = error.localizedDescription
        }
    }
}

private enum ImportDestination: Equatable {
    case add
    case replace(Int)
}

private struct CropEditorSession: Identifiable {
    let id = UUID()
    let targetID: Int?
    let image: NSImage
    let crop: ModelScreenCrop
    let vignette: ModelScreenVignette
}
