import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Browser View

struct FileBrowserView: View {
    @ObservedObject var vm: FileBrowserViewModel
    @EnvironmentObject var appState: AppState

    @State private var selectedItem: FileItem?
    @State private var previewItem: FileItem?
    @State private var renameItem: FileItem?
    @State private var newName: String = ""
    @State private var showNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var showFilePicker: Bool = false
    @State private var showSortMenu: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var itemToDelete: FileItem?
    @State private var shareURL: URL?
    @State private var showShareSheet: Bool = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Grid layout

    private let gridColumns = [
        GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 12)
    ]

    var body: some View {
        ZStack {
            // MARK: Content
            Group {
                if vm.isLoading && vm.items.isEmpty {
                    loadingView
                } else if vm.filteredItems.isEmpty && !vm.isLoading {
                    emptyView
                } else {
                    contentView
                }
            }

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
                Task {
                    if let item = itemToDelete {
                        await vm.delete(item)
                    } else {
                        await vm.deleteSelected()
                    }
                }
                itemToDelete = nil
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
    }

    // MARK: - Content view

    private var contentView: some View {
        Group {
            if appState.viewMode == .list {
                listContent
            } else {
                gridContent
            }
        }
        .animation(.spring(duration: 0.3), value: vm.filteredItems.map(\.id))
    }

    // MARK: - List

    private var listContent: some View {
        List(vm.filteredItems, id: \.id, selection: vm.isSelecting ? $vm.selectedItems : .constant(nil)) { item in
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
                Divider()
                Button {
                    vm.isSelecting = true
                } label: {
                    Label("Select Items", systemImage: "checkmark.circle")
                }
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
        if item.isPreviewable {
            Button {
                previewItem = item
            } label: {
                Label("Preview", systemImage: "eye")
            }
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
        } else if item.isDirectory {
            vm.open(item)
        } else if item.isPreviewable && appState.previewOnTap {
            previewItem = item
        } else {
            Task {
                if let url = await vm.download(item) {
                    shareURL = url
                    showShareSheet = true
                }
            }
        }
    }

    private func handleLongPress(_ item: FileItem) {
        vm.isSelecting = true
        vm.toggleSelection(item)
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
