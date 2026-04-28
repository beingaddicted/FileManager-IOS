import SwiftUI

// MARK: - Connections List

struct ConnectionsListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel

    @State private var showAddConnection: Bool = false
    @State private var editingConnection: ServerConnection?
    @State private var presentedBrowser: BrowserPresentation?

    var body: some View {
        NavigationStack {
            List {
                // MARK: Built-in
                Section("Built-in") {
                    builtInRow(
                        title:  "On This Device",
                        image:  "internaldrive.fill",
                        color:  .blue,
                        dest:   { localBrowserView }
                    )
                    builtInRow(
                        title:  "iCloud Drive",
                        image:  "icloud.fill",
                        color:  .cyan,
                        dest:   { iCloudBrowserView }
                    )
                }

                // MARK: Saved connections
                if !appState.connections.isEmpty {
                    Section("Saved Connections") {
                        ForEach(appState.connections) { conn in
                            connectionRow(conn)
                        }
                        .onDelete { appState.removeConnections(at: $0) }
                    }
                }

                // MARK: UPnP discovery
                Section {
                    NavigationLink {
                        UPnPDiscoveryView()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.red.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "tv.fill")
                                    .foregroundStyle(.red)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("UPnP / DLNA")
                                    .font(.body)
                                Text("Discover media servers on your network")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Media Servers")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddConnection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddConnection) {
                AddConnectionView()
            }
            .sheet(item: $editingConnection) { conn in
                AddConnectionView(existing: conn)
            }
            .sheet(item: $presentedBrowser) { destination in
                NavigationStack {
                    FileBrowserView(vm: destination.viewModel)
                }
            }
        }
    }

    // MARK: - Built-in row

    @ViewBuilder
    private func builtInRow<Dest: View>(
        title: String,
        image: String,
        color: Color,
        @ViewBuilder dest: @escaping () -> Dest
    ) -> some View {
        NavigationLink {
            dest()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: image)
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.body)
            }
        }
    }

    // MARK: - Connection row

    @ViewBuilder
    private func connectionRow(_ conn: ServerConnection) -> some View {
        let connected = connVM.isConnected(conn)
        let state     = connVM.connectionStates[conn.id]

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(conn.type.tintColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                if case .connecting = state {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: conn.type.systemImage)
                        .foregroundStyle(conn.type.tintColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conn.displayName)
                    .font(.body)
                Text(conn.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status dot
            Circle()
                .fill(connected ? Color.green : Color(.systemGray4))
                .frame(width: 8, height: 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if connected, let provider = connVM.provider(for: conn) {
                presentBrowser(provider: provider, conn: conn)
            } else {
                connect(conn)
            }
        }
        .contextMenu {
            Button {
                connect(conn)
            } label: {
                Label(connected ? "Reconnect" : "Connect",
                      systemImage: connected ? "arrow.clockwise" : "network")
            }

            if connected {
                Button(role: .destructive) {
                    connVM.disconnect(from: conn)
                } label: {
                    Label("Disconnect", systemImage: "network.slash")
                }
            }

            Divider()

            Button {
                editingConnection = conn
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive) {
                appState.removeConnection(conn)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // MARK: - Navigation helpers

    @ViewBuilder private var localBrowserView: some View {
        let browser = connVM.makeLocalBrowser()
        FileBrowserView(vm: browser)
    }

    @ViewBuilder private var iCloudBrowserView: some View {
        let browser = connVM.makeICloudBrowser()
        FileBrowserView(vm: browser)
    }

    private func connect(_ conn: ServerConnection) {
        Task {
            if let provider = await connVM.connect(to: conn) {
                presentBrowser(provider: provider, conn: conn)
            }
        }
    }

    private func presentBrowser(provider: FileProvider, conn: ServerConnection) {
        appState.activeConnection = conn
        presentedBrowser = BrowserPresentation(
            id: conn.id,
            viewModel: connVM.makeBrowser(for: provider, providerType: conn.type.providerType)
        )
    }
}

private struct BrowserPresentation: Identifiable {
    let id: UUID
    let viewModel: FileBrowserViewModel
}

// MARK: - UPnP Discovery View

struct UPnPDiscoveryView: View {
    @StateObject private var discovery = NetworkDiscovery.shared
    @EnvironmentObject var connVM: ConnectionViewModel

    var body: some View {
        List {
            if discovery.isDiscovering {
                Section {
                    HStack {
                        ProgressView()
                        Text("Scanning network…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }
            }

            if discovery.discoveredDevices.isEmpty && !discovery.isDiscovering {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("No devices found")
                            .foregroundStyle(.secondary)
                        Text("Make sure UPnP devices are on the same Wi-Fi network.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            ForEach(discovery.discoveredDevices) { device in
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.red.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: "tv.fill")
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.friendlyName)
                                .font(.body)
                            Text(device.modelName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.manufacturer)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("UPnP / DLNA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if discovery.isDiscovering {
                        discovery.stopDiscovery()
                    } else {
                        discovery.startDiscovery()
                    }
                } label: {
                    Image(systemName: discovery.isDiscovering ? "stop.circle" : "arrow.clockwise")
                }
            }
        }
        .task {
            discovery.startDiscovery()
        }
    }
}
