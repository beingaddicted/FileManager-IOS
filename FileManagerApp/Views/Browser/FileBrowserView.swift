import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Browser View

struct FileBrowserView: View {
    @ObservedObject var vm: FileBrowserViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel

    @State private var selectedItem: FileItem?
    @State private var previewItem: FileItem?
    @State private var renameItem: FileItem?
    @State private var newName: String = ""
    @State private var showNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var showFilePicker: Bool = false
    @State private var showFolderPicker: Bool = false
    @State private var showSystemBrowserPicker: Bool = false
    @State private var showSortMenu: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var itemToDelete: FileItem?
    @State private var shareURL: URL?
    @State private var showShareSheet: Bool = false
    @State private var systemPreviewItem: FileItem?

    @Environment(\.dismiss) private var dismiss

    // MARK: - Grid layout

    private let gridColumns = [
        GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 12)
    ]

    var body: some View {
        ZStack {
            // MARK: Content
            VStack(spacing: 0) {
                if vm.breadcrumbs.count > 1 {
                    breadcrumbBar
                }

                Group {
                    if vm.isLoading && vm.items.isEmpty {
                        loadingView
                    } else if vm.filteredItems.isEmpty && !vm.isLoading {
                        emptyView
                    } else {
                        contentView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Transfer overlay
            if !vm.transferTasks.filter({ $0.state == .active }).isEmpty {
                transferOverlay
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .searchable(text: $vm.searchText, placement: .navigationBarDrawer, prompt: "Search files…")
        .refreshable { await vm.refresh() }
        .task { await vm.loadDirectory() }
        .errorAlert(error: $vm.error)
        .sheet(item: $previewItem) { item in
            UniversalPreviewView(item: item, provider: vm)
        }
        .sheet(item: $systemPreviewItem) { item in
            UniversalPreviewView(item: item, provider: connVM.makeLocalBrowser())
        }
        .alert("Rename", isPresented: .init(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField("New name", text: $newName)
            Button("Rename") {
                guard let item = renameItem, !newName.isBlank else { return }
                Task { await vm.rename(item, to: newName) }
                renameItem = nil
            }
            Button("Cancel", role: .cancel) { renameItem = nil }
        } message: {
            Text("Enter a new name for \"\(renameItem?.name ?? "")\"")
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                guard !newFolderName.isBlank else { return }
                Task { await vm.createFolder(named: newFolderName) }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Delete \(itemToDelete?.name ?? "selected items")?",
               isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                // Capture before clearing: the Task runs later, so `itemToDelete` would already be nil.
                let single = itemToDelete
                itemToDelete = nil
                Task {
                    if let item = single {
                        await vm.delete(item)
                    } else {
                        await vm.deleteSelected()
                    }
                }
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    let ok = url.startAccessingSecurityScopedResource()
                    Task {
                        await vm.upload(url: url)
                        if ok { url.stopAccessingSecurityScopedResource() }
                    }
                }
            case .failure(let err):
                vm.error = err.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folderURL = urls.first else { return }
                let ok = folderURL.startAccessingSecurityScopedResource()
                defer {
                    if ok { folderURL.stopAccessingSecurityScopedResource() }
                }
                do {
                    try LocalFileService.addExternalFolderBookmark(url: folderURL)
                    Task { await vm.refresh() }
                } catch {
                    vm.error = "Could not save folder access."
                }
            case .failure(let err):
                vm.error = err.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showSystemBrowserPicker,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let picked = urls.first else { return }
                handleSystemPickedURL(picked)
            case .failure(let err):
                vm.error = err.localizedDescription
            }
        }
    }

    // MARK: - Breadcrumb bar

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.breadcrumbs.indices, id: \.self) { i in
                    let crumb = vm.breadcrumbs[i]
                    Button {
                        if crumb.path != vm.currentPath {
                            vm.navigate(to: crumb.path)
                        }
                    } label: {
                        Text(crumb.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(crumb.path == vm.currentPath ? .primary : .secondary)

                    if i < vm.breadcrumbs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Content view

    private var contentView: some View {
        Group {
            if shouldShowLocalHome {
                localHomeContent
            } else if appState.viewMode == .list {
                listContent
            } else {
                gridContent
            }
        }
        .animation(.spring(duration: 0.3), value: vm.filteredItems.map(\.id))
    }

    private var shouldShowLocalHome: Bool {
        vm.providerType == .local &&
        vm.currentPath == "/" &&
        vm.searchText.isEmpty &&
        !vm.isSelecting
    }

    private var rootLocationItems: [FileItem] {
        vm.filteredItems
            .filter { !$0.path.hasPrefix(LocalFileService.smartRootPrefix) }
            .filter { !appState.isPinnedLocalLocation(path: $0.path) }
    }

    private var rootQuickAccessItems: [FileItem] {
        vm.filteredItems
            .filter { $0.path.hasPrefix(LocalFileService.smartRootPrefix) }
            .filter { !appState.isPinnedLocalLocation(path: $0.path) }
    }

    private var pinnedLocalItems: [FileItem] {
        let byPath = Dictionary(uniqueKeysWithValues: vm.filteredItems.map { ($0.path, $0) })
        return appState.localPinnedLocations.compactMap { pin in
            if let item = byPath[pin.path] {
                return item
            }
            return FileItem(
                id: pin.path,
                name: pin.name,
                path: pin.path,
                size: 0,
                modifiedDate: Date(),
                isDirectory: true,
                isHidden: false,
                isSymlink: false,
                itemType: .folder,
                providerType: .local
            )
        }
    }

    private var localHomeContent: some View {
        List {
            if !pinnedLocalItems.isEmpty {
                Section("Pinned (\(pinnedLocalItems.count))") {
                    ForEach(pinnedLocalItems) { item in
                        locationShortcutRow(item)
                    }
                    .onMove { source, destination in
                        appState.movePinnedLocalLocations(from: source, to: destination)
                    }
                }
            }

            if !rootLocationItems.isEmpty {
                Section("Locations (\(rootLocationItems.count))") {
                    ForEach(rootLocationItems) { item in
                        locationShortcutRow(item)
                    }
                }
            }

            if !rootQuickAccessItems.isEmpty {
                Section("Quick Access (\(rootQuickAccessItems.count))") {
                    ForEach(rootQuickAccessItems) { item in
                        locationShortcutRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func locationShortcutRow(_ item: FileItem) -> some View {
        HStack(spacing: 12) {
            Button {
                handleTap(item)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(item.accentColor)
                        .font(.title3)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .foregroundStyle(.primary)
                        Text(item.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            Button {
                appState.togglePinnedLocalLocation(item)
            } label: {
                Image(systemName: appState.isPinnedLocalLocation(path: item.path) ? "pin.fill" : "pin")
                    .foregroundStyle(appState.isPinnedLocalLocation(path: item.path) ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - List

    private var listContent: some View {
        Group {
            if vm.isSelecting {
                List(vm.filteredItems, id: \.id, selection: $vm.selectedItems) { item in
                    FileRowView(
                        item:          item,
                        isSelected:    vm.selectedItems.contains(item),
                        showThumbnail: appState.thumbnailsEnabled,
                        onTap:         { handleTap(item) },
                        onLongPress:   { handleLongPress(item) }
                    )
                    .contextMenu { contextMenu(for: item) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.horizontal, 0)
                }
            } else {
                List(vm.filteredItems, id: \.id) { item in
                    FileRowView(
                        item:          item,
                        isSelected:    vm.selectedItems.contains(item),
                        showThumbnail: appState.thumbnailsEnabled,
                        onTap:         { handleTap(item) },
                        onLongPress:   { handleLongPress(item) }
                    )
                    .contextMenu { contextMenu(for: item) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.horizontal, 0)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(vm.filteredItems) { item in
                    FileGridItemView(
                        item:        item,
                        isSelected:  vm.selectedItems.contains(item),
                        onTap:       { handleTap(item) },
                        onLongPress: { handleLongPress(item) }
                    )
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("This folder is empty")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transfer overlay

    private var transferOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                ForEach(vm.transferTasks.filter { $0.state == .active }) { task in
                    HStack {
                        Image(systemName: task.direction == .upload ? "arrow.up" : "arrow.down")
                            .foregroundStyle(.tint)
                        Text(task.filename)
                            .lineLimit(1)
                            .font(.footnote)
                        Spacer()
                        Text(task.progress.percentString)
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: task.progress)
                }
            }
            .padding(12)
            .glassStyle()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Navigation title

    private var navigationTitle: String {
        if vm.isSelecting {
            return "\(vm.selectedItems.count) selected"
        }
        let last = vm.currentPath == "/" ? vm.providerType.rawValue : (vm.currentPath as NSString).lastPathComponent
        return last
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if vm.isSelecting {
                Button("Done") { vm.clearSelection() }
            } else if vm.canGoBack {
                Button {
                    vm.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            } else if shouldShowLocalHome && pinnedLocalItems.count > 1 {
                EditButton()
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if vm.isSelecting {
                selectionToolbar
            } else {
                normalToolbar
            }
        }
    }

    private var selectionToolbar: some View {
        HStack {
            Button {
                vm.selectAll()
            } label: {
                Text("All")
            }
            Menu {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    vm.copy(Array(vm.selectedItems))
                    vm.clearSelection()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    vm.cut(Array(vm.selectedItems))
                    vm.clearSelection()
                } label: {
                    Label("Move", systemImage: "scissors")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var normalToolbar: some View {
        HStack(spacing: 4) {
            // Multi-select shortcut
            Button {
                vm.isSelecting = true
            } label: {
                Text("Select")
            }

            // View mode toggle
            Button {
                withAnimation {
                    appState.viewMode = appState.viewMode == .list ? .grid : .list
                }
            } label: {
                Image(systemName: appState.viewMode == .list ? "square.grid.2x2" : "list.bullet")
            }

            // Sort
            Menu {
                ForEach(SortField.allCases, id: \.self) { field in
                    Button {
                        if appState.sortField == field {
                            appState.sortAscending.toggle()
                        } else {
                            appState.sortField = field
                        }
                    } label: {
                        HStack {
                            Text(field.label)
                            if appState.sortField == field {
                                Image(systemName: appState.sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }

            // Add / More
            Menu {
                Button {
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("Upload File", systemImage: "arrow.up.doc")
                }
                if vm.providerType == .local {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Add Folder Access", systemImage: "folder.badge.gearshape")
                    }
                }
                Button {
                    showSystemBrowserPicker = true
                } label: {
                    Label("Browse Files Providers", systemImage: "folder")
                }
                Divider()
                if !vm.clipboardItems.isEmpty {
                    Button {
                        Task { await vm.paste() }
                    } label: {
                        Label("Paste (\(vm.clipboardItems.count))", systemImage: "doc.on.clipboard")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        Button {
            appState.addRecent(item)
            previewItem = item
        } label: {
            Label("Open", systemImage: "eye")
        }

        Button {
            Task {
                if let url = await vm.download(item) {
                    shareURL       = url
                    showShareSheet = true
                }
            }
        } label: {
            Label("Share / Export", systemImage: "square.and.arrow.up")
        }

        if vm.providerType.isNetwork {
            Button {
                vm.enqueueBackgroundDownload(item)
            } label: {
                Label("Download to Device", systemImage: "arrow.down.circle")
            }

            Button {
                vm.togglePin(item)
            } label: {
                Label(
                    vm.isPinned(item) ? "Unpin (Online Only)" : "Pin Offline",
                    systemImage: vm.isPinned(item) ? "pin.slash" : "pin.fill"
                )
            }
        }

        Divider()

        Button {
            vm.copy([item])
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            vm.cut([item])
        } label: {
            Label("Move", systemImage: "scissors")
        }

        Button {
            appState.toggleFavorite(item)
        } label: {
            Label(
                appState.isFavorite(item) ? "Remove Favorite" : "Add Favorite",
                systemImage: appState.isFavorite(item) ? "star.slash" : "star"
            )
        }

        Button {
            newName = item.name
            renameItem = item
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            itemToDelete      = item
            showDeleteConfirm = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Tap / long press

    private func handleTap(_ item: FileItem) {
        if vm.isSelecting {
            vm.toggleSelection(item)
            return
        }

        if item.isDirectory {
            vm.open(item)
            return
        }

        // Open every file type in-app (native viewer/editor/QuickLook fallback).
        appState.addRecent(item)
        previewItem = item
    }

    private func handleLongPress(_ item: FileItem) {
        vm.isSelecting = true
        vm.toggleSelection(item)
    }

    private func handleSystemPickedURL(_ picked: URL) {
        let granted = picked.startAccessingSecurityScopedResource()
        defer {
            if granted {
                picked.stopAccessingSecurityScopedResource()
            }
        }

        let isDirectory = (try? picked.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? picked.hasDirectoryPath
        if isDirectory {
            do {
                try LocalFileService.addExternalFolderBookmark(url: picked)
                if vm.providerType == .local {
                    Task { await vm.refresh() }
                }
            } catch {
                vm.error = "Could not save folder access."
            }
            return
        }

        do {
            let tempURL = try copyImportedFileToAppTemp(picked)
            if let item = FileItem.fromLocalURL(tempURL, provider: .local) {
                systemPreviewItem = item
            } else {
                vm.error = "Could not open selected file."
            }
        } catch {
            vm.error = error.localizedDescription
        }
    }

    private func copyImportedFileToAppTemp(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let targetDir = fm.temporaryDirectory.appendingPathComponent("PickedFiles", isDirectory: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)

        let safeName = source.lastPathComponent.isEmpty ? "OpenedFile" : source.lastPathComponent
        let dst = targetDir.appendingPathComponent("\(UUID().uuidString)-\(safeName)")

        do {
            try fm.copyItem(at: source, to: dst)
        } catch {
            let data = try Data(contentsOf: source)
            try data.write(to: dst, options: .atomic)
        }
        return dst
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
