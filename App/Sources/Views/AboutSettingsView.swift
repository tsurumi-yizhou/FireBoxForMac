import SwiftUI

struct AboutSettingsView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FireBox"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "app.common.none")
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "app.common.none")
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? String(localized: "app.common.none")
    }

    var body: some View {
        Form {
            Section("app.about.section.app") {
                LabeledContent("app.about.name", value: appName)
                LabeledContent("app.about.version", value: appVersion)
                LabeledContent("app.about.build", value: appBuild)
                LabeledContent("app.about.bundleId", value: bundleID)
            }
        }
            .formStyle(.grouped)
            .navigationTitle("app.about.title")
    }
}
