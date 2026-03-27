// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Client",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Client",
            targets: ["Client"]
        ),
    ],
    dependencies: [
        // 如果有外部依赖，在这里添加
    ],
    targets: [
        .target(
            name: "Client",
            dependencies: [],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ClientTests",
            dependencies: ["Client"],
            path: "Tests"
        ),
    ]
)
