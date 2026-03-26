import SwiftUI
import Client

@main
struct DemoApp: App {
    @State private var state = DemoState()

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SessionListView(state: state)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 220)
            } detail: {
                if let session = state.selectedSession {
                    ChatView(state: state, session: session, availableModels: state.availableModels)
                } else {
                    Text("demo.placeholder.selectOrCreateSession")
                }
            }
            .task {
                await state.bootstrap()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {}
            .formStyle(.grouped)
            .frame(minWidth: 400, minHeight: 300)
            .navigationTitle("demo.settings.title")
    }
}
