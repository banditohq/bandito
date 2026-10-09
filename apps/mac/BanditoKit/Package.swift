// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BanditoKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BanditoKit", targets: ["BanditoKit"])],
    targets: [
        .target(name: "BanditoKit"),
        .testTarget(name: "BanditoKitTests", dependencies: ["BanditoKit"]),
    ]
)
