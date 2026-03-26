import SwiftUI
import Client

@main
struct MainApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .task {
                    await state.bootstrap()
                }
        }

        Settings {
            TabView {
                GeneralSettingsView(state: state)
                    .tabItem { Label("app.settings.tab.general", systemImage: "gearshape") }
                AboutSettingsView()
                    .tabItem { Label("app.settings.tab.about", systemImage: "info.circle") }
            }
        }
    }
}

enum SidebarItem: CaseIterable, Identifiable {
    case dashboard
    case connections
    case providers
    case routeRules
    case allowlist

    var id: String {
        switch self {
        case .dashboard: return "dashboard"
        case .connections: return "connections"
        case .providers: return "providers"
        case .routeRules: return "route_rules"
        case .allowlist: return "allowlist"
        }
    }

    var localizedTitle: String {
        switch self {
        case .dashboard: return String(localized: "app.sidebar.dashboard")
        case .connections: return String(localized: "app.sidebar.connections")
        case .providers: return String(localized: "app.sidebar.providers")
        case .routeRules: return String(localized: "app.sidebar.routeRules")
        case .allowlist: return String(localized: "app.sidebar.allowlist")
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "chart.bar"
        case .connections: "network"
        case .providers: "server.rack"
        case .routeRules: "arrow.triangle.branch"
        case .allowlist: "checkmark.shield"
        }
    }
}

struct ContentView: View {
    @Bindable var state: AppState
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.localizedTitle, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            switch selection {
            case .dashboard:
                DashboardView(state: state)
            case .connections:
                ConnectionsView(state: state)
            case .providers:
                ProvidersView(state: state)
            case .routeRules:
                RouteRulesView(state: state)
            case .allowlist:
                AllowlistView(state: state)
            case nil:
                Text("app.content.selectItem")
            }
        }
        .toolbar {
            Text(state.isServiceConnected ? String(localized: "app.main.connection.connected") : String(localized: "app.main.connection.disconnected"))
                .foregroundStyle(state.isServiceConnected ? .green : .red)
        }
    }
}
