// swift-tools-version: 6.2
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings()
#endif

let package = Package(
    name: "FireBoxDependencies",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.3.1"),
        .package(url: "https://github.com/teunlao/swift-ai-sdk", exact: "0.17.5"),
    ]
)
