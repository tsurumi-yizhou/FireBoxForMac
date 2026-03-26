import SwiftUI

struct ProvidersView: View {
    @Bindable var state: AppState
    @State private var showingAddProvider = false
    @State private var modelEditorProviderServiceID: Int32?

    var body: some View {
        Form {
            Section {
                ForEach(state.providers) { provider in
                    ProviderRow(
                        state: state,
                        provider: provider,
                        onOpenModelEditor: { modelEditorProviderServiceID = provider.serviceID }
                    )
                }
            } header: {
                Text("app.providers.configuredProviders")
            } footer: {
                if state.providers.isEmpty {
                    Text("app.providers.noProviders")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("app.providers.title")
        .toolbar {
            Button {
                showingAddProvider = true
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "app.providers.newProvider"))
            .accessibilityLabel(Text("app.providers.newProvider"))
        }
        .sheet(isPresented: $showingAddProvider) {
            NewProviderSheet(state: state) {
                showingAddProvider = false
            }
        }
        .sheet(
            isPresented: Binding(
                get: { modelEditorProviderServiceID != nil },
                set: { isPresented in if !isPresented { modelEditorProviderServiceID = nil } }
            )
        ) {
            if let provider = state.providers.first(where: { $0.serviceID == modelEditorProviderServiceID }) {
                ProviderModelSheet(state: state, provider: provider) {
                    modelEditorProviderServiceID = nil
                }
            }
        }
    }
}

private struct ProviderRow: View {
    @Bindable var state: AppState
    @Bindable var provider: Provider
    var onOpenModelEditor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("app.common.name", text: $provider.name)
            Picker("app.common.type", selection: $provider.type) {
                ForEach(ProviderType.allCases) { type in
                    Text(type.localizedName).tag(type)
                }
            }
            .disabled(true)

            TextField("app.providers.baseURL", text: $provider.baseURL)
            SecureField("app.providers.apiKey", text: $provider.apiKey)

            HStack {
                Button("app.providers.saveProvider") {
                    Task {
                        await state.updateProvider(provider, includeApiKey: true)
                    }
                }
                Button("app.providers.saveEnabledModels", action: onOpenModelEditor)
                Button(role: .destructive) {
                    Task {
                        await state.deleteProvider(provider)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .help(String(localized: "app.common.delete"))
                .accessibilityLabel(Text("app.common.delete"))
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ProviderModelSheet: View {
    @Bindable var state: AppState
    @Bindable var provider: Provider
    var onDismiss: () -> Void

    @State private var searchText = ""
    @State private var manualModelName = ""

    private var filteredModels: [ModelInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return provider.models
        }
        return provider.models.filter { model in
            model.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("app.common.search", text: $searchText)
            }
            Section("app.providers.enabledModels") {
                if filteredModels.isEmpty {
                    Text("app.providers.noModelsLoaded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredModels) { model in
                        Toggle(model.name, isOn: Binding(
                            get: { model.enabled },
                            set: { model.enabled = $0 }
                        ))
                    }
                }
            }
            Section {
                HStack {
                    TextField("app.providers.manualModelName", text: $manualModelName)
                    Button {
                        state.addProviderModelManually(
                            providerServiceID: provider.serviceID,
                            modelName: manualModelName
                        )
                        manualModelName = ""
                    } label: {
                        Label("app.providers.manualAddModel", systemImage: "plus.circle")
                    }
                    .disabled(manualModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await state.fetchProviderModels(provider)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("app.common.cancel", action: onDismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("app.common.save") {
                    Task {
                        await state.saveProviderModelSelection(provider)
                        onDismiss()
                    }
                }
            }
        }
    }
}

private struct NewProviderSheet: View {
    @Bindable var state: AppState
    var onDismiss: () -> Void

    @State private var name = ""
    @State private var type: ProviderType = .openAI
    @State private var baseURL = ""
    @State private var apiKey = ""

    var body: some View {
        Form {
            TextField("app.common.name", text: $name)
            Picker("app.common.type", selection: $type) {
                ForEach(ProviderType.allCases) { value in
                    Text(value.localizedName).tag(value)
                }
            }
            TextField("app.providers.baseURL", text: $baseURL)
            SecureField("app.providers.apiKey", text: $apiKey)
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 450, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("app.common.cancel") {
                    onDismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("app.common.save") {
                    Task {
                        await state.addProvider(name: name, type: type, baseURL: baseURL, apiKey: apiKey)
                        onDismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
