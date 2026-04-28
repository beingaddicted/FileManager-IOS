import Foundation
import SwiftUI
import Observation

// MARK: - FileBrowserViewModel

@Observable
@MainActor
final class FileBrowserViewModel {
    // MARK: - State

    var items: [FileItem] = [] {
        didSet { rebuildNameIndex() }
    }
    var selectedItems: Set<FileItem> = []
    var currentPath: String = "/"
    var pathStack: [String] = []
    var isLoading: Bool = false
    var error: String?
    var searchText: String = "" {
        didSet { scheduleSearchDebounce() }
    }
    /// Debounced echo of `searchText`; avoids re-running the filter on every keystroke.
    private var debouncedSearch: String = ""
    var transferTasks: [TransferTask] = []
    var clipboardItems: [FileItem] = []
    var clipboardMode: ClipboardMode = .copy
    var isSelecting: Bool = false

    // MARK: - Dependencies

    @ObservationIgnored private var provider: FileProvider
    @ObservationIgnored let providerType: ProviderType
    @ObservationIgnored private let appState: AppState
    /// In-flight debounce task. Replaced on every keystroke so only the
    /// last one applies. Uses a Task instead of Combine because Combine's
    /// `debounce` operator wants an `ObservableObject` publisher.
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?

    /// Pre-lowered file names keyed by `FileItem.id`. Building this once when
    /// `items` changes lets `filteredItems` use a cheap `contains(_:)` instead
    /// of `localizedCaseInsensitiveContains` per-keystroke per-row.
    @ObservationIgnored private var nameIndex: [String: String] = [:]

    private func rebuildNameIndex() {
        nameIndex.removeAll(keepingCapacity: true)
        nameIndex.reserveCapacity(items.count)
        for item in items {
            nameIndex[item.id] = item.name.lowercased()
        }
    }

    // MARK: - Computed

    var filteredItems: [FileItem] {
        let visible = appState.showHiddenFiles ? items : items.filter { !$0.isHidden }
        let sorted  = sort(visible)
        let query = debouncedSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return sorted }
        return sorted.filter { item in
            (nameIndex[item.id] ?? item.name.lowercased()).contains(query)
        }
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

    /// Pushes `searchText` into `debouncedSearch` after a 220 ms quiet period.
    /// Combine's `.debounce` is awkward against `@Observable` because there's
    /// no `$searchText` publisher; a self-cancelling Task is the simplest
    /// equivalent.
    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        let snapshot = searchText
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.debouncedSearch != snapshot {
                self.debouncedSearch = snapshot
            }
        }
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
    //
    // Loading semantics:
    //
    //   * First load (items empty)  → show the full-screen spinner.
    //   * Refresh (items populated) → keep the existing rows visible and
    //     diff against the new listing. SwiftUI's `List`/`LazyVGrid` use
    //     `FileItem.id` to identify rows, so it animates inserts/removes
    //     in place without flicker as long as we don't replace the array
    //     wholesale through a `isLoading=true` round-trip.

    func loadDirectory() async {
        let isFirstLoad = items.isEmpty
        if isFirstLoad { isLoading = true }
        error = nil
        defer { isLoading = false }
        do {
            let fresh = try await provider.listDirectory(at: currentPath)
            applyFresh(items: fresh, isFirstLoad: isFirstLoad)
        } catch {
            self.error = error.localizedDescription
            if isFirstLoad { items = [] }
        }
    }

    /// Apply `fresh` to `items`. For repeat loads, prefer in-place index
    /// mutations so SwiftUI keeps row identity stable and animates the diff
    /// rather than tearing down the whole list.
    private func applyFresh(items fresh: [FileItem], isFirstLoad: Bool) {
        if isFirstLoad {
            items = fresh
            return
        }
        // Use `Array.difference(from:by:)` keyed on item id+mtime so renamed
        // files come through as a remove+insert (SwiftUI animates that), but
        // unchanged files stay put (no row redraw).
        let oldKeyed = items.map { Self.diffKey($0) }
        let newKeyed = fresh.map { Self.diffKey($0) }
        let diff = newKeyed.difference(from: oldKeyed)
        if diff.isEmpty {
            // Nothing changed — keep existing array reference so SwiftUI sees
            // no work at all.
            return
        }
        // Apply changes by walking the diff and mutating `items` in place.
        var working = items
        for change in diff {
            switch change {
            case let .remove(offset, _, _):
                if offset < working.count {
                    working.remove(at: offset)
                }
            case let .insert(offset, _, _):
                let inserted = fresh[offset]
                let safeOffset = min(offset, working.count)
                working.insert(inserted, at: safeOffset)
            }
        }
        items = working
    }

    private static func diffKey(_ item: FileItem) -> String {
        "\(item.id)|\(Int(item.modifiedDate.timeIntervalSince1970))|\(item.size)"
    }

    /// Refreshes `items` without toggling `isLoading` (e.g. after delete so the list stays responsive).
    private func refreshItemsOnly() async {
        do {
            let fresh = try await provider.listDirectory(at: currentPath)
            applyFresh(items: fresh, isFirstLoad: false)
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
        let name = url.lastPathComponent
        let dst  = (currentPath as NSString).appendingPathComponent(name)
        let task = TransferTask(filename: name, direction: .upload)
        transferTasks.append(task)
        task.state = .active

        task.cancellable = Task {
            do {
                // Streaming upload — provider reads bytes from disk as needed
                // so we don't load the entire file into memory.
                try await provider.uploadFile(at: url, to: dst) { [weak task] p in
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

    /// Returns a streaming target the AV player can use directly, if the
    /// provider exposes one (HTTP-based providers like WebDAV/UPnP do; SFTP
    /// and SMB return `nil` and the caller must fall back to `download`).
    func streamingTarget(for item: FileItem) -> StreamingTarget? {
        provider.streamingURL(for: item.path)
    }

    /// Convenience for views that want pinning state without reaching into
    /// `OfflinePinService` directly.
    func cachedOfflineURL(for item: FileItem) -> URL? {
        guard let connId = item.connectionId else { return nil }
        return OfflinePinService.shared.cachedURL(for: connId, path: item.path)
    }

    /// Resolves the connection backing this browser, if any.
    func currentConnection() -> ServerConnection? {
        guard providerType.isNetwork else { return nil }
        // The first item provides a hint; otherwise fall back to the most
        // recently active connection on the AppState.
        if let id = items.compactMap(\.connectionId).first,
           let conn = appState.connections.first(where: { $0.id == id }) {
            return conn
        }
        return appState.activeConnection
    }

    func togglePin(_ item: FileItem) {
        guard let conn = currentConnection() else { return }
        OfflinePinService.shared.togglePin(item: item, connection: conn)
        if OfflinePinService.shared.isPinned(connectionId: conn.id, path: item.path) {
            // Kick off an immediate sync so the file actually lands on disk.
            Task {
                await OfflinePinService.shared.sync(connection: conn, provider: provider)
            }
        }
    }

    func isPinned(_ item: FileItem) -> Bool {
        guard let connId = item.connectionId ?? currentConnection()?.id else { return false }
        return OfflinePinService.shared.isPinned(connectionId: connId, path: item.path)
    }

    /// Enqueues a real download via `BackgroundTransferService` for the
    /// "Save to Files" action. Distinct from the in-memory preview path.
    func enqueueBackgroundDownload(_ item: FileItem) {
        let conn = currentConnection()
        BackgroundTransferService.shared.enqueueDownload(
            item: item,
            connection: conn,
            provider: provider
        )
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
