// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bannerless",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bannerless", targets: ["Bannerless"]),
        .library(name: "CodeCore", targets: ["CodeCore"]),
    ],
    targets: [
        // Finding one-time codes, and reading them from Messages and notifications.
        .target(name: "CodeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The notch panel.
        .target(name: "NotchUI"),
        // The menu bar app.
        .executableTarget(name: "Bannerless", dependencies: ["CodeCore", "NotchUI"]),
        .testTarget(name: "BannerlessTests", dependencies: ["CodeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
