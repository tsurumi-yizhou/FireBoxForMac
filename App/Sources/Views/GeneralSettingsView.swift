import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("app.general.quickToolModel") {
                Picker("app.common.provider", selection: $state.quickToolProviderID) {
                    Text("app.common.none").tag(nil as Int32?)
                    ForEach(state.providers) { provider in
                        Text(provider.name).tag(provider.serviceID as Int32?)
                    }
                }
                TextField("app.common.model", text: $state.quickToolModel)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("app.general.title")
    }
}
