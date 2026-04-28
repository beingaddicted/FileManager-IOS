import Foundation
import Photos

// MARK: - Local File Service

final class LocalFileService: FileProvider {
    let providerType: ProviderType = .local
    private(set) var isConnected: Bool = true
    static let smartRootPrefix = "/__smart__"
    static let photosPrefix = "/__photos__"

    private struct SmartFolder {
        let name: String
        let path: String
        let kind: Kind

        enum Kind {
            case images
            case videos
            case documents
        }
    }

    private static let smartFolders: [SmartFolder] = [
        SmartFolder(name: "All Images", path: "\(smartRootPrefix)/images", kind: .images),
        SmartFolder(name: "All Videos", path: "\(smartRootPrefix)/videos", kind: .videos),
        SmartFolder(name: "All Documents", path: "\(smartRootPrefix)/documents", kind: .documents)
    ]

    private struct ExternalFolderBookmark: Codable {
        let name: String
        let path: String
        let bookmarkData: Data
    }

    private var smartFolderCache: [String: (timestamp: Date, items: [FileItem])] = [:]
    private let cacheTTL: TimeInterval = 30
    private static let externalFoldersKey = "local_external_folders_v1"

    func connect() async throws {}
    func disconnect() {}

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        if path == "/" {
            let roots = Self.rootPaths.map { root in
                FileItem(
                    id: root.path,
                    name: root.name,
                    path: root.path,
                    size: 0,
                    modifiedDate: Date(),
                    isDirectory: true,
                    isHidden: false,
                    isSymlink: false,
                    itemType: .folder,
                    providerType: .local
                )
            }
            let smart = Self.smartFolders.map { folder in
                FileItem(
                    id: folder.path,
                    name: folder.name,
                    path: folder.path,
                    size: 0,
                    modifiedDate: Date(),
                    isDirectory: true,
                    isHidden: false,
                    isSymlink: false,
                    itemType: .folder,
                    providerType: .local
                )
            }
            return roots + smart
        }

        if path.hasPrefix(Self.smartRootPrefix) {
            return try await listSmartFolder(at: path)
        }

