// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BanditoKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BanditoKit", targets: ["BanditoKit"]),
        .library(name: "BanditoDesign", targets: ["BanditoDesign"]),
        .library(name: "BanditoUI", targets: ["BanditoUI"]),
    ],
    targets: [
        .target(name: "BanditoKit"),
        .target(name: "BanditoDesign", resources: [.process("Colors.xcassets")]),
        .target(name: "BanditoUI", dependencies: ["BanditoKit", "BanditoDesign"]),
        .testTarget(name: "BanditoKitTests", dependencies: ["BanditoKit"]),
        .testTarget(name: "BanditoUITests", dependencies: ["BanditoUI", "BanditoKit"]),
    ]
)
