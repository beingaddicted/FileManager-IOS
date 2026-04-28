import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showClearRecentsConfirm = false
    @State private var showClearCacheConfirm   = false
    @State private var cacheSize: String       = "Calculating…"
    @State private var showFolderPicker        = false
    @State private var folderAccessError: String?
    @State private var externalFoldersRevision = 0

    private var externalFolders: [(name: String, path: String)] {
        _ = externalFoldersRevision
        return LocalFileService.externalFolderRoots()
    }

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

                Section {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Add Folder From Files", systemImage: "folder.badge.plus")
                    }

                    if externalFolders.isEmpty {
                        Text("No extra folders added yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(externalFolders, id: \.path) { folder in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name)
                                    Text(folder.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    LocalFileService.removeExternalFolder(path: folder.path)
                                    externalFoldersRevision += 1
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }

                    if let folderAccessError {
                        Label(folderAccessError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Local Folder Access")
                } footer: {
                    Text("iOS sandbox limits direct device-wide access. Add folders from Files app to browse them in Local.")
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
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let granted = url.startAccessingSecurityScopedResource()
                    defer {
                        if granted {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    do {
                        try LocalFileService.addExternalFolderBookmark(url: url)
                        folderAccessError = nil
                        externalFoldersRevision += 1
                    } catch {
                        folderAccessError = "Could not save access to selected folder."
                    }
                case .failure(let error):
                    folderAccessError = error.localizedDescription
                }
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

    @State private var selectedSection: HistorySection = .recents

    private var displayedItems: [FileItem] {
        switch selectedSection {
        case .recents:
            return appState.recentFiles
        case .favorites:
            return appState.favorites
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if displayedItems.isEmpty {
                    emptyView
                } else {
                    List {
                        Section {
                            Picker("Section", selection: $selectedSection) {
                                ForEach(HistorySection.allCases, id: \.self) { section in
                                    Text(section.title).tag(section)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        ForEach(displayedItems) { item in
                            FileRowView(
                                item:          item,
                                isSelected:    false,
                                showThumbnail: appState.thumbnailsEnabled
                            )
                        }
                        .onDelete { offsets in
                            switch selectedSection {
                            case .recents:
                                offsets.forEach { i in
                                    let _ = appState.recentFiles.remove(at: i)
                                }
                            case .favorites:
                                offsets.forEach { i in
                                    let _ = appState.favorites.remove(at: i)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(selectedSection == .recents ? "Recent Files" : "Favorites")
            .toolbar {
                if !displayedItems.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear") {
                            if selectedSection == .recents {
                                appState.clearRecents()
                            } else {
                                appState.favorites.removeAll()
                            }
                        }
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
            Text(selectedSection == .recents ? "No Recent Files" : "No Favorites Yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(selectedSection == .recents ? "Files you open will appear here." : "Mark files as favorites from the file browser.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum HistorySection: CaseIterable, Hashable {
    case recents
    case favorites

    var title: String {
        switch self {
        case .recents:
            return "Recents"
        case .favorites:
            return "Favorites"
        }
    }
}
