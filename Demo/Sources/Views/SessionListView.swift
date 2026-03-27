import SwiftUI

struct SessionListView: View {
    @Bindable var state: DemoState
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool

    private var sessionSelection: Binding<UUID?> {
        Binding(
            get: { state.selectedSessionID },
            set: { newValue in
                guard let newValue else { return }
                state.selectSessionFromList(newValue)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("demo.search.placeholder", text: $state.sessionSearchQuery)
                        .textFieldStyle(.plain)
                        .focused($isSearchFieldFocused)
                    if !state.sessionSearchQuery.isEmpty {
                        Button {
                            state.sessionSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            List(selection: sessionSelection) {
                ForEach(state.displayedSessions) { session in
                    Text(session.title)
                        .padding(.vertical, 3)
                        .tag(session.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectSessionFromList(session.id)
                        }
                        .contextMenu {
                            Button("demo.common.delete", role: .destructive) {
                                state.deleteSession(session)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .animation(.easeInOut(duration: 0.18), value: isSearchExpanded)
        .toolbar {
            Button(action: toggleSearch) {
                Image(systemName: "magnifyingglass")
            }
            .help(String(localized: "demo.search.toggle"))

            Button(action: { _ = state.createSession() }) {
                Image(systemName: "square.and.pencil")
            }
        }
        .navigationTitle("demo.sessions.title")
    }

    private func toggleSearch() {
        isSearchExpanded.toggle()
        if isSearchExpanded {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        } else {
            state.sessionSearchQuery = ""
            isSearchFieldFocused = false
        }
    }
}
