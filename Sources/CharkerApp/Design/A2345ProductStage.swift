import AppKit
import CharkerCore
import SwiftUI

/// A static product render for identity and onboarding surfaces. The interactive
/// GLB belongs to the dashboard; connection pages should stay light, stable and
/// scroll normally even when the account is reconnecting.
private enum A2345ProductArt {
    static let image: NSImage? = {
        if UserDefaults.standard.bool(forKey: "noA2345ProductArt") { return nil }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent("Model3D/A2345.png")
            if let image = NSImage(contentsOf: bundled) { return image }
        }
        #if DEBUG
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Design
            .deletingLastPathComponent()  // CharkerApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repository root
        return NSImage(contentsOf: repository.appendingPathComponent(
            "Resources/Model3D/A2345.png"
        ))
        #else
        return nil
        #endif
    }()
}

struct A2345ProductStage: View {
    var active = true
    var height: CGFloat = 108

    var body: some View {
        Group {
            if let artwork = A2345ProductArt.image {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .saturation(active ? 1 : 0.58)
        .brightness(active ? 0 : -0.06)
        .opacity(active ? 1 : 0.78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.text("Anker Prime 250W 充电器产品图")))
        .accessibilityValue(Text(L10n.text(active ? "在线" : "未连接")))
    }

    private var fallback: some View {
        VStack(spacing: 5) {
            Text("ANKER")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accentText)
            Text("PRIME 250W")
                .font(.numeral(10, .semibold))
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: 5) {
                ForEach(0..<6, id: \.self) { _ in
                    Capsule(style: .continuous)
                        .fill(Palette.textTertiary.opacity(0.7))
                        .frame(width: 12, height: 4)
                }
            }
        }
        .frame(width: height * 1.45, height: height * 0.68)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        }
    }
}
