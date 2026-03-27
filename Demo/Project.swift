import ProjectDescription

let project = Project(
    name: "Demo",
    packages: [
        .remote(
            url: "https://github.com/gonzalezreal/textual",
            requirement: .exact("0.3.1")
        ),
        .remote(
            url: "https://github.com/teunlao/swift-ai-sdk",
            requirement: .exact("0.17.5")
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
                "CFBundleDisplayName": "FireChatBox",
                "CFBundleName": "FireChatBox",
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
                .package(product: "AISDKJSONSchema"),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "EXECUTABLE_NAME": "FireChatBox",
                    "INFOPLIST_KEY_CFBundleDisplayName": "FireChatBox",
                    "INFOPLIST_KEY_CFBundleName": "FireChatBox",
                    "PRODUCT_NAME": "FireChatBox",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                    "WRAPPER_NAME": "FireChatBox.app",
                ]
            )
        ),
    ]
)
