import AppKit

enum BrandAssets {
    static let ankerLogo = image(named: "Anker.svg")
    static let githubLogo = templateImage(named: "GitHub.svg")
    static let xLogo = templateImage(named: "X.svg")

    private static func image(named name: String) -> NSImage? {
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent("Brand/\(name)")
            if let image = NSImage(contentsOf: bundled) { return image }
        }

        #if DEBUG
        let repositoryAsset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Design
            .deletingLastPathComponent()  // CharkerApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/Brand/\(name)")
        return NSImage(contentsOf: repositoryAsset)
        #else
        return nil
        #endif
    }

    private static func templateImage(named name: String) -> NSImage? {
        guard let image = image(named: name) else { return nil }
        image.isTemplate = true
        return image
    }
}
