// swift-tools-version: 6.0
// 这个 manifest 让「核心逻辑」能在 Windows 上直接 swift build / swift test。
// SwiftUI 壳（App/）不进这个包，只由 Xcode 在 macOS / CI 上编译。
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    targets: [
        .target(
            name: "AppCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"]
        ),
    ]
)
