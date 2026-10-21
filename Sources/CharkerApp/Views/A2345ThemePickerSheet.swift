import A2345Protocol
import AppKit
import CharkerCore
import SwiftUI
import UniformTypeIdentifiers

/// The official app's previews of the three built-in clock styles, and the
/// time it lays over every picture, from `Resources/ClockThemes`.
private enum A2345ClockThemeArt {
    static let styles = (1...3).map { load("style\($0)") }
    static let clock = load("clock")

    static func builtIn(_ kind: A2345ThemeKind) -> NSImage? {
        styles.indices.contains(Int(kind.rawValue)) ? styles[Int(kind.rawValue)] : nil
    }

    private static func load(_ name: String) -> NSImage? {
        if let base = Bundle.main.resourceURL,
           let image = NSImage(contentsOf: base.appendingPathComponent("ClockThemes/\(name).png")) {
            return image
        }
        #if DEBUG
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Views
            .deletingLastPathComponent()  // CharkerApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repository root
        return NSImage(contentsOf: repository.appendingPathComponent(
            "Resources/ClockThemes/\(name).png"
        ))
        #else
        return nil
        #endif
    }
}

/// Clock screensaver themes: the three built-in styles, the cloud picture
/// themes and the user's own pictures. Pictures are downloaded by the charger
/// itself over Wi-Fi. Each tile has the screen's shape and shows the clock the
/// way the charger will, as the official app does; a square crop of a 480×200
/// picture kept only its empty middle.
struct A2345ThemePickerSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingUpload: PendingUpload?
    @State private var confirmingDelete: A2345CloudTheme?

    private struct PendingUpload {
        let preview: NSImage
        let jpeg: Data
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.m), count: 2)
    private let screenAspect = A2345PictureEncoder.size.width / A2345PictureEncoder.size.height
    private var clock: A2345ClockState? { model.a2345Snapshot.settings?.clock }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("时钟主题")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if model.a2345ThemeDownload != nil {
                    ProgressView().controlSize(.small)
                    Text("充电器正在下载…")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.l)
            Divider().overlay(Palette.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    section(L10n.text("标准样式")) {
                        ForEach([A2345ThemeKind.style1, .style2, .style3], id: \.rawValue) { kind in
                            tile(
                                title: A2345Labels.builtInStyle(kind),
                                selected: clock?.themeCode == kind.rawValue,
                                enabled: clockOn
                            ) {
                                if let art = A2345ClockThemeArt.builtIn(kind) {
                                    Image(nsImage: art).resizable().scaledToFill()
                                }
                            } action: { model.applyA2345BuiltInStyle(kind) }
                        }
                    }
                    ForEach(themeCategories, id: \.self) { category in
                        section(category.isEmpty ? L10n.text("云端主题") : category) {
                            ForEach(model.a2345Themes?.filter { $0.category == category } ?? []) { theme in
                                pictureTile(theme)
                            }
                        }
                    }
                    if !model.a2345Snapshot.isDemo, model.a2345CustomPictures != nil {
                        section(L10n.text("我的图片")) {
                            ForEach(model.a2345CustomPictures ?? []) { theme in
                                pictureTile(theme)
                                    .contextMenu {
                                        Button(L10n.text("删除"), role: .destructive) {
                                            confirmingDelete = theme
                                        }
                                    }
                            }
                            uploadTile
                        }
                    }
                    if model.a2345Themes == nil, !model.a2345Snapshot.isDemo {
                        Text("云端主题没有读到。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(Space.l)
            }
            .disabled(model.a2345ControlBlocker != nil)
            if let pendingUpload {
                Divider().overlay(Palette.stroke)
                uploadConfirmation(pendingUpload)
            }
        }
        .frame(width: 520, height: 560)
        .background(Palette.bg)
        .onAppear { model.reloadA2345CustomPictures() }
        .confirmationDialog(
            L10n.text("删除这张图片？"),
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("删除"), role: .destructive) {
                if let theme = confirmingDelete { model.deleteA2345CustomPicture(theme) }
                confirmingDelete = nil
            }
            Button("取消", role: .cancel) { confirmingDelete = nil }
        }
    }

    private var uploadTile: some View {
        Button(action: chooseImage) {
            VStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surfaceRaised)
                    .aspectRatio(screenAspect, contentMode: .fit)
                    .overlay {
                        if model.a2345CloudWork.contains(.pictures) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                Text("上传图片")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.a2345CanUploadPicture || model.a2345CloudWork.contains(.pictures))
        .help(uploadHelp)
    }

    /// Why uploading is unavailable; empty (no tooltip) when it is.
    private var uploadHelp: Text {
        guard !model.a2345CanUploadPicture,
              (model.a2345CustomPictures?.count ?? 0) >= AnkerCloudClient.a2345CustomPictureLimit
        else { return Text(verbatim: "") }
        return Text(L10n.format("最多 %d 张。", AnkerCloudClient.a2345CustomPictureLimit))
    }

    private func uploadConfirmation(_ upload: PendingUpload) -> some View {
        HStack(spacing: Space.m) {
            Image(nsImage: upload.preview)
                .resizable()
                .aspectRatio(A2345PictureEncoder.size.width / A2345PictureEncoder.size.height, contentMode: .fit)
                .frame(width: 192)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("上传到 Anker 账号后就能用在充电器上。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Button("取消") { pendingUpload = nil }
                    Button(L10n.text("上传")) {
                        model.uploadA2345CustomPicture(upload.jpeg)
                        pendingUpload = nil
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                    .disabled(!model.a2345CanUploadPicture)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.l)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url),
              let cropped = A2345PictureEncoder.crop(image),
              let jpeg = A2345PictureEncoder.jpeg(cropped) else { return }
        pendingUpload = PendingUpload(
            preview: NSImage(cgImage: cropped, size: A2345PictureEncoder.size),
            jpeg: jpeg
        )
    }

    private var themeCategories: [String] {
        var seen: [String] = []
        for theme in model.a2345Themes ?? [] where !seen.contains(theme.category) {
            seen.append(theme.category)
        }
        return seen
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.m) {
                content()
            }
        }
    }

    private var clockOn: Bool { clock?.isOn ?? false }

    private func pictureTile(_ theme: A2345CloudTheme) -> some View {
        tile(
            title: theme.kind == .custom ? nil : theme.title,
            selected: clock?.themeCode == theme.kind.rawValue && clock?.themeID == theme.id,
            enabled: clockOn && (theme.kind == .custom || model.a2345SupportsPictureThemes),
            downloading: model.a2345ThemeDownload == theme.id
        ) {
            AsyncImage(url: URL(string: theme.imageURL)) { phase in
                switch phase {
                case .success(let picture):
                    picture.resizable().scaledToFill()
                    clockOverlay
                case .failure:
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                default:
                    ProgressView().controlSize(.small)
                }
            }
        } action: { model.applyA2345PictureTheme(theme) }
    }

    /// The time as the charger draws it over a picture, at the official
    /// preview's scale.
    @ViewBuilder
    private var clockOverlay: some View {
        if let time = A2345ClockThemeArt.clock {
            GeometryReader { screen in
                Image(nsImage: time)
                    .resizable()
                    .scaledToFit()
                    .frame(width: screen.size.width * 0.47)
                    .position(x: screen.size.width / 2, y: screen.size.height / 2)
            }
        }
    }

    private func tile<Screen: View>(
        title: String?,
        selected: Bool,
        enabled: Bool,
        downloading: Bool = false,
        @ViewBuilder screen: () -> Screen,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Color.black
                    .aspectRatio(screenAspect, contentMode: .fit)
                    .overlay {
                        screen()
                        if downloading {
                            Color.black.opacity(0.4)
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(
                                selected ? Palette.accent : Palette.stroke,
                                lineWidth: selected ? 2 : Stroke.hairline
                            )
                    )
                if let title, !title.isEmpty {
                    Text(title)
                        .font(Typo.caption)
                        .foregroundStyle(selected ? Palette.accentText : Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled || model.a2345ThemeDownload != nil)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(title ?? L10n.text("我的图片")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
