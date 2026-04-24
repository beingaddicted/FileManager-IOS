import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showClearRecentsConfirm = false
    @State private var showClearCacheConfirm   = false
    @State private var cacheSize: String       = "Calculating…"

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Appearance
                Section("Appearance") {
                    Picker("Theme", selection: $appState.theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.rawValue.capitalized).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Default View", selection: $appState.viewMode) {
                        Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                        Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    }
                }

                // MARK: Browser
                Section("Browser") {
                    Picker("Sort By", selection: $appState.sortField) {
                        ForEach(SortField.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }

                    Toggle(isOn: $appState.sortAscending) {
                        Label("Sort Ascending", systemImage: appState.sortAscending ? "chevron.up" : "chevron.down")
                    }

                    Toggle(isOn: $appState.showHiddenFiles) {
                        Label("Show Hidden Files", systemImage: "eye.slash")
                    }

                    Toggle(isOn: $appState.thumbnailsEnabled) {
                        Label("Show Thumbnails", systemImage: "photo")
                    }

                    Toggle(isOn: $appState.previewOnTap) {
                        Label("Preview on Tap", systemImage: "hand.tap")
                    }
                }

                // MARK: Cache
                Section {
                    HStack {
                        Label("Cache Size", systemImage: "internaldrive")
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label("Clear Thumbnail Cache", systemImage: "trash")
                    }
                } header: {
                    Text("Storage")
                }

                // MARK: Recents
                Section {
                    HStack {
                        Label("Recent Files", systemImage: "clock")
                        Spacer()
                        Text("\(appState.recentFiles.count)")
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showClearRecentsConfirm = true
                    } label: {
                        Label("Clear Recent Files", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("History")
                }

                // MARK: Protocol support
                Section {
                    protocolRow("FTP",          image: "network",          color: .orange,  supported: true)
                    protocolRow("SFTP (SSH)",   image: "lock.shield.fill", color: .purple,  supported: true,  note: "Requires NMSSH pod")
                    protocolRow("WebDAV",       image: "globe",            color: .teal,    supported: true)
                    protocolRow("SMB",          image: "desktopcomputer",  color: .gray,    supported: false, note: "Requires AMSMB2 pod")
                    protocolRow("UPnP / DLNA",  image: "tv.fill",          color: .red,     supported: true)
                    protocolRow("iCloud Drive", image: "icloud.fill",      color: .cyan,    supported: true)
                    protocolRow("Google Drive", image: "square.stack.3d.up.fill", color: .green, supported: true)
                    protocolRow("Dropbox",      image: "shippingbox.fill", color: .blue,    supported: true)
                    protocolRow("OneDrive",     image: "cloud.fill",       color: .blue,    supported: true)
                } header: {
                    Text("Protocol Support")
                }

                // MARK: About
                Section("About") {
                    HStack {
                        Text("All-In-One File Manager")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text("2025.1")
                            .foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://github.com/beingaddicted/filemanager-ios")!) {
                        Label("GitHub Repository", systemImage: "link")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .alert("Clear Recent Files?", isPresented: $showClearRecentsConfirm) {
                Button("Clear", role: .destructive) { appState.clearRecents() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Clear Thumbnail Cache?", isPresented: $showClearCacheConfirm) {
                Button("Clear", role: .destructive) {
                    ThumbnailService.shared.clearCache()
                    cacheSize = "0 KB"
                }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                cacheSize = await calculateCacheSize()
            }
        }
    }

    // MARK: - Protocol row

    private func protocolRow(
        _ name: String,
        image: String,
        color: Color,
        supported: Bool,
        note: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: image)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let note = note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: supported ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(supported ? .green : .orange)
        }
    }

    // MARK: - Cache size

    private func calculateCacheSize() async -> String {
        let cacheURL = FileManager.default.cachesDirectory
        let size = await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: [.fileSizeKey]
            ).compactMap {
                (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }.reduce(0, +)) ?? 0
        }.value
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Recents View

struct RecentsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel

    @State private var previewItem: FileItem?

    var body: some View {
        NavigationStack {
            Group {
                if appState.recentFiles.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(appState.recentFiles) { item in
                            Button {
                                previewItem = item
                            } label: {
                                FileRowView(
                                    item:          item,
                                    isSelected:    false,
                                    showThumbnail: appState.thumbnailsEnabled
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.forEach { i in
                                let _ = appState.recentFiles.remove(at: i)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recent Files")
            .toolbar {
                if !appState.recentFiles.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear") { appState.clearRecents() }
                    }
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No Recent Files")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Files you open will appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
