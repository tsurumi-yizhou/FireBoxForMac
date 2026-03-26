import ProjectDescription

let project = Project(
    name: "Demo",
    packages: [
        .remote(
            url: "https://github.com/gonzalezreal/textual",
            requirement: .exact("0.3.1")
        ),
    ],
    targets: [
        .target(
            name: "Demo",
            destinations: .macOS,
            product: .app,
            bundleId: "com.firebox.demo",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "$(PRODUCT_NAME)",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "LSMinimumSystemVersion": "15.0",
                "CFBundleLocalizations": ["en", "zh-Hans"],
                "CFBundleDevelopmentRegion": "en",
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "Client", path: "../Client"),
                .package(product: "Textual"),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]
            )
        ),
    ]
)
