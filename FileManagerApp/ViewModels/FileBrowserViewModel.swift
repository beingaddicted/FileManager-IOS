import Foundation
import SwiftUI
import Combine

// MARK: - FileBrowserViewModel

@MainActor
final class FileBrowserViewModel: ObservableObject {
    // MARK: - State

    @Published var items: [FileItem] = []
    @Published var selectedItems: Set<FileItem> = []
    @Published var currentPath: String = "/"
    @Published var pathStack: [String] = []
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var searchText: String = ""
    @Published var transferTasks: [TransferTask] = []
    @Published var clipboardItems: [FileItem] = []
    @Published var clipboardMode: ClipboardMode = .copy
    @Published var isSelecting: Bool = false

    // MARK: - Dependencies

    private var provider: FileProvider
    let providerType: ProviderType
    private let appState: AppState

    // MARK: - Computed

    var filteredItems: [FileItem] {
        let visible = appState.showHiddenFiles ? items : items.filter { !$0.isHidden }
        let sorted  = sort(visible)
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var breadcrumbs: [Breadcrumb] {
        var crumbs: [Breadcrumb] = []
        var accumulated = "/"
        crumbs.append(Breadcrumb(name: providerType.rawValue, path: "/"))
        let parts = currentPath.split(separator: "/").map(String.init)
        for part in parts {
            accumulated = accumulated.hasSuffix("/") ? accumulated + part : accumulated + "/" + part
            crumbs.append(Breadcrumb(name: part, path: accumulated))
        }
        return crumbs
    }

    var canGoBack: Bool { !pathStack.isEmpty }
    var isInSelection: Bool { isSelecting }

    // MARK: - Init

    init(provider: FileProvider, providerType: ProviderType, appState: AppState) {
        self.provider     = provider
        self.providerType = providerType
        self.appState     = appState
    }

    // MARK: - Navigation

    func open(_ item: FileItem) {
        guard item.isDirectory else { return }
        pathStack.append(currentPath)
        currentPath = item.path
        Task { await loadDirectory() }
    }

    func goBack() {
        guard let previous = pathStack.popLast() else { return }
        currentPath = previous
        Task { await loadDirectory() }
    }

    func navigate(to path: String) {
        pathStack.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    // MARK: - Load

    func loadDirectory() async {
        isLoading = true
        error     = nil
        defer { isLoading = false }
        do {
            items = try await provider.listDirectory(at: currentPath)
        } catch {
            self.error = error.localizedDescription
            items = []
        }
    }

    /// Refreshes `items` without toggling `isLoading` (e.g. after delete so the list stays responsive).
    private func refreshItemsOnly() async {
        do {
            items = try await provider.listDirectory(at: currentPath)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        await loadDirectory()
    }

    // MARK: - Sort

    private func sort(_ list: [FileItem]) -> [FileItem] {
        list.sorted { a, b in
            // Folders first
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch appState.sortField {
            case .name:
                let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                return appState.sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                return appState.sortAscending ? a.size < b.size : a.size > b.size
            case .date:
                return appState.sortAscending ? a.modifiedDate < b.modifiedDate : a.modifiedDate > b.modifiedDate
            case .type:
                let cmp = a.itemType.rawValue.localizedCaseInsensitiveCompare(b.itemType.rawValue)
                return appState.sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    // MARK: - File operations

    func createFolder(named name: String) async {
        if providerType == .local &&
            (currentPath == "/" || currentPath.hasPrefix(LocalFileService.smartRootPrefix)) {
            self.error = "Open a location (Documents/Downloads/etc.) before creating a folder."
            return
        }
        let path = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
        do {
            try await provider.createDirectory(at: path)
            await loadDirectory()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ item: FileItem) async {
        let snapshot = items
        items.removeAll { $0.id == item.id }
        selectedItems.remove(item)

        do {
            try await provider.delete(at: item.path)
        } catch {
            self.error = error.localizedDescription
            items = snapshot
            return
        }
        await refreshItemsOnly()
    }

    func deleteSelected() async {
        let toDelete = Array(selectedItems)
        let ids = Set(toDelete.map(\.id))
        items.removeAll { ids.contains($0.id) }
        clearSelection()

        for item in toDelete {
            do { try await provider.delete(at: item.path) }
            catch { self.error = error.localizedDescription }
        }
        await refreshItemsOnly()
    }

    func rename(_ item: FileItem, to newName: String) async {
        do {
            try await provider.rename(at: item.path, to: newName)
            await loadDirectory()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Clipboard

    func copy(_ items: [FileItem]) {
        clipboardItems = items
        clipboardMode  = .copy
    }

    func cut(_ items: [FileItem]) {
        clipboardItems = items
        clipboardMode  = .move
    }

    func paste() async {
        guard !clipboardItems.isEmpty else { return }
        for item in clipboardItems {
            let dst = (currentPath as NSString).appendingPathComponent(item.name)
            do {
                if clipboardMode == .copy {
                    try await provider.copy(from: item.path, to: dst)
                } else {
                    try await provider.move(from: item.path, to: dst)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        if clipboardMode == .move { clipboardItems = [] }
        await loadDirectory()
    }

    // MARK: - Upload

    func upload(url: URL) async {
        if providerType == .local &&
            (currentPath == "/" || currentPath.hasPrefix(LocalFileService.smartRootPrefix)) {
            error = "Open a location before uploading files."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error = "Failed to read file"
            return
        }
        let name = url.lastPathComponent
        let dst  = (currentPath as NSString).appendingPathComponent(name)
        let task = TransferTask(filename: name, direction: .upload)
        transferTasks.append(task)
        task.state = .active

        task.cancellable = Task {
            do {
                try await provider.upload(data, to: dst) { [weak task] p in
                    Task { @MainActor in task?.progress = p }
                }
                task.state = .done
                await self.loadDirectory()
            } catch {
                task.state = .failed
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Download

    func download(_ item: FileItem) async -> URL? {
        let task = TransferTask(filename: item.name, direction: .download)
        transferTasks.append(task)
        task.state = .active
        do {
            let url = try await provider.downloadToTemp(from: item.path) { [weak task] p in
                Task { @MainActor in task?.progress = p }
            }
            task.state = .done
            appState.addRecent(item)
            return url
        } catch {
            task.state = .failed
            self.error = error.localizedDescription
            return nil
        }
    }

    func saveText(_ text: String, for item: FileItem) async throws {
        guard item.isTextEditable else { throw FileProviderError.unsupportedOperation }
        let data = Data(text.utf8)
        try await provider.upload(data, to: item.path, progress: nil)
        appState.addRecent(item)
        await loadDirectory()
    }

    // MARK: - Selection

    func toggleSelection(_ item: FileItem) {
        if selectedItems.contains(item) {
            selectedItems.remove(item)
        } else {
            selectedItems.insert(item)
        }
    }

    func selectAll() {
        selectedItems = Set(filteredItems)
    }

    func clearSelection() {
        selectedItems = []
        isSelecting   = false
    }
}

// MARK: - Support types

enum ClipboardMode { case copy, move }

struct Breadcrumb: Identifiable {
    var id: String { path }
    let name: String
    let path: String
}
