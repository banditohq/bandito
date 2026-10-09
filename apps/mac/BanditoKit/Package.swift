// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BanditoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BanditoKit", targets: ["BanditoKit"]),
        .library(name: "BanditoDesign", targets: ["BanditoDesign"]),
        .library(name: "BanditoL10n", targets: ["BanditoL10n"]),
    ],
    targets: [
        .target(name: "BanditoKit"),
        .target(name: "BanditoDesign", resources: [.process("Colors.xcassets")]),
        .target(name: "BanditoL10n", resources: [.process("Resources")]),
        .testTarget(name: "BanditoKitTests", dependencies: ["BanditoKit", "BanditoL10n"]),
    ]
)
