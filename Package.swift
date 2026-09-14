// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Charker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Charker", targets: ["CharkerApp"]),
        .library(name: "A2687Protocol", targets: ["A2687Protocol"]),
        .library(name: "A2345Protocol", targets: ["A2345Protocol"]),
        .library(name: "CharkerCore", targets: ["CharkerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/warrenm/GLTFKit2.git", exact: "0.5.15"),
        .package(url: "https://github.com/warrenm/DracoSwift.git", exact: "1.5.7"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "A2687Protocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "A2345Protocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CharkerCore",
            dependencies: ["A2687Protocol", "A2345Protocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CharkerDraco",
            dependencies: [
                .product(name: "GLTFKit2", package: "GLTFKit2"),
                .product(name: "DracoSwift", package: "DracoSwift"),
            ],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CharkerApp",
            dependencies: [
                "CharkerCore",
                "CharkerDraco",
                .product(name: "GLTFKit2", package: "GLTFKit2"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "A2687ProtocolTests",
            dependencies: ["A2687Protocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "A2345ProtocolTests",
            dependencies: ["A2345Protocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CharkerCoreTests",
            dependencies: ["CharkerCore", "A2345Protocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
