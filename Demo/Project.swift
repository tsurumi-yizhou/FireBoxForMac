import ProjectDescription

let project = Project(
    name: "Demo",
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
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "0.1.0",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "LSMinimumSystemVersion": "15.0",
                "CFBundleLocalizations": ["en", "zh-Hans"],
                "CFBundleDevelopmentRegion": "en",
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "Client", path: "../Client"),
                .external(name: "Textual"),
                .external(name: "AISDKJSONSchema"),
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
