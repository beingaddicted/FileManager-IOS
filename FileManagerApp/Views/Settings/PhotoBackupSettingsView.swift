import SwiftUI

// MARK: - Photo Backup Settings
//
// Configure where the Camera Roll is auto-uploaded. Picks one of the user's
// saved server connections, lets them choose folder layout, and triggers an
// on-demand sync run.

struct PhotoBackupSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel
    @StateObject private var service = PhotoBackupService.shared
    @State private var draft: PhotoBackupConfig = .disabled
    @State private var didLoad = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Photo Backup", isOn: $draft.enabled)
                if draft.enabled {
                    Picker("Server", selection: connectionBinding) {
                        Text("None").tag(UUID?.none)
                        ForEach(eligibleConnections) { conn in
                            Text(conn.displayName).tag(Optional(conn.id))
                        }
                    }
                    HStack {
                        Text("Target folder").foregroundStyle(.secondary)
                        Spacer()
                        TextField("/Photos/iPhone", text: $draft.targetPath)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
            } header: {
                Text("Destination")
            } footer: {
                if eligibleConnections.isEmpty {
                    Text("Add a SMB, SFTP, or WebDAV server first.")
                } else {
                    Text("Photos are uploaded once; we track which assets have already synced so re-runs are fast.")
                }
            }

            if draft.enabled {
                Section("What to back up") {
                    ForEach(PhotoBackupConfig.Kind.allCases) { kind in
                        Toggle(kind.displayName, isOn: kindBinding(for: kind))
                    }
                }

                Section("Folder layout") {
                    Picker("Layout", selection: $draft.folderLayout) {
                        ForEach(PhotoBackupConfig.FolderLayout.allCases) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }
                }

                Section("Network") {
                    Toggle("Wi-Fi only", isOn: $draft.wifiOnly)
                }

                Section {
                    Button {
                        runNow()
                    } label: {
                        if service.isRunning {
                            HStack {
                                ProgressView()
                                Text("Syncing… \(service.uploadedCount) of \(service.uploadedCount + service.pendingCount)")
                            }
                        } else {
                            Label("Run Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(service.isRunning || draft.connectionId == nil)
                    if service.isRunning {
                        Button(role: .destructive) {
                            service.cancel()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    }
                    if let last = service.lastRun {
                        HStack {
                            Text("Last run").foregroundStyle(.secondary)
                            Spacer()
                            Text(last.shortDescription)
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if let err = service.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Status")
                }
            }
        }
        .navigationTitle("Photo Backup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !didLoad {
                draft = service.config
                didLoad = true
            }
        }
        .onChange(of: draft) { service.updateConfig($0) }
    }

    // MARK: - Helpers

    private var eligibleConnections: [ServerConnection] {
        appState.connections.filter { $0.type.providerType.isNetwork }
    }

    private var connectionBinding: Binding<UUID?> {
        Binding(
            get: { draft.connectionId },
            set: { draft.connectionId = $0 }
        )
    }

    private func kindBinding(for kind: PhotoBackupConfig.Kind) -> Binding<Bool> {
        Binding(
            get: { draft.kinds.contains(kind) },
            set: { isOn in
                if isOn {
                    if !draft.kinds.contains(kind) { draft.kinds.append(kind) }
                } else {
                    draft.kinds.removeAll { $0 == kind }
                }
            }
        )
    }

    private func runNow() {
        guard let connId = draft.connectionId,
              let conn = appState.connections.first(where: { $0.id == connId }) else { return }
        Task {
            // Make sure we're connected; otherwise try to connect first.
            let provider: FileProvider? = connVM.provider(for: conn) ?? (await connVM.connect(to: conn))
            guard let provider else { return }
            await service.runOnce(using: provider, connection: conn)
        }
    }
}

// MARK: - Offline Pins View

struct OfflinePinsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel
    @StateObject private var service = OfflinePinService.shared

    var body: some View {
        List {
            if service.pins.isEmpty {
                Text("Long-press any folder or file in your servers and choose **Pin Offline** to keep a synced local copy.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(service.pins) { pin in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: pin.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(pin.displayName)
                                    Text(pin.connectionName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let date = pin.lastSyncedAt {
                                    Text(date.relativeDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("Not synced")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(pin.remotePath)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                service.removePin(pin)
                            } label: {
                                Label("Remove", systemImage: "pin.slash")
                            }
                        }
                    }
                } header: {
                    Text("Pinned items (\(service.pins.count))")
                }
            }

            Section {
                Button {
                    syncAll()
                } label: {
                    if service.isSyncing {
                        HStack {
                            ProgressView()
                            Text("Syncing…")
                        }
                    } else {
                        Label("Sync All Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(service.isSyncing || service.pins.isEmpty)
                if let err = service.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Offline Files")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func syncAll() {
        Task {
            for conn in appState.connections {
                guard service.pins.contains(where: { $0.connectionId == conn.id }) else { continue }
                let provider: FileProvider? = connVM.provider(for: conn) ?? (await connVM.connect(to: conn))
                guard let provider else { continue }
                await service.sync(connection: conn, provider: provider)
            }
        }
    }
}