        let fm  = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
            .isHiddenKey, .isSymbolicLinkKey
        ]
        do {
            return try withSecurityScopedAccess(for: path) {
                let contents = try fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
                )
                return contents.compactMap { FileItem.fromLocalURL($0) }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == CocoaError.fileReadNoPermission.rawValue ||
                 nsError.code == CocoaError.fileReadInvalidFileName.rawValue) {
                throw FileProviderError.permissionDenied
            }
            throw error
        }
    }

    private func listSmartFolder(at path: String) async throws -> [FileItem] {
        if let cached = smartFolderCache[path], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.items
        }

        guard let folder = Self.smartFolders.first(where: { $0.path == path }) else {
            throw FileProviderError.invalidPath(path)
        }

        let roots = Self.normalizedScanRoots(from: Self.rootPaths.map(\.path))
        var scanned = try await Task.detached(priority: .userInitiated) {
            try Self.scanFiles(in: roots, kind: folder.kind)
        }.value

        if folder.kind == .images || folder.kind == .videos {
            let photoItems = try await scanPhotoLibrary(kind: folder.kind)
            scanned.append(contentsOf: photoItems)
        }

        let deduped = Self.deduplicated(scanned)
            .sorted { $0.modifiedDate > $1.modifiedDate }

        smartFolderCache[path] = (Date(), deduped)
        return deduped
    }

    // MARK: - Info

    func getInfo(at path: String) async throws -> FileItem {
        if let localIdentifier = Self.decodePhotoAssetIdentifier(from: path),
           let item = try await photoFileItem(localIdentifier: localIdentifier) {
            return item
        }

        return try withSecurityScopedAccess(for: path) {
            let url = URL(fileURLWithPath: path)
            guard let item = FileItem.fromLocalURL(url) else {
                throw FileProviderError.fileNotFound(path)
            }
            return item
        }
    }

    // MARK: - Download / Upload

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        if let localIdentifier = Self.decodePhotoAssetIdentifier(from: path) {
            let url = try await exportPhotoAssetToTemp(localIdentifier: localIdentifier)
            let data = try Data(contentsOf: url)
            progress?(1.0)
            return data
        }

        return try withSecurityScopedAccess(for: path) {
            let url = URL(fileURLWithPath: path)
            let data = try coordinatedReadData(at: url)
            progress?(1.0)
            return data
        }
    }

    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL {
        if let localIdentifier = Self.decodePhotoAssetIdentifier(from: path) {
            let url = try await exportPhotoAssetToTemp(localIdentifier: localIdentifier)
            progress?(1.0)
            return url
        }
        let url = URL(fileURLWithPath: path)
        progress?(1.0)
        return url
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        try withSecurityScopedAccess(for: path) {
            let url = URL(fileURLWithPath: path)
            try coordinatedWriteData(data, to: url)
            progress?(1.0)
        }
    }

    // MARK: - Operations

    func delete(at path: String) async throws {
        if Self.decodePhotoAssetIdentifier(from: path) != nil {
            throw FileProviderError.unsupportedOperation
        }
        try withSecurityScopedAccess(for: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func createDirectory(at path: String) async throws {
        try withSecurityScopedAccess(for: path) {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        }
    }

    func rename(at path: String, to newName: String) async throws {
        if Self.decodePhotoAssetIdentifier(from: path) != nil {
            throw FileProviderError.unsupportedOperation
        }
        try withSecurityScopedAccess(for: path) {
            let src = URL(fileURLWithPath: path)
            let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
            try FileManager.default.moveItem(at: src, to: dst)
        }
    }

    func move(from src: String, to dst: String) async throws {
        if Self.decodePhotoAssetIdentifier(from: src) != nil {
            throw FileProviderError.unsupportedOperation
        }
        try withSecurityScopedAccess(for: src) {
            try FileManager.default.moveItem(
                atPath: src,
                toPath: dst
            )
        }
    }

    func copy(from src: String, to dst: String) async throws {
        if Self.decodePhotoAssetIdentifier(from: src) != nil {
            throw FileProviderError.unsupportedOperation
        }
        try withSecurityScopedAccess(for: src) {
            try FileManager.default.copyItem(
                atPath: src,
                toPath: dst
            )
        }
    }

    // MARK: - Helpers

    private static func photoAssetPath(for localIdentifier: String) -> String {
        let encoded = localIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? localIdentifier
        return "\(photosPrefix)/\(encoded)"
    }

    private static func decodePhotoAssetIdentifier(from path: String) -> String? {
        guard path.hasPrefix("\(photosPrefix)/") else { return nil }
        let encoded = String(path.dropFirst(photosPrefix.count + 1))
        return encoded.removingPercentEncoding
    }

    private func ensurePhotoLibraryAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { result in
                    continuation.resume(returning: result)
                }
            }
            guard newStatus == .authorized || newStatus == .limited else {
                throw FileProviderError.permissionDenied
            }
        default:
            throw FileProviderError.permissionDenied
        }
    }

    private func scanPhotoLibrary(kind: SmartFolder.Kind) async throws -> [FileItem] {
        guard kind == .images || kind == .videos else { return [] }
        try await ensurePhotoLibraryAccess()

        return try await Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.includeHiddenAssets = false
            opts.predicate = NSPredicate(
                format: "mediaType == %d",
                kind == .images ? PHAssetMediaType.image.rawValue : PHAssetMediaType.video.rawValue
            )

            let fetch = PHAsset.fetchAssets(with: opts)
            var results: [FileItem] = []
            fetch.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let preferredType: PHAssetResourceType = kind == .images ? .photo : .video
                let preferred = resources.first(where: { $0.type == preferredType }) ?? resources.first
                let filename = preferred?.originalFilename ?? (kind == .images ? "Photo.jpg" : "Video.mov")
                let fileSize = (preferred?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0

                results.append(FileItem(
                    id: "photo-\(asset.localIdentifier)",
                    name: filename,
                    path: Self.photoAssetPath(for: asset.localIdentifier),
                    size: fileSize,
                    modifiedDate: asset.modificationDate ?? asset.creationDate ?? Date(),
                    createdDate: asset.creationDate,
                    isDirectory: false,
                    isHidden: false,
                    isSymlink: false,
                    itemType: kind == .images ? .image : .video,
                    providerType: .local
                ))
            }
            return results
        }.value
    }

    private func photoFileItem(localIdentifier: String) async throws -> FileItem? {
        try await ensurePhotoLibraryAccess()
        return try await Task.detached(priority: .userInitiated) {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetch.firstObject else { return nil }
            let resources = PHAssetResource.assetResources(for: asset)
            let kind: SmartFolder.Kind = asset.mediaType == .video ? .videos : .images
            let preferredType: PHAssetResourceType = kind == .images ? .photo : .video
            let preferred = resources.first(where: { $0.type == preferredType }) ?? resources.first
            let filename = preferred?.originalFilename ?? (kind == .images ? "Photo.jpg" : "Video.mov")
            let fileSize = (preferred?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            return FileItem(
                id: "photo-\(asset.localIdentifier)",
                name: filename,
                path: Self.photoAssetPath(for: asset.localIdentifier),
                size: fileSize,
                modifiedDate: asset.modificationDate ?? asset.creationDate ?? Date(),
                createdDate: asset.creationDate,
                isDirectory: false,
                isHidden: false,
                isSymlink: false,
                itemType: kind == .images ? .image : .video,
                providerType: .local
            )
        }.value
    }

    private func exportPhotoAssetToTemp(localIdentifier: String) async throws -> URL {
        try await ensurePhotoLibraryAccess()

        let (asset, resource) = try await Task.detached(priority: .userInitiated) {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetch.firstObject else { throw FileProviderError.fileNotFound(localIdentifier) }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first else { throw FileProviderError.fileNotFound(localIdentifier) }
            return (asset, resource)
        }.value

        let fallbackName = asset.mediaType == .video ? "Video.mov" : "Photo.jpg"
        let originalName = resource.originalFilename.isEmpty ? fallbackName : resource.originalFilename
        let ext = URL(fileURLWithPath: originalName).pathExtension
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: tmpURL,
                options: nil
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        return tmpURL
    }

    static var rootPaths: [(name: String, path: String)] {
        let fm  = FileManager.default
        var paths: [(String, String)] = []

        // App container root
        let home = NSHomeDirectory()
        if fm.fileExists(atPath: home) {
            paths.append(("App Container", home))
        }

        // Documents
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(("Documents", docs.path))
            let inbox = docs.appendingPathComponent("Inbox")
            if fm.fileExists(atPath: inbox.path) {
                paths.append(("Inbox", inbox.path))
            }
        }
        // Downloads (iOS 16+)
        if let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: dl.path) {
            paths.append(("Downloads", dl.path))
        }
        // Library
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: lib.path) {
            paths.append(("Library", lib.path))
        }
        // Caches
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: caches.path) {
            paths.append(("Caches", caches.path))
        }
        // Temporary
        paths.append(("Temporary", fm.temporaryDirectory.path))
        // iCloud container root if available
        if let icloud = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents") {
            paths.append(("iCloud Documents", icloud.path))
        }
        paths.append(contentsOf: externalFolderRoots())
        return paths
    }

    static func externalFolderRoots() -> [(name: String, path: String)] {
        externalFolderBookmarks().map { ($0.name, $0.path) }
    }

    private static func externalFolderBookmarks() -> [ExternalFolderBookmark] {
        guard let data = UserDefaults.standard.data(forKey: externalFoldersKey),
              let bookmarks = try? JSONDecoder().decode([ExternalFolderBookmark].self, from: data) else {
            return []
        }
        return bookmarks
    }

    static func addExternalFolderBookmark(url: URL) throws {
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = url.lastPathComponent.isEmpty ? "External Folder" : url.lastPathComponent
        let newEntry = ExternalFolderBookmark(name: name, path: url.path, bookmarkData: bookmark)
        var entries = externalFolderBookmarks()
        entries.removeAll { $0.path == newEntry.path }
        entries.append(newEntry)
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: externalFoldersKey)
        }
    }

    static func removeExternalFolder(path: String) {
        var entries = externalFolderBookmarks()
        entries.removeAll { $0.path == path }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: externalFoldersKey)
        }
    }

    private func withSecurityScopedAccess<T>(for path: String, _ work: () throws -> T) throws -> T {
        guard let bookmark = Self.externalFolderBookmarks().first(where: { path.hasPrefix($0.path) }) else {
            return try work()
        }
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark.bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let didStart = resolved.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                resolved.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }

    private func coordinatedReadData(at url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var result = Data()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                result = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let readError {
            throw readError
        }
        return result
    }

    private func coordinatedWriteData(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    private static func scanFiles(in roots: [String], kind: SmartFolder.Kind) throws -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isHiddenKey,
            .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isSymbolicLinkKey
        ]

        var items: [FileItem] = []

        for rootPath in roots {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory != true,
                      values.isRegularFile == true else {
                    continue
                }

                let type = FileTypeHelper.detectType(for: url)
                guard matches(kind: kind, type: type) else { continue }
                if let item = FileItem.fromLocalURL(url, provider: .local) {
                    items.append(item)
                }
            }
        }

        return items
    }

    private static func normalizedScanRoots(from roots: [String]) -> [String] {
        let fm = FileManager.default
        var existing = roots.filter { fm.fileExists(atPath: $0) }
        existing = Array(Set(existing)).sorted { $0.count < $1.count }

        var filtered: [String] = []
        for candidate in existing {
            let isNested = filtered.contains { parent in
                candidate == parent || candidate.hasPrefix(parent + "/")
            }
            if !isNested {
                filtered.append(candidate)
            }
        }
        return filtered
    }

    private static func deduplicated(_ items: [FileItem]) -> [FileItem] {
        var seen = Set<String>()
        var result: [FileItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            let key = item.isDirectory ? "D:\(item.path)" : "F:\(item.path)"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    private static func matches(kind: SmartFolder.Kind, type: FileItemType) -> Bool {
        switch kind {
        case .images:
            return type == .image
        case .videos:
            return type == .video
        case .documents:
            switch type {
            case .document, .spreadsheet, .presentation, .pdf, .text, .code, .archive, .database:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - iCloud Service

final class ICloudService: FileProvider {
    let providerType: ProviderType = .iCloud
    private(set) var isConnected: Bool = false
    private var baseURL: URL?

    func connect() async throws {
        guard let url = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw FileProviderError.notConnected
        }
        baseURL = url
        isConnected = true
    }

    func disconnect() { isConnected = false }

    func listDirectory(at path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        )
        return contents.compactMap { FileItem.fromLocalURL($0, provider: .iCloud) }
    }

    func getInfo(at path: String) async throws -> FileItem {
        let url = URL(fileURLWithPath: path)
        guard let item = FileItem.fromLocalURL(url, provider: .iCloud) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        // Trigger iCloud download if needed
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        // Wait briefly for download
        var attempts = 0
        while attempts < 30 {
            if let data = try? Data(contentsOf: url) {
                progress?(1.0)
                return data
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            attempts += 1
        }
        throw FileProviderError.transferFailed("iCloud download timed out")
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        progress?(1.0)
    }

    func delete(at path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func createDirectory(at path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func rename(at path: String, to newName: String) async throws {
        let src = URL(fileURLWithPath: path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    func move(from src: String, to dst: String) async throws {
        try FileManager.default.moveItem(atPath: src, toPath: dst)
    }
}
