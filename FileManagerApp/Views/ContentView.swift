import SwiftUI

// MARK: - Content View (Root)

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            // MARK: Local
            NavigationStack {
                FileBrowserView(vm: connVM.makeLocalBrowser())
            }
            .tabItem { Label("Files", systemImage: "internaldrive.fill") }
            .tag(AppTab.local)

            // MARK: Network (NAS)
            ConnectionsListView()
                .tabItem { Label("Servers", systemImage: "externaldrive.connected.to.line.below.fill") }
                .tag(AppTab.network)

            // MARK: Transfers
            TransfersView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle.fill") }
                .tag(AppTab.transfers)

            // MARK: Recents
            RecentsView()
                .tabItem { Label("Recents", systemImage: "clock.fill") }
                .tag(AppTab.recents)

            // MARK: Settings
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(appState.theme.colorScheme)
        .errorAlert(error: $appState.alertError)
        .sheet(item: $appState.incomingPreviewItem) { item in
            NavigationStack {
                UniversalPreviewView(item: item, provider: connVM.makeLocalBrowser())
            }
        }
    }
}
