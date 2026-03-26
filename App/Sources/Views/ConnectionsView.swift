import SwiftUI

struct ConnectionsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("app.connections.section.realtime") {
                LabeledContent("app.connections.activeConnections", value: "\(state.activeConnections)")
            }

            Section("app.connections.section.details") {
                ForEach(state.connections) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("app.connections.connectionId", value: "\(entry.connectionId)")
                        LabeledContent("app.common.caller", value: entry.caller.friendlyLabel)
                        LabeledContent("app.connections.connectedAt", value: entry.connectedAt.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("app.common.requestCount", value: "\(entry.requestCount)")
                        LabeledContent("app.connections.activeStream", value: entry.hasActiveStream ? String(localized: "app.common.yes") : String(localized: "app.common.no"))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("app.connections.title")
    }
}
