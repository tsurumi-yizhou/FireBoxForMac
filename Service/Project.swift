import ProjectDescription

let project = Project(
    name: "Service",
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
                .external(name: "SwiftAISDK"),
                .external(name: "OpenAIProvider"),
                .external(name: "AnthropicProvider"),
                .external(name: "GoogleProvider"),
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
