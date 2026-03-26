import SwiftUI

struct RouteRulesView: View {
    @Bindable var state: AppState
    @State private var showingAddRule = false
    @State private var editingRuleDraft: RouteRule?

    var body: some View {
        Form {
            Section {
                ForEach(state.routeRules) { rule in
                    RouteRuleCard(
                        rule: rule,
                        providers: state.providers,
                        onEdit: { editingRuleDraft = makeDraft(from: rule) },
                        onDelete: {
                            Task {
                                await state.deleteRoute(rule)
                            }
                        }
                    )
                }
            } footer: {
                if state.routeRules.isEmpty {
                    Text("app.routes.noRules")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("app.routes.title")
        .toolbar {
            Button {
                showingAddRule = true
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "app.routes.newRule"))
            .accessibilityLabel(Text("app.routes.newRule"))
        }
        .sheet(isPresented: $showingAddRule) {
            RouteRuleEditorSheet(
                state: state,
                providers: state.providers,
                isNew: true,
                initialRule: RouteRule(candidates: [CandidateTarget()]),
                onDismiss: { showingAddRule = false }
            )
        }
        .sheet(item: $editingRuleDraft) { draft in
            RouteRuleEditorSheet(
                state: state,
                providers: state.providers,
                isNew: false,
                initialRule: draft,
                onDismiss: { editingRuleDraft = nil }
            )
        }
    }

    private func makeDraft(from rule: RouteRule) -> RouteRule {
        RouteRule(
            serviceID: rule.serviceID,
            routeId: rule.routeId,
            strategy: rule.strategy,
            capabilityReasoning: rule.capabilityReasoning,
            capabilityToolCalling: rule.capabilityToolCalling,
            inputImage: rule.inputImage,
            inputVideo: rule.inputVideo,
            inputAudio: rule.inputAudio,
            outputImage: rule.outputImage,
            outputVideo: rule.outputVideo,
            outputAudio: rule.outputAudio,
            candidates: rule.candidates.map {
                CandidateTarget(providerServiceID: $0.providerServiceID, modelName: $0.modelName)
            },
            createdAt: rule.createdAt,
            updatedAt: rule.updatedAt
        )
    }
}

private struct RouteRuleCard: View {
    @Bindable var rule: RouteRule
    var providers: [Provider]
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var previewTargets: String {
        if rule.candidates.isEmpty {
            return String(localized: "app.common.none")
        }
        let names = rule.candidates.prefix(3).map { candidate -> String in
            let providerName = providers.first(where: { $0.serviceID == candidate.providerServiceID })?.name ?? "?"
            return "\(providerName) / \(candidate.modelName)"
        }
        return names.joined(separator: " • ")
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(rule.routeId.isEmpty ? String(localized: "app.common.none") : rule.routeId)
                        .font(.headline)
                    Spacer()
                    Text(rule.strategy.localizedName)
                        .foregroundStyle(.secondary)
                }
                Text(previewTargets)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("app.routes.saveRule", action: onEdit)
                    Button("app.routes.deleteRule", role: .destructive, action: onDelete)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct RouteRuleEditorSheet: View {
    @Bindable var state: AppState
    var providers: [Provider]
    var isNew: Bool
    var onDismiss: () -> Void

    @State private var rule: RouteRule

    init(
        state: AppState,
        providers: [Provider],
        isNew: Bool,
        initialRule: RouteRule,
        onDismiss: @escaping () -> Void
    ) {
        self._state = Bindable(state)
        self.providers = providers
        self.isNew = isNew
        self.onDismiss = onDismiss
        self._rule = State(initialValue: RouteRule(
            serviceID: initialRule.serviceID,
            routeId: initialRule.routeId,
            strategy: initialRule.strategy,
            capabilityReasoning: initialRule.capabilityReasoning,
            capabilityToolCalling: initialRule.capabilityToolCalling,
            inputImage: initialRule.inputImage,
            inputVideo: initialRule.inputVideo,
            inputAudio: initialRule.inputAudio,
            outputImage: initialRule.outputImage,
            outputVideo: initialRule.outputVideo,
            outputAudio: initialRule.outputAudio,
            candidates: initialRule.candidates.map {
                CandidateTarget(providerServiceID: $0.providerServiceID, modelName: $0.modelName)
            },
            createdAt: initialRule.createdAt,
            updatedAt: initialRule.updatedAt
        ))
    }

    var body: some View {
        Form {
            TextField("app.routes.routeID", text: $rule.routeId)
            Picker("app.routes.strategy", selection: $rule.strategy) {
                ForEach(RouteStrategy.allCases) { strategy in
                    Text(strategy.localizedName).tag(strategy)
                }
            }

            Section("app.routes.capabilities") {
                Toggle("app.routes.reasoning", isOn: $rule.capabilityReasoning)
                Toggle("app.routes.toolCalling", isOn: $rule.capabilityToolCalling)
            }

            Section("app.routes.multimodalInput") {
                Toggle("app.common.image", isOn: $rule.inputImage)
                Toggle("app.common.video", isOn: $rule.inputVideo)
                Toggle("app.common.audio", isOn: $rule.inputAudio)
            }

            Section("app.routes.multimodalOutput") {
                Toggle("app.common.image", isOn: $rule.outputImage)
                Toggle("app.common.video", isOn: $rule.outputVideo)
                Toggle("app.common.audio", isOn: $rule.outputAudio)
            }

            Section("app.routes.candidateTargets") {
                ForEach(rule.candidates) { candidate in
                    CandidateTargetRow(state: state, candidate: candidate, providers: providers)
                }
                .onDelete { indices in
                    rule.candidates.remove(atOffsets: indices)
                }
                Button("app.routes.addTarget") {
                    rule.candidates.append(CandidateTarget())
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("app.common.cancel", action: onDismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("app.common.save") {
                    Task {
                        if isNew {
                            await state.addRoute(rule)
                        } else {
                            await state.updateRoute(rule)
                        }
                        onDismiss()
                    }
                }
                .disabled(rule.routeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct CandidateTargetRow: View {
    @Bindable var state: AppState
    @Bindable var candidate: CandidateTarget
    var providers: [Provider]

    private var selectedProvider: Provider? {
        guard let providerServiceID = candidate.providerServiceID else { return nil }
        return providers.first(where: { $0.serviceID == providerServiceID })
    }

    private var modelOptions: [String] {
        (selectedProvider?.models ?? [])
            .filter(\.enabled)
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        HStack {
            Picker("app.common.provider", selection: $candidate.providerServiceID) {
                Text("app.common.none").tag(nil as Int32?)
                ForEach(providers) { provider in
                    Text(provider.name).tag(provider.serviceID as Int32?)
                }
            }
            if modelOptions.isEmpty {
                Text("app.routes.noEnabledModels")
                    .foregroundStyle(.secondary)
            } else {
                Picker("app.common.model", selection: $candidate.modelName) {
                    ForEach(modelOptions, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }
        }
        .task(id: candidate.providerServiceID) {
            await state.ensureProviderModelsLoaded(providerServiceID: candidate.providerServiceID)
            if let firstModel = modelOptions.first, !modelOptions.contains(candidate.modelName) {
                candidate.modelName = firstModel
            }
        }
        .onChange(of: candidate.providerServiceID) {
            if modelOptions.isEmpty {
                candidate.modelName = ""
            } else if !modelOptions.contains(candidate.modelName), let firstModel = modelOptions.first {
                candidate.modelName = firstModel
            }
        }
    }
}
