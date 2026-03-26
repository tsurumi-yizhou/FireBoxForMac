import ProjectDescription

let project = Project(
    name: "Shared",
    settings: .settings(
        base: [
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        ]
    ),
    targets: [
        .target(
            name: "Shared",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.firebox.shared",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/**"],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
                    "ENABLE_MODULE_VERIFIER": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]
            )
        ),
    ]
)
