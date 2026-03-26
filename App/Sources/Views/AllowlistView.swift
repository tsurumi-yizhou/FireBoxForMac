import SwiftUI

struct AllowlistView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                ForEach(state.allowlist) { entry in
                    VStack(alignment: .leading) {
                        LabeledContent("app.common.caller", value: entry.caller.friendlyLabel)
                        LabeledContent("app.allowlist.firstSeen", value: entry.firstSeenAt.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("app.allowlist.lastSeen", value: entry.lastSeenAt.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("app.common.requestCount", value: "\(entry.requestCount)")
                        if let deniedUntilUtc = entry.deniedUntilUtc {
                            LabeledContent("app.allowlist.deniedUntil", value: deniedUntilUtc.formatted(date: .abbreviated, time: .standard))
                        }
                        Toggle("app.allowlist.allowed", isOn: Binding(
                            get: { entry.allowed },
                            set: { newValue in
                                Task {
                                    await state.updateClientAccess(entry, allowed: newValue)
                                }
                            }
                        ))
                    }
                    .padding(4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("app.allowlist.title")
    }
}
