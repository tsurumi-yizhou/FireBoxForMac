import SwiftUI

struct SessionListView: View {
    @Bindable var state: DemoState

    var body: some View {
        List(selection: $state.selectedSessionID) {
            ForEach(state.sessions) { session in
                Text(session.title)
                    .tag(session.id)
                    .contextMenu {
                        Button("demo.common.delete", role: .destructive) {
                            state.deleteSession(session)
                        }
                    }
            }
        }
        .toolbar {
            Button(action: { _ = state.createSession() }) {
                Image(systemName: "square.and.pencil")
            }
        }
        .navigationTitle("demo.sessions.title")
    }
}
