import SwiftUI

struct DashboardView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("app.dashboard.section.today") {
                LabeledContent("app.common.requests", value: "\(state.stats.todayRequests)")
                LabeledContent("app.common.tokens", value: "\(state.stats.todayTokens)")
                LabeledContent(
                    "app.common.cost",
                    value: String(format: String(localized: "app.common.cost.format"), locale: .current, state.stats.todayCost)
                )
            }
            Section("app.dashboard.section.month") {
                LabeledContent("app.common.requests", value: "\(state.stats.monthRequests)")
                LabeledContent("app.common.tokens", value: "\(state.stats.monthTokens)")
                LabeledContent(
                    "app.common.cost",
                    value: String(format: String(localized: "app.common.cost.format"), locale: .current, state.stats.monthCost)
                )
            }
            Section("app.dashboard.section.service") {
                LabeledContent("app.dashboard.service.status", value: state.isServiceConnected ? String(localized: "app.dashboard.service.connected") : String(localized: "app.dashboard.service.disconnected"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("app.dashboard.title")
    }
}
