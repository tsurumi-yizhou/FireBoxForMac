import ProjectDescription

let project = Project(
    name: "Service",
    packages: [
        .remote(
            url: "https://github.com/teunlao/swift-ai-sdk",
            requirement: .exact("0.17.5")
        ),
    ],
    targets: [
        .target(
            name: "Service",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.firebox.service",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/**"],
            dependencies: [
                .project(target: "Shared", path: "../Shared"),
                .package(product: "SwiftAISDK"),
                .package(product: "OpenAIProvider"),
                .package(product: "AnthropicProvider"),
                .package(product: "GoogleProvider"),
                .sdk(name: "SwiftData", type: .framework, status: .required),
                .sdk(name: "CloudKit", type: .framework, status: .required),
                .sdk(name: "Security", type: .framework, status: .required),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path @executable_path/Frameworks @executable_path/../Frameworks @loader_path/Frameworks @loader_path/../Frameworks",
                ]
            )
        ),
    ]
)
