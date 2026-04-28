import SwiftUI

// MARK: - Content View (Root)

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel
    @State private var didAppear = false

    var body: some View {
        Group {
            if didAppear {
                TabView(selection: $appState.selectedTab) {
                    // MARK: Local
                    NavigationStack {
                        FileBrowserView(vm: connVM.makeLocalBrowser())
                    }
                    .tabItem {
                        Label("Local", systemImage: "internaldrive.fill")
                    }
                    .tag(AppTab.local)

                    // MARK: Network
                    ConnectionsListView()
                        .tabItem {
                            Label("Network", systemImage: "network")
                        }
                        .tag(AppTab.network)

                    // MARK: Cloud
                    CloudDashboardView()
                        .tabItem {
                            Label("Cloud", systemImage: "cloud.fill")
                        }
                        .tag(AppTab.cloud)

                    // MARK: Recents
                    RecentsView()
                        .tabItem {
                            Label("Recents", systemImage: "clock.fill")
                        }
                        .tag(AppTab.recents)

                    // MARK: Settings
                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                        .tag(AppTab.settings)
                }
            } else {
                ProgressView("Starting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(appState.theme.colorScheme)
        .errorAlert(error: $appState.alertError)
        .sheet(item: $appState.incomingPreviewItem) { item in
            NavigationStack {
                UniversalPreviewView(item: item, provider: connVM.makeLocalBrowser())
            }
        }
        .onAppear {
            if !didAppear {
                didAppear = true
            }
        }
    }
}

// MARK: - Cloud Dashboard

struct CloudDashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel
    @State private var showAddCloudConnection: Bool = false

    var cloudConnections: [ServerConnection] {
        appState.connections.filter { $0.type.isCloud }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // MARK: iCloud
                    CloudProviderCard(
                        title:      "iCloud Drive",
                        subtitle:   "Apple",
                        systemImage: "icloud.fill",
                        tint:       .cyan,
                        isConnected: true
                    ) {
                        NavigationLink("Browse") {
                            FileBrowserView(vm: connVM.makeICloudBrowser())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .controlSize(.small)
                    }

                    // MARK: Saved cloud connections
                    ForEach(cloudConnections) { conn in
                        cloudConnectionCard(conn)
                    }

                    // MARK: Add more
                    Button {
                        showAddCloudConnection = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Cloud Account")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("Cloud")
            .sheet(isPresented: $showAddCloudConnection) {
                AddConnectionView(preferredType: .googleDrive)
            }
        }
    }

    @ViewBuilder
    private func cloudConnectionCard(_ conn: ServerConnection) -> some View {
        let connected = connVM.isConnected(conn)
        CloudProviderCard(
            title:       conn.displayName,
            subtitle:    conn.subtitle,
            systemImage: conn.type.systemImage,
            tint:        conn.type.tintColor,
            isConnected: connected
        ) {
            if connected, let provider = connVM.provider(for: conn) {
                NavigationLink("Browse") {
                    FileBrowserView(vm: connVM.makeBrowser(for: provider, providerType: conn.type.providerType))
                }
                .buttonStyle(.borderedProminent)
                .tint(conn.type.tintColor)
                .controlSize(.small)
            } else {
                Button("Connect") {
                    Task { _ = await connVM.connect(to: conn) }
                }
                .buttonStyle(.borderedProminent)
                .tint(conn.type.tintColor)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Cloud Provider Card

struct CloudProviderCard<Actions: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isConnected: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Circle()
                        .fill(isConnected ? Color.green : Color(.systemGray3))
                        .frame(width: 7, height: 7)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            actions()
        }
        .padding(16)
        .background(Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
    }
}
