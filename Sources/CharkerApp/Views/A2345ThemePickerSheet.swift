import A2345Protocol
import AppKit
import CharkerCore
import SwiftUI
import UniformTypeIdentifiers

/// Clock screensaver themes: the three built-in styles, the cloud picture
/// themes and the user's own pictures. Pictures are downloaded by the charger
/// itself over Wi-Fi.
struct A2345ThemePickerSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingUpload: PendingUpload?
    @State private var confirmingDelete: A2345CloudTheme?

    private struct PendingUpload {
        let preview: NSImage
        let jpeg: Data
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: Space.m)]
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
                                image: nil,
                                symbol: "clock",
                                enabled: clockOn
                            ) { model.applyA2345BuiltInStyle(kind) }
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
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Palette.surfaceRaised)
                    if model.a2345CloudWork.contains(.pictures) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(width: 96, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                Text("上传图片")
                    .font(Typo.micro)
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
            image: URL(string: theme.imageURL),
            symbol: "photo",
            enabled: clockOn && (theme.kind == .custom || model.a2345SupportsPictureThemes),
            downloading: model.a2345ThemeDownload == theme.id
        ) { model.applyA2345PictureTheme(theme) }
    }

    private func tile(
        title: String?,
        selected: Bool,
        image: URL?,
        symbol: String,
        enabled: Bool,
        downloading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                ZStack {
                    Color.black
                    if let image {
                        AsyncImage(url: image) { phase in
                            if let picture = phase.image {
                                picture.resizable().scaledToFill()
                            } else {
                                Image(systemName: symbol)
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if downloading {
                        Color.black.opacity(0.4)
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(selected ? Palette.accent : Palette.stroke, lineWidth: selected ? 2 : Stroke.hairline)
                )
                if let title, !title.isEmpty {
                    Text(title)
                        .font(Typo.micro)
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
